#!/usr/bin/env bash
# C-s b "back": return to the previously focused location — across sessions,
# windows and panes — and re-zoom it if it was zoomed when you left. Depth-one
# history kept by the track hooks (pane-focus-in / client-session-changed).
# Jumping back is itself a focus change, so pressing back again toggles
# between the two most recent spots. Fail-soft: outside tmux or on any
# error, exit 0 silently.
set -u
[ -n "${TMUX:-}" ] || exit 0

US=$'\x1f'

case "${1:-}" in
    track)
        new="${2:-}"
        [ -n "$new" ] || exit 0
        cur="$(tmux show -gqv @nav_cur 2>/dev/null)"
        [ "$cur" = "$new" ] && exit 0
        if [ -n "$cur" ]; then
            # zoom is captured at departure: leaving a window keeps its zoom,
            # so the flag is still readable through the old pane id. (Pane
            # switches INSIDE a window unzoom before this hook runs — those
            # departures record unzoomed, which matches what you saw last.)
            z="$(tmux display -p -t "$cur" '#{window_zoomed_flag}' 2>/dev/null || true)"
            tmux set -g @nav_prev "${cur}${US}${z:-0}" 2>/dev/null
        fi
        tmux set -g @nav_cur "$new" 2>/dev/null
        ;;
    back)
        IFS="$US" read -r pane zoom <<< "$(tmux show -gqv @nav_prev 2>/dev/null)"
        [ -n "${pane:-}" ] || { tmux display-message "No previous location" 2>/dev/null; exit 0; }
        if ! tmux display -p -t "$pane" '' >/dev/null 2>&1; then
            tmux display-message "Previous location is gone" 2>/dev/null
            exit 0
        fi
        tmux select-window -t "$pane" \; select-pane -t "$pane" \; \
             switch-client -t "$pane" 2>/dev/null
        if [ "${zoom:-0}" = 1 ] && \
           [ "$(tmux display -p -t "$pane" '#{window_zoomed_flag}' 2>/dev/null)" = 0 ]; then
            tmux resize-pane -Z -t "$pane" 2>/dev/null
        fi
        ;;
esac
exit 0
