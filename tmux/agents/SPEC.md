# tmux agents — spec (draft 0.1)

Minimal, self-owned layer that surfaces AI coding agents (Claude Code first;
Codex/opencode later) in the tmux workflow: notice → locate → act, without
ambient noise. Everything themable via the existing Catppuccin theme system.

## Non-goals

Worktree/branch orchestration, remote permission approval via send-keys,
rate-limit/quota display, sidebar/dashboard TUI, per-agent park. Agent process
recovery after restarts is Claude's job, not this layer's.

## State model

Per **pane**. One of:

| state | meaning | loudness |
|---|---|---|
| `action` (dialog-class, `prev=action`) | a permission dialog blocks the agent | RED, loud (bell/notification) — the only red in the system |
| `action` (waiting-class, `prev=waiting`) | idle, waiting for the user's next message — an open conversation, nothing blocked | yellow, silent; the full unseen story: tallies as unseen, never paints the attended pane, clears on focus |
| `unseen` | turn finished, result not looked at yet | yellow, silent |
| `running` | agent is working | quiet (dim) |
| `idle` | agent alive, nothing to report | quiet (dim) |

Red means exactly one thing: something is blocked on the user. Claude
Code fires the idle-waiting notification ~60s after every turn end, so
painting it red would redden precisely the agent being conversed with —
the class split keeps that calm. Urgent reddens both classes.

Priority for aggregation: `action > unseen > running > idle`.
Window state = max of its panes; session state = max of its windows.

**Clearing rule (load-bearing):** focusing a pane clears `unseen` → `idle`
(global `pane-focus-in` hook, `if -F`-guarded so it costs nothing when there is
no transition). A turn that finishes while the pane is focused and the client
is focused becomes `idle` directly — decided atomically server-side:

```
tmux if -F -t "$TMUX_PANE" '#{&&:#{pane_active},#{&&:#{window_active},#{session_attached}}}' \
    'set -p @agent_state idle' 'set -p @agent_state unseen'
```

States are **ephemeral by design** — they die with the pane/server, and
resurrect not restoring them is correct (a restored "running" would be a lie).

## Storage

Truth lives in tmux pane user options (no state files, no GC):

- `@agent_state` — one of the states
- `@agent_ts`    — unix time of last transition (recency sort)
- `@agent_prev`  — the event that produced the state (dialog- vs
  waiting-class reds, guard context)
- `@agent_kind`  — `claude` | `codex` | `opencode` | ...

Derived by the daemon, read-only for every renderer:

- `@agent_class` — alert / warn / busy / stale / quiet / hidden: the
  effective display class after the modifier law
- `@agent_rank`  — jump band (0 urgent-pending, 1 await, 2 unseen incl
  muted awaits, 3 stuck incl faults; unset = not a jump target).
  Viewer-independent — closeness and age are the renderer's business
- `@agent_mod`   — resolved modifier name (urgent/muted/disabled; session
  mutes count as muted)
- `@agent_win_sig` (window) + `@agents_any`/`@agents_n_*` (global) — tab
  signals and widget counts

Cross-session aggregation is never done in format strings — nested
`#{S:#{P:}}` loops are broken on tmux 3.7b (verified).

## Data flow

```
Claude hooks / adapters ──→ agent-state.sh ─┐   (emit: one appended line
picker toggles ───────────→ agents-ctl.sh ──┤    + wait-for doorbell;
settings changes ─────────→ agents-settings┤    >> never blocks)
focus / client hooks ─────────────────────  ┘
                 │
                 ▼
        spool (per-server, ~/.local/state/tmux-agents/<socket>/)
                 │
                 ▼
        agentsd.sh — the SINGLE WRITER (bash ≥ 4; inert on 3.2):
          drain to EOF → transitions + guards → in-loop sensors
          (0.5s probes of attended dialogs, liveness sweep, stall stamp) →
          one batched option write → derive class/rank/mod +
          counts + win_sig → refresh-client only on change → park
                 │
                 ▼
        tmux options ──→ agents-render.sh / agents-jump.sh / theme
                         (read-only; closeness stays viewer-side)
```

- **Doorbell is latency, never correctness**: `wait-for -S` signals toggle
  on 3.7b (an even count landing with no waiter cancels) — the daemon
  level-triggers off the spool via a persistent read fd and drains until
  dry before parking; the 5s status tick backstops a lost edge. The park
  blocks on a daemon-private FIFO (bridge child converts wait-for signals
  to bytes) so in-loop timers can fire; hooks never touch the FIFO.
- **Attended-vs-unseen stays server-side**: the daemon chains `if -F` into
  its batch — no userspace focus cache is as fresh as the server itself.
  Temporal guards compare event-ts to event-ts, immune to drain delay.
- **Hooks** (`~/.claude/settings.json`, global): `UserPromptSubmit` → running,
  `PermissionRequest` + `Notification`(permission_prompt|idle_prompt) → action,
  `Stop` → stop. Every hook command is fail-soft:
  `[ -x "$SCRIPT" ] && "$SCRIPT" ...; exit 0` — deleting the repo must never
  break Claude.
