#!/usr/bin/env bash
# Per-session agent settings, keyed by session name so they survive tmux
# restarts (resurrect recreates sessions by name; it does NOT save options).
# File: one "session<TAB>key<TAB>value" line per setting. Session "*" = global.
# Every change is announced on the bus — the daemon re-derives and, when
# the master switch goes off, wipes every visible trace itself.
# Usage: agents-settings.sh get <session> <key>     (prints value or nothing)
#        agents-settings.sh toggle <session> <key>  (on <-> off, default off)
#        agents-settings.sh list
set -u

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FILE="${XDG_STATE_HOME:-$HOME/.local/state}/tmux-agents/settings.tsv"
mkdir -p "$(dirname "$FILE")" 2>/dev/null
[ -f "$FILE" ] || : > "$FILE"

cmd="${1:-}" sess="${2:-}" key="${3:-}"

announce() {
    [ -n "${TMUX:-}" ] || return 0
    . "$DIR/agents-env.sh" 2>/dev/null || return 0
    agents_emit settings.changed - system
}

# toggle-target: like toggle, but arg 2 is an agent target (sess:win.pane) —
# lets fzf binds stay free of nested command substitutions
if [ "$cmd" = toggle-target ]; then
    cmd=toggle
    sess="${sess%%:*}"
fi

case "$cmd" in
    get)
        awk -F'\t' -v s="$sess" -v k="$key" '$1 == s && $2 == k { print $3; exit }' "$FILE"
        ;;
    toggle)
        [ -n "$sess" ] && [ -n "$key" ] || exit 0
        cur="$(awk -F'\t' -v s="$sess" -v k="$key" '$1 == s && $2 == k { print $3; exit }' "$FILE")"
        new=on; [ "$cur" = on ] && new=off
        tmp="$FILE.tmp.$$"
        awk -F'\t' -v s="$sess" -v k="$key" '!($1 == s && $2 == k)' "$FILE" > "$tmp"
        printf '%s\t%s\t%s\n' "$sess" "$key" "$new" >> "$tmp"
        mv "$tmp" "$FILE"
        announce
        echo "$new"
        ;;
    list)
        cat "$FILE"
        ;;
    enable|disable)
        v=on; [ "$cmd" = disable ] && v=off
        tmp="$FILE.tmp.$$"
        awk -F'\t' '!($1 == "*" && $2 == "enabled")' "$FILE" > "$tmp"
        printf '*\tenabled\t%s\n' "$v" >> "$tmp"
        mv "$tmp" "$FILE"
        announce
        echo "agents layer: ${v}"
        ;;
esac
exit 0
