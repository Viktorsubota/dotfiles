#!/usr/bin/env bash
# Actions on agent panes, driven from the picker:
#   --kill T...  SIGTERM the agent process under each pane target
#   --diff T     git diff in the pane's cwd (preview)
#   --urgent T   toggle the urgent modifier
#   --mute T     toggle mute (tier-aware: session mute wins the toggle)
#   --disable T  toggle disabled
# Modifier toggles are bus events — the daemon applies the exclusivity
# law and the tier logic, then this waits for its drain (heartbeat bump)
# so the picker's reload renders the new class, not the old one.

set -u
[ -n "${TMUX:-}" ] || exit 0
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/agents-env.sh" 2>/dev/null || exit 0

# prints the pid of the first process under root matching kind; rc 1 if none
find_agent_pid() { # <pane_root_pid> <kind>
    local ps_snapshot
    ps_snapshot="$(ps -axo pid=,ppid=,comm= 2>/dev/null)" || return 1
    [ -n "$ps_snapshot" ] || return 1
    awk -v root="$1" -v kind="$2" '
        {
            id = $1; pp = $2
            sub(/^[ \t]*[0-9]+[ \t]+[0-9]+[ \t]+/, "")
            comm[id] = $0; ppid[id] = pp; alive[id] = 1
        }
        END {
            if (!(root in alive)) exit 1   # pid gone from ps? doubt -> caller keeps state
            n = 0; q[n++] = root
            for (i = 0; i < n; i++) {
                p = q[i]
                base = comm[p]; sub(/.*\//, "", base)
                if (tolower(base) ~ tolower(kind)) { print p; exit 0 }
                for (c in ppid) if (ppid[c] == p) q[n++] = c
            }
            exit 1
        }' <<< "$ps_snapshot"
}

toggle() { # <event> <target> — emit, then wait for the daemon to apply it
    # The heartbeat carries a drain counter. A drain in flight at emit time
    # may have already passed the spool's EOF, so one bump proves nothing;
    # two drains past the starting count means one whole drain began after
    # the emit — the toggle is applied. Re-ring the doorbell while waiting:
    # signals toggle (a pair landing with no waiter cancels) and the ack
    # cannot afford to sit out the 5s tick backstop.
    local c0 c i
    IFS= read -r c0 < "$AGENTS_HEARTBEAT" 2>/dev/null || c0=0
    case "$c0" in ''|*[!0-9]*) c0=0 ;; esac
    agents_emit "$1" "$2" claude
    for i in $(seq 1 70); do
        IFS= read -r c < "$AGENTS_HEARTBEAT" 2>/dev/null || c=0
        case "$c" in ''|*[!0-9]*) c=0 ;; esac
        [ "$c" -ge $((c0 + 2)) ] && break
        [ $((i % 8)) -eq 2 ] && tmux wait-for -S agents 2>/dev/null
        sleep 0.01
    done
    return 0
}

case "${1:-}" in
    --urgent)
        [ -n "${2:-}" ] && toggle user.urgent "$2"
        exit 0 ;;
    --mute)
        [ -n "${2:-}" ] && toggle user.mute "$2"
        exit 0 ;;
    --disable)
        [ -n "${2:-}" ] && toggle user.disable "$2"
        exit 0 ;;
    --send)
        # a prompt typed at a dead agent's pane would execute in its
        # shell as commands — verify the agent process first
        target="${2:-}"; text="${3:-}"
        [ -n "$target" ] && [ -n "$text" ] || exit 0
        pane_pid="$(tmux display -p -t "$target" '#{pane_pid}' 2>/dev/null)" || exit 0
        kind="$(tmux display -p -t "$target" '#{@agent_kind}' 2>/dev/null)"
        if ! find_agent_pid "$pane_pid" "${kind:-claude}" >/dev/null; then
            tmux display-message -d 2500 "Agent gone — prompt NOT sent" 2>/dev/null
            exit 0
        fi
        tmux send-keys -t "$target" -l -- "$text" \; send-keys -t "$target" Enter 2>/dev/null
        exit 0 ;;
    --diff)
        d="$(tmux display -p -t "${2:-}" '#{pane_current_path}' 2>/dev/null)"
        [ -n "$d" ] && git -C "$d" diff --color=always 2>/dev/null || echo "no git diff"
        exit 0 ;;
    --kill)
        shift
        for target in "$@"; do
            pane_pid="$(tmux display -p -t "$target" '#{pane_pid}' 2>/dev/null)" || continue
            kind="$(tmux display -p -t "$target" '#{@agent_kind}' 2>/dev/null)"
            pid="$(find_agent_pid "$pane_pid" "${kind:-claude}")" || continue
            [ -n "$pid" ] && kill -TERM "$pid" 2>/dev/null
        done
        exit 0 ;;
esac
exit 0
