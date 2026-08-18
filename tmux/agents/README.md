# tmux agents

AI coding agents surfaced in tmux: who's working, who's waiting on you,
where — with zero cost when nothing changes. Design: SPEC.md; build: PLAN.md.

## Architecture

Three decoupled layers around a resident daemon (`agentsd.sh`, bash ≥ 4,
one per tmux server; on stock bash 3.2 the layer stays inert):

1. **Emitters** append one line per event to a spool file (`>>` never
   blocks — a dead daemon can never stall an agent CLI) and ring a
   `tmux wait-for` doorbell. `agent-state.sh` is the adapter entry for
   hooks; the picker's toggles and settings changes ride the same bus.
2. **agentsd.sh** is the single writer: it drains the spool, applies every
   transition and guard, runs the sensors in-loop (0.5s attended-dialog screen
   probes, liveness sweep, stall stamping), and derives the policy once —
   `@agent_class` (alert/warn/busy/stale/quiet/hidden), `@agent_rank`
   (jump sortkey) and `@agent_mod` per pane, plus widget counts and tab
   signals. One `refresh-client` per drain, only when something changed.
3. **Renderers** (`agents-render.sh`, `agents-jump.sh`, theme formats)
   read facts and derived policy, write nothing, decide nothing beyond
   viewer-relative closeness. `agents-ctl.sh` holds the actions.

Facts live in tmux pane options — the server is the database, `tmux show`
the debugger; the daemon rebuilds everything from them after a restart.
The status tick doubles as watchdog. Tests: `tests/run.sh` replays fixture
event streams through `agentsd.sh --replay` against golden option dumps.

## States

| state | color | meaning | clears by |
|---|---|---|---|
| action (dialog) | red | a permission dialog blocks the agent | answering (tool runs), turn end, or the dialog leaving the screen — NOT by looking |
| action (waiting) | yellow | idle, waiting for your next message — never shown on the pane you are in | visiting the pane, or your next prompt |
| unseen | yellow | finished, result unread | focusing the pane |
| running | green | working | — |
| idle | dim | alive, nothing to report | — |

Red means exactly one thing: something is blocked on you.

Urgent agents (`ctrl-t` in the picker): always red while needing attention,
always make noise, bypass mutes.

## Surfaces

- Tabs: the leading space of each window tab is the only per-tab signal —
  red when a pane in it has a blocking dialog (or urgent event), yellow
  for muted awaits or a native bell.
- Status-right widget: ghost head with fleet total, running and unseen
  segments as `current:elsewhere`, red await pill and stuck pill only
  when nonzero. Hidden when no agents. Click opens the view.
- Session rows in `C-s s` carry a worst-state-colored ghost.
- Bell + optional macOS notification on blocking dialogs and urgent
  events only — yellow states are silent.

## Keys

- `C-s a` — agents view · `C-s u` — always-jump to the top target
  (standing on it = no-op) · click the status widget — agents view
- In the view: `enter` jump · `ctrl-e` send prompt · `ctrl-x` kill agent ·
  `ctrl-t` urgent · `ctrl-b` mute · `ctrl-q` disable · `ctrl-o` dismiss ·
  `ctrl-r` name · `ctrl-l` refresh · `ctrl-v` output/diff preview ·
  `ctrl-a`/`ctrl-s` switch views

## Agents

Claude Code (hooks, installed by `claude-install.sh` — full fidelity),
opencode (plugin, `opencode-plugin.js` → `~/.config/opencode/plugins/`),
agy/Antigravity (hooks in `~/.gemini/config/hooks.json`, installed by
`agy-install.sh` — running/stop only: agy exposes no permission or idle
events, so agy agents never go red), Codex (`codex-notify.sh`,
turn-complete only, see its header for config.toml lines), Gemini CLI
(hooks: `AfterAgent` → `agent-state.sh stop gemini`, `Notification` →
`action`), aider (`notifications-command: agent-state.sh stop aider` in
`~/.aider.conf.yml`). All get launch/cleanup via the `.zshrc` wrappers.
Anything else: call `agent-state.sh <state> <kind>` from the pane.

## Settings

`~/.local/state/tmux-agents/settings.tsv` — keyed by session NAME (survives
restarts; states themselves are deliberately ephemeral).
`agents-settings.sh get|toggle|list|enable|disable`.

Three mute scopes: **agent** (`ctrl-b` on an agent row — pane-scoped, dies
with the pane), **session** (`ctrl-b` on a session row), **global**
(`agents-settings.sh toggle '*' mute`). Urgent agents ignore all three.

Master switch: `agents-settings.sh disable` turns the whole layer off —
hooks become no-ops and every marker is wiped instantly; `enable` restores.
`ctrl-o` on an agent row dismisses a stuck red state (ESC inside an agent
fires no hook — verified — so tmux cannot see it; red otherwise self-heals
on your next prompt to that agent).

## Uninstall

`./uninstall.sh` — removes hooks (incl. live tmux hooks, which outlive file
deletion), plugin, state options; prints the manual config leftovers.
