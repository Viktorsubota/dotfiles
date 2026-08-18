#!/usr/bin/env bash
# Normalized dump of everything the daemon derives, for golden diffing.
# Timestamps print as offsets from $TEST_NOW so goldens are stable.
# Requires $TMUX pointing at the scratch server.
set -u
US=$'\x1f'
now="${TEST_NOW:?}"

echo "== panes"
tmux list-panes -a -F "#{pane_id}${US}#{@agent_state}${US}#{@agent_ts}${US}#{@agent_prev}${US}#{@agent_kind}${US}#{@agent_class}${US}#{@agent_rank}${US}#{@agent_mod}${US}#{@agent_sid}${US}#{@agent_msg}" 2>/dev/null \
| sort \
| while IFS="$US" read -r p st ts prev kind cls rank mod sid msg; do
    rel=""
    [ -n "$ts" ] && rel=$(( ts - now ))
    printf '%s state=%s ts=%s prev=%s kind=%s cls=%s rank=%s mod=%s sid=%s msg=%s\n' \
        "$p" "$st" "$rel" "$prev" "$kind" "$cls" "$rank" "$mod" "$sid" "$msg"
done

echo "== globals"
tmux show -g 2>/dev/null | grep '^@agents_' | LC_ALL=C sort

echo "== winsig"
tmux list-windows -a -F "#{window_id}${US}#{@agent_win_sig}" 2>/dev/null \
| sort \
| while IFS="$US" read -r w sig; do
    printf '%s sig=%s\n' "$w" "$sig"
done
