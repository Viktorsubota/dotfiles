# tmux agents — build plan

Companion to SPEC.md. Stages ship independently; after each stage: commit,
live with it a day or two, then continue. Nothing may break when the scripts
are missing (fail-soft), nothing may run when no agent changes state.

Glyph: ghost `󰊠` (nf-md-ghost), solid for loud states; outline `󱙝` for quiet
states if it renders, otherwise solid+dim. Color = state, from theme options.

## Files that will exist

```
tmux/agents/
  SPEC.md  PLAN.md  README.md
  agent-state.sh        # state transitions (single entry point, agent-agnostic)
  agents-recompute.sh   # attention summary -> @agents_attention
  agents-scan.sh        # shared list/aggregate for picker, status, jump (+ liveness)
  agents-jump.sh        # jump to highest-priority agent
  agents-settings.sh    # per-session settings: file <-> session options
  claude-install.sh     # Claude adapter: hooks into ~/.claude/settings.json
  uninstall.sh          # full removal incl. live tmux hooks
  opencode-plugin.js    # stage 6
.zshrc                  # claude() wrapper (+ generic agent_wrap later)
.tmux.conf              # focus hook, status module append, C-s a / C-s n binds
tmux/theme.conf         # window glyph in window-status-format
tmux/frappe|latte|macchiato.conf  # @agent_* colors
tmux/tzs-session-picker.sh        # session symbols + agents mode
```

---

## Stage 0 — groundwork

- **0.1 Theme options.** Add to each theme file: `@agent_color_action`
  (red/peach), `@agent_color_unseen` (yellow), `@agent_color_quiet`
  (overlay tone), mapped from existing `@thm_*`. Add `@agent_glyph` /
  `@agent_glyph_quiet` globals in .tmux.conf.
  *Check:* `tmux show -g @agent_color_action` correct after switching
  light/dark.
- **0.2 Glyph render test.** Confirm `󰊠` and `󱙝` render in status bar and
  fzf popup at real size. Fallback: solid ghost everywhere, dim = quiet.

## Stage 1 — engine (no UI)

- **1.1 `agent-state.sh`.** Subcommands: `running|action|stop|seen|launch|off`,
  arg 2 = kind (default claude). Writes `@agent_state`, `@agent_ts`,
  `@agent_kind` pane options. `stop` decides unseen-vs-idle atomically
  server-side (`if -F` on pane_active+window_active+session_attached).
  Fail-soft: no tmux/no pane → exit 0 silently.
- **1.2 Transition guard** (inside 1.1). Rules:
  - `stop` legitimately clears `action`: approving a permission fires no
    hook, so the eventual Stop is the only end-of-turn signal.
  - `stop` arriving while state is already `unseen` keeps the older ts.
  - a `Notification` (→action) arriving ≤2 s after a `stop` is ignored
    (workmux flapping bug), via `@agent_prev` + `@agent_ts`.
- **1.3 `agents-recompute.sh`.** Scan `list-panes -a`, sessions (≠ current)
  with action/unseen; write `@agents_attention` as comma-joined names when
  ≤3 else count; unset when zero; `refresh-client -S`.
- **1.4 Claude adapter — `claude-install.sh`.** python3 JSON edit of
  `~/.claude/settings.json`: `UserPromptSubmit`→running,
  `PermissionRequest` + `Notification`(matcher `permission_prompt|idle_prompt`)
  →action, `Stop`→stop. Every command fail-soft:
  `[ -x "$S" ] && "$S" ... ; exit 0`, path via `$DOTFILES_DIR` env with
  literal fallback. Idempotent (re-run = no duplicates). `--remove` flag.
- **1.5 zsh wrapper.** `claude()` in .zshrc: `launch` on start, `off` on
  exit (survives kill -9 of the child). Guard: only when `$TMUX_PANE` set.
- **1.6 Focus-clear hook.** In .tmux.conf:
  `set-hook -g pane-focus-in { if -F '#{==:#{@agent_state},unseen}' '...' }`
  → `seen` + recompute, shell spawned only on real transitions.
