#!/usr/bin/env bash
# Full removal of the agents layer runtime pieces. Live tmux hooks outlive
# config and file deletion, so they are unset explicitly here.
# Config lines (in .tmux.conf, theme.conf, .zshrc) are listed at the end for
# manual removal — they are fail-soft and harmless if left.
set -u

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# AGENT_PANE_OPTS — the one list of pane options the layer writes. Removal
# must clear exactly what the daemon sets, so it is read, never retyped.
# Uninstalling from outside tmux is normal; the sourced file wants $TMUX set.
: "${TMUX:=}"
. "$DIR/agents-env.sh" 2>/dev/null || true

"$DIR/claude-install.sh" --remove 2>/dev/null && echo "removed Claude hooks"
"$DIR/agy-install.sh" --remove 2>/dev/null && echo "removed agy hooks"

rm -f "${XDG_CONFIG_HOME:-$HOME/.config}/opencode/plugins/tmux-agent-state.js" \
    && echo "removed opencode plugin"

# stop every agentsd (one per tmux server) and drop their runtime dirs
for d in "${XDG_STATE_HOME:-$HOME/.local/state}/tmux-agents"/*/; do
    [ -d "$d" ] || continue
    pid="$(cat "$d/agentsd.pid" 2>/dev/null)"
    [ -n "$pid" ] && kill "$pid" 2>/dev/null
    rm -rf "$d"
done
echo "stopped agentsd daemons"

if [ -n "${TMUX:-}" ] || tmux info >/dev/null 2>&1; then
    tmux set-hook -gu pane-focus-in 2>/dev/null
    tmux set-hook -gu client-session-changed 2>/dev/null
    echo "unset live tmux hooks (re-sourcing .tmux.conf restores them)"
    tmux list-panes -a -F '#{pane_id}' 2>/dev/null | while read -r p; do
        for o in $AGENT_PANE_OPTS; do
            tmux set -p -t "$p" -u "@agent_$o" 2>/dev/null
        done
    done
    tmux list-windows -a -F '#{window_id}' 2>/dev/null | while read -r w; do
        tmux set -w -t "$w" -u @agent_win_sig 2>/dev/null
    done
    tmux set -g -u @agents_any \; set -g -u @agents_n_running \; \
         set -g -u @agents_n_action \; set -g -u @agents_n_unseen \; \
         set -g -u @agents_n_stuck \; \
                 set -g -u @agents_n_running_cur \; set -g -u @agents_n_running_oth \; \
                 set -g -u @agents_n_action_cur \; set -g -u @agents_n_action_oth \; \
                 set -g -u @agents_n_unseen_cur \; set -g -u @agents_n_unseen_oth \; \
                 set -g -u @agents_n_stuck_cur \; set -g -u @agents_n_stuck_oth 2>/dev/null
    tmux refresh-client -S 2>/dev/null
    echo "cleared all agent state options"
fi

cat <<'EOF'

Manual leftovers (harmless if kept, all fail-soft):
  .tmux.conf   — "Agents layer" section (@agent_glyph, hooks, binds a/u,
                 the status-right tick and @status_agents appends)
  theme.conf   — @agent_color_*, @status_agents, and the @agent_win_sig
                 reference in window-status-format
  .zshrc       — _agent_wrap + claude/codex/opencode/gemini/agy wrappers
  ~/.codex/config.toml — notify line, if you added it
  ~/.local/state/tmux-agents/ — settings file
EOF
exit 0
