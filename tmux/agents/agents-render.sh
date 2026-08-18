#!/usr/bin/env bash
# Pure presentation over agent panes — reads facts (@agent_state/ts/kind/
# name) and the daemon-derived policy (@agent_class/@agent_rank/@agent_mod),
# writes nothing, decides nothing:
#   --list      US-separated: sortkey, target, pane_id, kind, state, class, age, mod, name
#   --rows      fzf display rows: target, glyph(ANSI), state, name, kind, age, mod
#   --sessions  session list annotated with worst-state glyph (for the picker)
# Closeness (current window/session sorts first) is viewer-relative and
# lives here; everything modifier-shaped arrives pre-chewed in class/mod.

set -u
[ -n "${TMUX:-}" ] || exit 0

now="$(date +%s)"
IDLE_OLD_SECS=1800  # idle older than this sorts last
US=$'\x1f'  # field separator for tmux -F output: tab is IFS
            # whitespace and bash read collapses empty fields

age_str() { # sets AGE — no subshell, this runs once per pane
    local s=$(( now - ${1:-$now} ))
    if   [ "$s" -lt 60 ];    then AGE="${s}s"
    elif [ "$s" -lt 3600 ];  then AGE="$(( s / 60 ))m"
    elif [ "$s" -lt 86400 ]; then AGE="$(( s / 3600 ))h"
    else AGE="$(( s / 86400 ))d"; fi
}

hex2ansi_var() { # "#rrggbb" varname -> truecolor fg escape, fork-free
    local h="${1#\#}"
    printf -v "$2" '\033[38;2;%d;%d;%dm' "0x${h:0:2}" "0x${h:2:2}" "0x${h:4:2}" 2>/dev/null
}

# Everything scalar in one server round-trip: colors, glyph, viewer
# position for closeness, client width (per-row show calls add up)
load_display_opts() {
    IFS="$US" read -r glyph c_action c_unseen c_running c_stalled c_quiet \
        CUR_SESS CUR_WIN CW < <(tmux display -p \
        "#{@agent_glyph}${US}#{@agent_color_action}${US}#{@agent_color_unseen}${US}#{@agent_color_running}${US}#{@agent_color_stalled}${US}#{@agent_color_quiet}${US}#{session_name}${US}#{window_index}${US}#{client_width}" 2>/dev/null)
    glyph="${glyph:-*}"
    CW="${CW:-200}"
    hex2ansi_var "$c_action" a_action; hex2ansi_var "$c_unseen" a_unseen
    hex2ansi_var "$c_running" a_running; hex2ansi_var "$c_stalled" a_stalled
    hex2ansi_var "$c_quiet" a_quiet
}

class_color() { # sets COL and TCOL for a class — attention tints its target too
    TCOL=""
    case "$1" in
        alert) COL="$a_action"; TCOL="$COL" ;;
        warn)  COL="$a_unseen"; TCOL="$COL" ;;
        busy)  COL="$a_running" ;;
        stale) COL="$a_stalled" ;;
        *)     COL="$a_quiet" ;;
    esac
}

