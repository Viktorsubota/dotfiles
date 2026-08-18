#!/usr/bin/env bash
# State transitions for AI agent panes (SPEC.md). Agent-agnostic: adapters
# (Claude hooks, opencode plugin, shell wrappers) all call this. A pure
# emitter: one line appended to the spool, one doorbell — agentsd.sh, the
# single writer, applies the transition and every guard.
# Usage: agent-state.sh <running|action|waiting|stop|seen|launch|off|dismiss|escheck> [kind] [pane]
# pane arg is for tmux hooks (run-shell does not set TMUX_PANE — pass
# #{hook_pane}). Fail-soft: outside tmux or on any error, exit 0 silently —
# a broken dotfiles checkout must never break an agent CLI.

set -u

pane="${3:-${TMUX_PANE:-}}"
[ -n "$pane" ] && [ -n "${TMUX:-}" ] || exit 0

event="${1:-}"
kind="${2:-claude}"

# parameter expansion, not a cd-subshell — this runs per tool call of
# every agent; hooks invoke by absolute path so the strip is safe
DIR="${BASH_SOURCE[0]%/*}"
[ "$DIR" = "${BASH_SOURCE[0]}" ] && DIR=.
. "$DIR/agents-env.sh" 2>/dev/null || exit 0

# master switch: `agents-settings.sh disable` turns the whole layer off
agents_setting '*' enabled
[ "$AGENTS_VAL" = off ] && exit 0

# hook payload on stdin: session_id pins the pane to its first agent (a
# nested headless claude inside a tool call must not flap the state) and
# message carries what is being asked. ONLY hook-borne verbs may read —
# launch/off come from shell wrappers whose stdin is the user's pipe
# into the CLI itself (git diff | claude), and reading would eat it.
extra=""
case "$event" in running|action|waiting|stop) payload_ok=1 ;; *) payload_ok="" ;; esac
if [ -n "$payload_ok" ] && [ ! -t 0 ]; then
    payload=""
    IFS= read -r -t 0.2 -d '' payload || true
    sid=""; msg=""
    [[ $payload =~ \"session_id\":\"([^\"]+)\" ]] && sid="${BASH_REMATCH[1]}"
    [[ $payload =~ \"message\":\"([^\"]+)\" ]] && msg="${BASH_REMATCH[1]}"
    if [ -n "$sid" ]; then
        msg="${msg//[$'\t\n\r']/ }"
        extra="$sid $msg"
    fi
fi

case "$event" in
    running) agents_emit turn.work "$pane" "$kind" "$extra" ;;
    launch)  agents_emit agent.launch "$pane" "$kind" "$extra" ;;
    action)  agents_emit ask.permission "$pane" "$kind" "$extra" ;;
    waiting) agents_emit ask.input "$pane" "$kind" "$extra" ;;
    stop)    agents_emit turn.end "$pane" "$kind" "$extra" ;;
    seen)    agents_emit focus.enter "$pane" "$kind" ;;
    dismiss) agents_emit user.dismiss "$pane" "$kind" ;;
    off)     agents_emit agent.exit "$pane" "$kind" ;;
    resync)  agents_emit resync - system ;;
    escheck)
        # probe request: the daemon screen-checks the pane (dialog-class
        # reds only) and clears the red when the markers are gone
        agents_emit sense.probe "$pane" "$kind"
        ;;
esac
exit 0