- **Shell wrappers** (`claude()` zsh function): launch/exit events —
  guaranteed cleanup even after `kill -9` of the agent (the wrapper
  survives it).
- **Liveness sweep** runs in the daemon (one ps snapshot judges every
  tracked pane; doubt means alive; fresh transitions get a grace window —
  launch wrappers emit before the CLI has exec'd).
- **Lifecycle**: started from .tmux.conf, the emit path (pidfile check),
  and the tick watchdog (dead → start; heartbeat stale while the spool
  grows → wedged → replace). Lock: `shlock` (macOS ships no flock). Boot
  replays a small leftover spool, discards a big one, and re-derives from
  options either way. Accepted gap: detached server + dead daemon = no
  restart until reattach — a crashed daemon's stale pidfile also blocks
  the emit-path autostart, so recovery is tick-only.
- **Known limit (multi-client)**: attendance is per-session, so with two
  terminals on different sessions both active panes count as attended —
  a turn ending on the unfocused terminal's active pane lands idle
  instead of unseen, and its bells are suppressed. The `cur:oth` widget
  split likewise follows one client. Single-client use is unaffected.
- **Tests**: `tests/run.sh` replays fixture event streams through
  `agentsd.sh --replay` (event timestamps are the clock) on a scratch
  server and diffs normalized option dumps against goldens.
- **No polling anywhere**; no `#()` on the hot path (`#()` has a 1 s cache
  floor and `refresh-client -S` cannot force it).

## Surfaces

1. **Window glyph** — appended to `window-status-format`/`-current-format` in
   theme.conf: one glyph after the window number when any pane has
   `@agent_state`, colored by window max state (pure `#{P:}` format, verified
   OK in window context). Careful: theme modules use `set -gF`; runtime
   formats must escape or avoid source-time expansion.
2. **Session picker rows** (`C-s s`) — state symbol per session from one
   `list-panes -a` scan in the fzf `reload()`; saturated color only for
   `action`/`unseen`, dim otherwise. Muted sessions show a mute glyph.
3. **Agents view** — new mode in tzs-session-picker.sh (same `transform:`
   pattern as Windows mode):
   - rows: panes with `@agent_state`, sorted state-priority then `@agent_ts`
     desc; shows session:window.pane, kind, state, age
   - preview: `capture-pane -ep` on the highlighted pane
   - `enter` — switch-client + select-window + select-pane (this IS the
     "jump to attention" action: top row = most urgent)
   - `ctrl-x` — kill agent process (picker's existing kill idiom)
   - one toggle key — mute/unmute the highlighted agent's session
   - entry: `C-s a` directly (`--mode agents` arg), or from inside the picker
     via a mode key that is NOT ctrl-a (readline conflict in fzf query)
4. **Status-bar module** — `@status_agents` appended once to status-right in
   .tmux.conf (compose-once constraint; continuum stays untouched): renders
   `#{E:@agents_attention}` as glyph+count, **absent when zero**. No pane
   numbers — the jump action is `C-s a`.
5. **Alerts** (interruptive channel, `action` state only, never turn-complete):
   terminal bell and/or macOS notification (`osascript`), emitted by the hook
   script itself, gated per session (below). Never via `bell-action`/
   `monitor-bell` (would affect non-agent bells; window-scoped; wrong tool).

One glyph vocabulary everywhere; color carries state. Colors/icons are tmux
user options set in theme files (`@agent_color_action` etc.), never hardcoded
in scripts — light/dark switching works for free.

## Settings

Per-session, two toggles in v1: `bell`, `notify` (ambient visuals stay global —
a per-session-disabled glyph would make "no glyph" ambiguous).

- **Durable**: `~/.local/state/tmux-agents/settings.tsv` keyed by session name
  (resurrect recreates sessions by name, so keying survives restore;
  resurrect does NOT save user options — do not rely on it).
- **Fast**: mirrored into session options `@agents_bell`/`@agents_notify`;
  hooks read only the options. Sync file→options on `session-created` and
  `@resurrect-hook-post-restore-all`.
- **Editable**: from the agents view (toggle key on highlighted row; possibly
  a small settings mode later). `session-renamed` hook re-persists live
  options under the new name; stale file keys are harmless (name reuse
  restores old settings — a feature).
- Global defaults live in .tmux.conf/theme files, versioned in dotfiles.

## Codex / opencode (later)

- opencode: JS plugin (`session.idle` → unseen, `permission.asked` → action)
  calling the same agent-state.sh.
- Codex: `notify` covers turn-complete only; approval prompts only surface as
  TUI bell/OSC — cannot be gated per session at source. Accept lower fidelity
  (wrapper + `pane_current_command` fallback) rather than wrapping the binary.
- The state core must tolerate per-agent fidelity differences.

## Uninstall

A `make uninstall`-style script that: removes hook entries from
~/.claude/settings.json, unsets live tmux hooks it registered
(`set-hook -gu ...` — live hooks survive file deletion; learned the hard way),
clears all `@agent_*` options, removes wrapper functions. Fail-soft hooks make
partial removal safe.

## Implementation stages

See PLAN.md for the full task-level build plan (stages 0–7 with per-task
checks, open decisions, and risk table).

## Feature-mining: adopted into spec

From a survey of accessd/partner0/samleeney/craftzdog/workmux/hiroppy
(READMEs, changelogs, issues). Effort-ordered:

1. **Elapsed time + stale-running + idle decay** — all derived at read time
   from `@agent_ts` (no timers, no watchers): picker rows show age;
   `running` older than ~15 min renders a distinct "stalled?" marker
   (a hung/crashed agent that still says running is the likeliest way to
   lose an hour); `idle` older than ~30 min sorts below fresh idle.
   Lesson from workmux: stale must only ever demote `running`, never mask
   `action`/`unseen`.
2. **`ctrl-r` reload in the agents view** — re-runs the scan + liveness sweep;
   states change while the picker is open.
3. **Jump-to-attention key** (`C-s n`?) — teleport to highest-priority agent
   without the picker; repeat cycles. The dominant loop is "notice → deal
   with it" with exactly one actionable agent.
4. **Hook transition guard** — hooks fire out of order in real life (both
   mature tools shipped flapping bugs): ignore a `Notification` arriving
   just after `Stop`; never let a late event downgrade `action`.
5. **Notification title carries `session:window`**; global `notify_states`
   filter (default: action only) alongside per-session mute.
6. **Kill = SIGTERM the pane's foreground agent process**, not kill-pane
   (craftzdog semantics); pane/shell survives.
7. **Popup-nesting guard** — opening the picker from inside a popup must
   detach the outer popup first (nested display-popup errors).
8. Optional later: pane-border color per state (which pane, inside
   multi-pane windows); `--json` output mode on the scan script.

From the orchestrators (claude-squad, dmux, agent-deck, ntm, ccmanager,
agent-manager):

9. **Quick-prompt without attaching** — fzf binding in the agents view that
   reads a line and `send-keys` it to the highlighted agent's pane. Turns
   the view from a switcher into a triage console (claude-squad's forced
   attach-to-reprompt is its most-hated trait). NOTE: prompts only — the
   remote-*approval* ban stands; sending "y" to a permission prompt you
   haven't read stays out.
10. **State-filterable rows** — line format starts with a stable state tag +
    glyph, so plain fzf query syntax (`'action`, `!idle`) filters for free.
11. **Status module shows names when few** — `⚡ api,billing` when ≤3
    sessions need attention, `⚡ 5` otherwise.
12. **Preview toggle** — a key flips the fzf preview between
    `capture-pane` (what is it saying) and `git diff --stat` in the pane's
    cwd (is it actually producing code).
13. **Global mute** in the settings store alongside per-session mute (dmux).
14. Later: fzf `--multi` + the quick-prompt mechanism = broadcast/batch
    interrupt; `@agent_title_locked` pane option the renamer respects.

## Native Claude Code integration (delegate, don't duplicate)

`claude agents --json` (stable, documented) lists background sessions with
`state`/`waitingFor`/`pid`/`cwd` — but **interactive TUI sessions carry no
state**, agent view hides them, and there is no tmux surface, no
`done-unseen` concept, and no per-session mute. That's precisely the hole
this layer fills; don't rebuild the rest:

- Agents view MAY merge `--json` background sessions as extra rows
  (matched by pid/cwd); kill delegates to `claude stop <id>` for those rows
  vs SIGTERM for pane rows.
- Reuse Claude's session names (`/rename`, auto folder-derived) in rows.
- Status module counts only pane states — Claude's own footer already
  shows `← N agents` for background sessions; don't double-count.
- Alerts ride the `Notification` hook; per-session mute is our guard inside
  that hook script (native mute is global-only).
- Agent teams (`teammateMode: tmux`) spawns real panes running Claude —
  hooks will fire in them; must not break, may deserve a glyph later.

## Feature-mining: explicitly rejected

Animations/pulse glyphs (contradicts event-driven design), notification
sounds, per-session status-bar dots, sort-mode cycling, multi-agent glyph
alphabets (add when a second agent CLI is actually in use), git/PR/diff
columns, activity logs, subagent trees, decorative widgets.

## Warnings from other tools' bug history

- Liveness sweep must clear state only on definitive "pane gone" — never on
  tmux command error/timeout (workmux #209 deleted live state on flaky
  queries).
- Clear `unseen` on *pane* focus of the agent's pane, not window activity —
  background refreshes will eat unseen states otherwise (workmux #202).
- Enumerate all panes with state, never first-pane-per-window (partner0).
- Row identity per pane, never per session/window (craftzdog #9).
- fzf view over bespoke TUI and confirm-less kill both validated by
  samleeney's own reverts.
