#!/usr/bin/env bash
# C-s u: always-jump triage — straight to the agent that most needs you;
# never opens the view (that's C-s a). The daemon pre-computes the policy
# in @agent_rank (a band: 0 urgent-pending, 1 await, 2 unseen incl
# muted awaits, 3 stuck; unset = not a target); this only adds viewer
# closeness — current session splits each band ahead of elsewhere — and
# takes oldest-in-state first inside each.
# u is anchored to the TOP target only: standing on it already means the
# press does nothing (user's rule — no walking down the queue). Successful
# jumps are silent; only no-ops with nothing anywhere speak ("All clear").
# Dead targets are skipped for the next candidate. --dry prints instead
# of jumping.
set -u
[ -n "${TMUX:-}" ] || exit 0
US=$'\x1f'
now="${EPOCHSECONDS:-$(date +%s)}"
dry=""
[ "${1:-}" = "--dry" ] && dry=1

IFS="$US" read -r cur_pane cur_sess < <(tmux display -p \
    "#{pane_id}${US}#{client_session}" 2>/dev/null) || true

n_running=0
total=0
candidates=""   # band US age US pane US session:window US label US name
while IFS="$US" read -r pane sess win state prev ts rank cls name; do
    # disabled agents are invisible to the crumb count too
    [ "$state" = running ] && [ "$cls" != hidden ] && n_running=$((n_running + 1))
    [ -n "$rank" ] || continue
    band="$rank"
    case "$ts" in ''|*[!0-9]*) age=0 ;; *) age=$(( now - ts )) ;; esac
    if [ "$band" = 0 ]; then
        final=0
    else
        final=$(( band * 2 - 1 ))
        [ "$sess" = "$cur_sess" ] || final=$(( final + 1 ))
    fi
    # band-2 awaits tell the yellow story: an idle-wait says waiting, a
    # muted dialog await says unseen
    label="$state"
    if [ "$band" = 2 ] && [ "$state" = action ]; then
        label=unseen
        [ "$prev" = waiting ] && label=waiting
    fi
    candidates+="${final}${US}${age}${US}${pane}${US}${sess}:${win}${US}${label}${US}${name}"$'\n'
    total=$((total + 1))
done < <(tmux list-panes -a -F "#{pane_id}${US}#{session_name}${US}#{window_index}${US}#{@agent_state}${US}#{@agent_prev}${US}#{@agent_ts}${US}#{@agent_rank}${US}#{@agent_class}${US}#{@agent_name}" 2>/dev/null)

msg() { tmux display-message -d 1800 "$1" 2>/dev/null; }

if [ "$total" -eq 0 ]; then
    [ -n "$dry" ] && { echo "DRY: All clear · ${n_running} running"; exit 0; }
    msg "All clear · ${n_running} running"
    exit 0
fi

humanize() {
    if [ "$1" -lt 60 ]; then printf '%ss' "$1"
    elif [ "$1" -lt 3600 ]; then printf '%sm' $(( $1 / 60 ))
    else printf '%sh' $(( $1 / 3600 )); fi
}

if [ -n "$dry" ]; then
    echo "DRY candidate order (band/age/pane/loc/state):"
    printf '%s' "$candidates" | sort -t "$US" -k1,1n -k2,2nr | tr "$US" '|'
fi

while IFS="$US" read -r _band age pane loc state name; do
    tmux display -p -t "$pane" '' >/dev/null 2>&1 || continue
    if [ "$pane" = "$cur_pane" ]; then
        # already on the most urgent thing — do nothing at all
        [ -n "$dry" ] && echo "DRY: already on the top target ($loc)"
        exit 0
    fi
    label="$state"
    [ "$state" = action ] && label="await"
    rest=$(( total - 1 ))
    more=""
    [ "$rest" -gt 0 ] && more=" · ${rest} more"
    crumb="→ ${label} $(humanize "$age") · ${loc}${name:+ (${name})}${more} · b=back"
    if [ -n "$dry" ]; then
        echo "DRY would jump: $pane ($loc, $state) — \"$crumb\""
        exit 0
    fi
    # successful jumps are silent (user's call): the scene change is the
    # confirmation, the bar shows where. Only no-ops speak.
    tmux select-window -t "$pane" \; select-pane -t "$pane" \; \
         switch-client -t "$pane" 2>/dev/null
    exit 0
done < <(printf '%s' "$candidates" | sort -t "$US" -k1,1n -k2,2nr)

msg "Agents vanished mid-jump — all clear now"
exit 0