- **1.7 Liveness sweep** (in `agents-scan.sh`). For each state-claiming pane:
  pane still exists AND an agent-ish process is alive in it, else clear.
  Clear ONLY on definitive pane-gone — never on tmux error/timeout
  (workmux #209).
- *Stage check:* scripted transition sequence passes; real Claude session in
  a pane shows running→unseen→idle via `tmux show -p`; `kill -9` the claude
  process → wrapper clears state.

## Stage 2 — window glyph + status module

- **2.1 Window glyph.** In theme.conf `window-status-format`(+current):
  after the index, `#{P:}`-scan of the window's panes, priority-matched
  (action > unseen > quiet), glyph colored via `@agent_color_*`.
  Pitfall: theme uses `set -gF` (source-time expansion) — write these
  fragments with `##{}` escaping or via unexpanded intermediate options.
- **2.2 Status module.** `@status_agents` defined in theme.conf (styling)
  rendering `#{E:@agents_attention}` with ghost + color, empty-when-unset;
  appended once to status-right in .tmux.conf (compose-once constraint,
  continuum untouched).
- *Stage check:* agent finishes in a background window → yellow ghost on
  that window + status item appears; focusing clears both; light and dark
  themes both correct; zero agents → status bar identical to today.

## Stage 3 — picker

- **3.1 `agents-scan.sh --list`.** TSV: sort-key, target (`sess:win.pane`),
  pane_id, kind, state, age (humanized from `@agent_ts`), plus derived
  markers: `running` >15 min → `stalled?`; `idle` >30 min sorts last.
  Runs the liveness sweep first.
- **3.2 Session-row symbols.** In the picker's session `reload`: join
  session list with per-session worst state (one scan + awk), ANSI-colored
  ghost in a trailing column; `fzf --ansi`; keep `{1}` = session name
  (existing binds depend on it). Mute glyph for muted sessions (stage 4).
- **3.3 Agents mode.** New `transform:` handler (key: see open decisions —
  NOT ctrl-a): reload from `--list`, preview `capture-pane -ep -t {pane_id}`,
  header with key hints, state-tag words in rows so fzf query filters
  (`'action`, `!idle`).
- **3.4 Jump.** Enter: `switch-client -t` + `select-window` + `select-pane`
  from the row's pane_id.
- **3.5 Kill.** `ctrl-x`: SIGTERM the pane's foreground agent process
  (child of `#{pane_pid}`), NOT kill-pane; reload after.
- **3.6 Reload.** `ctrl-r`: re-run `--list` (includes sweep).
- **3.7 Quick-prompt.** Key opens prompt (fzf `--print-query` trick or
  `execute(read ...)`): `send-keys -t <pane> -l "<text>" Enter`. Prompts
  only — never used to answer permission dialogs.
- **3.8 Direct entry.** Picker accepts `--mode agents`; bind `C-s a`.
  Popup-nesting guard: if already inside a popup, detach first.
- **3.9 `agents-jump.sh`** + bind `C-s n`: switch to highest-priority pane
  without the picker; repeated press cycles.
- *Stage check:* two fake agents in two sessions sort correctly, preview
  live, jump lands on exact pane, kill leaves shell alive, prompt lands in
  agent, `C-s a` works from inside and outside popups.

## Stage 4 — settings

- **4.1 `agents-settings.sh`.** `get|set|toggle|list` over
  `~/.local/state/tmux-agents/settings.tsv` keyed by session name; fields
  v1: `bell`, `notify`. mkdir-lock around writes. Global flags row
  (`bell`, `notify`, `notify_states` default `action`).
- **4.2 Mirroring.** File → session options (`@agents_bell`, `@agents_notify`)
  on `session-created` hook and `@resurrect-hook-post-restore-all`;
  `session-renamed` re-persists live options under the new name; lazy GC of
  names absent from `tmux ls` (stale keys harmless).
- **4.3 In-view toggles.** Agents view: one key toggles mute for the
  highlighted row's session (execute-silent + reload), mute glyph shown in
  the row; one key or pinned row for global mute.
- *Stage check:* mute session → kill-server → restore → still muted; rename
  session → settings follow.

## Stage 5 — alerts

- **5.1 Alert path** in `agent-state.sh action`: terminal bell
  (`printf '\a' > /dev/tty`) and/or macOS notification (osascript), gated:
  global flag && session flag && state ∈ `notify_states`. Never for stop.
- **5.2 Content.** Title `kind — session:window`; suppress when the tmux
  client is focused AND the pane is the active one (you're already looking).
- *Stage check:* permission prompt in background session rings once; muted
  session silent; `stop` never rings; alert while staring at the pane: none.

## Stage 6 — other agents (as needed)

- **6.1 opencode**: plugin js → `session.idle`→stop, `permission.asked`→action,
  same script.
- **6.2 Codex**: `notify` config →stop; approvals have no hook — accept
  wrapper + `pane_current_command` fallback fidelity.
- **6.3 Generic wrapper** `agent_wrap <kind> <cmd...>` for anything else.
- **6.4 Optional:** merge `claude agents --json` background sessions into
  the view (kill → `claude stop <id>`).

## Stage 7 — uninstall + docs

- **7.1 `uninstall.sh`**: remove hook entries (via `claude-install.sh
  --remove`), `set-hook -gu` every live hook this system registered, unset
  all `@agent*`/`@agents*` options everywhere, note the .zshrc/.tmux.conf
  lines to delete. Leaves Claude fully working.
- **7.2 README** (short): what it is, keys, states, uninstall.
- **7.3 shellcheck** clean on all scripts.

---

## Open decisions (Viktor)

1. In-picker key for agents mode (ctrl-a is taken by readline; candidates:
   `ctrl-g`, `ctrl-t`, `alt-a`).
2. Key for quick-prompt inside the view (`ctrl-s`?) and mute toggle (`ctrl-m`
   is Enter in terminals — avoid; `ctrl-b`?).
3. `C-s n` for jump-to-attention — OK, or another letter?
4. Stale thresholds: running→`stalled?` after 15 min? idle demotion after 30?
5. Pane-border coloring for the agent pane (extra visual channel): in or out?
6. macOS notification via osascript (no dependency) vs terminal-notifier
   (nicer, brew dependency)?

## Risks (from other tools' bug history)

| Risk | Mitigation |
|---|---|
| Hooks fire out of order → state flapping | transition guard (1.2) |
| Sweep deletes live state on flaky tmux call | clear only on definitive pane-gone (1.7) |
| Window activity clears unseen prematurely | clear on pane focus only (1.6) |
| `-gF` theme expansion mangles runtime formats | `##` escaping + render test (2.1) |
| Stale marker masks action/unseen | stale only ever demotes `running` (3.1) |
| Nested popup errors | detach guard (3.8) |
| Leftover live hooks after removal | uninstall unsets hooks explicitly (7.1) |

## Definition of done (v1 = stages 0–5)

Zero cost when idle (no polling, no daemons); every surface driven by one
state store; states never lie (focus clears, sweep validates, guard orders);
one glyph everywhere; silence when nothing needs you; full uninstall.

## v3 addendum — the bus refactor (2026-08-12, built)

V1's "no daemons" held until the layer's own growth broke it: policy
duplicated across four scripts drifted, and concurrent hook writers raced
on the same options. V3 replaces both with a spool-file event bus and a
resident single-writer daemon (`agentsd.sh`) that owns every transition,
sensor and derived fact; renderers went read-only. See SPEC.md "Data
flow" for the current architecture and `tests/run.sh` for the replay rig
that guards it. "Zero cost when idle" survives: the daemon parks on a
blocking read (zero wakeups with nothing tracked) and every other v1
guarantee — states never lie, silence when nothing needs you, full
uninstall — carries over.