list_raw() { # US-separated: sortkey, target, pane_id, kind, state, class, age, mod, name
    # sortkey = class-order . urgency-bit . closeness (window > session > elsewhere) . age
    tmux list-panes -a \
        -F "#{pane_id}${US}#{session_name}${US}#{window_index}${US}#{pane_index}${US}#{@agent_state}${US}#{@agent_prev}${US}#{@agent_ts}${US}#{@agent_kind}${US}#{@agent_class}${US}#{@agent_rank}${US}#{@agent_mod}${US}#{pane_current_command}${US}#{@agent_name}" \
        2>/dev/null \
    | while IFS="$US" read -r pane_id sess win pidx state prev ts kind cls rank mod cmd name; do
        if [ -z "$state" ]; then
            # untracked agents (started without wrapper/hooks, or layer
            # disabled) still show up in the agents view, states unknown
            case "$cmd" in
                claude|codex|opencode|gemini|aider|agy) state="-" kind="$cmd" cls="" ;;
                *) continue ;;
            esac
        fi
        # an idle-wait is an open conversation, not a pending dialog — the
        # label says so; the widget and jump already tell the same story
        [ "$state" = action ] && [ "$prev" = waiting ] && state=waiting
        local prio ubit=1 dist=2
        case "$cls" in
            alert)  prio=0 ;;
            warn)   prio=1 ;;
            busy)   prio=2 ;;
            stale)  prio=3 ;;
            quiet)
                prio=4
                [ -n "$ts" ] && [ $(( now - ts )) -gt "$IDLE_OLD_SECS" ] && prio=5
                ;;
            hidden) prio=6 ;;
            *)      prio=7 ;;
        esac
        [ "$rank" = 0 ] && ubit=0
        if [ "$sess" = "$CUR_SESS" ]; then
            dist=1
            [ "$win" = "$CUR_WIN" ] && dist=0
        fi
        age_str "$ts"
        # \x1f separators, NOT tabs: read with tab-IFS collapses the empty
        # mod field and shifts name left (the documented bash trap)
        printf "%s.%s.%s.%010d${US}%s:%s.%s${US}%s${US}%s${US}%s${US}%s${US}%s${US}%s${US}%s\n" \
            "$prio" "$ubit" "$dist" $(( 9999999999 - ${ts:-0} )) \
            "$sess" "$win" "$pidx" "$pane_id" "${kind:-?}" "$state" "$cls" "$AGE" \
            "$mod" "$name"
    done | sort -t. -k1,1 -k2,2 -k3,3 -k4,4n
}

case "${1:-}" in
    --list)
        load_display_opts
        list_raw ;;
    --rows)
        load_display_opts
        reset=$'\033[0m'
        faint=$'\033[2m'
        rows_src="$(list_raw)"
        [ -n "$rows_src" ] || exit 0
        # columns size to content: location as narrow as the longest target,
        # name up to 16; tighter caps when the popup will be cramped
        if [ $(( CW * 65 / 100 )) -lt 90 ]; then tcap=18 ncap=8 kw=6; else tcap=30 ncap=16 kw=8; fi
        IFS=$'\t' read -r tw nw < <(awk -F "$US" -v tc="$tcap" -v nc="$ncap" '
            length($2) > t { t = length($2) }
            length($9) > n { n = length($9) }
            END {
                t = t < 12 ? 12 : t; n = n < 4 ? 4 : n
                print (t > tc ? tc : t) "\t" (n > nc ? nc : n)
            }' <<< "$rows_src")
        while IFS="$US" read -r _ target pane_id kind state cls agestr mod name; do
            class_color "$cls"
            modcol="$faint"
            [ "$mod" = urgent ] && modcol="$a_action"
            printf "%s%-${tw}s%s  %s%s %-9s%s  %-${nw}.${nw}s  %-${kw}.${kw}s  %s%-4s%s %s%-6s%s\n" \
                "$TCOL" "$target" "$reset" "$COL" "$glyph" "$state" "$reset" \
                "${name:--}" "$kind" "$faint" "$agestr" "$reset" "$modcol" "$mod" "$reset"
        done <<< "$rows_src" ;;
    --sessions)
        load_display_opts
        # one awk pass: join session list with worst class (min prio wins;
        # prio already carries the modifier law), colorize inline
        { list_raw; echo "==="; tmux list-sessions -F '#{session_name}' 2>/dev/null; } \
        | awk -F "$US" -v glyph="$glyph" -v reset=$'\033[0m' \
              -v ca="$a_action" -v cu="$a_unseen" -v cr="$a_running" \
              -v cs="$a_stalled" -v cq="$a_quiet" '
            /^===$/ { part = 1; next }
            !part {
                split($1, a, "."); s = $2; sub(/:.*/, "", s)
                if (!(s in p) || a[1] < p[s]) p[s] = a[1]
                next
            }
            {
                if ($1 in p) {
                    # a stuck agent must not paint its session as working
                    c = (p[$1] == 0) ? ca : (p[$1] == 1) ? cu : (p[$1] == 2) ? cr : (p[$1] == 3) ? cs : cq
                    # glyph sits LEFT of the name; plain rows indent to align.
                    # The name is therefore always the LAST field -> pickers
                    # reference sessions by {-1}, never {1}.
                    print c glyph reset " " $1
                } else print "  " $1
            }' ;;
    *)
        : ;;
esac
exit 0
