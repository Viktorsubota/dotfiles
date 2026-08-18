# agents-env.sh — shared paths + event emission for the agents layer.
# Sourced, never executed; callers need $TMUX set. Everything here is
# fail-soft: emission errors are swallowed — a broken or absent layer must
# never break an agent CLI.
#
# The bus: one spool file per tmux server (keyed by socket path, so a
# scratch test server never shares state with the real one). Emitters
# append one line and ring the doorbell; agentsd.sh is the single writer
# of all agent state.

# parameter expansion, not a cd-subshell: this file is always sourced by
# absolute path, so the prefix strip cannot produce a bare name
AGENTS_DIR="${BASH_SOURCE[0]%/*}"
AGENTS_STATE="${XDG_STATE_HOME:-$HOME/.local/state}/tmux-agents"
AGENTS_SETTINGS="$AGENTS_STATE/settings.tsv"
_agents_sock="${TMUX%%,*}"
AGENTS_RUN="$AGENTS_STATE/${_agents_sock//\//%}"
AGENTS_SPOOL="$AGENTS_RUN/spool"
AGENTS_PID="$AGENTS_RUN/agentsd.pid"
AGENTS_HEARTBEAT="$AGENTS_RUN/heartbeat"

# Every pane-scoped option the layer writes, in one place: reaping an agent,
# wiping the layer and uninstalling all read from here. Three hand-kept
# copies had already drifted apart — a reaped pane kept its name and passed
# it to the next agent to land there.
AGENT_PANE_OPTS="state ts prev kind urgent mute disabled class rank mod name sid msg"

agents_setting() { # <session|*> <key> — sets AGENTS_VAL, fork-free: the
    # settings file is a handful of lines and this runs per hook event
    local s k v
    AGENTS_VAL=""
    [ -f "$AGENTS_SETTINGS" ] || return 0
    while IFS=$'\t' read -r s k v; do
        [ "$s" = "$1" ] && [ "$k" = "$2" ] && AGENTS_VAL="$v"
    done < "$AGENTS_SETTINGS"
    return 0
}

# Spool line: v1 \t ts \t event \t pane \t kind \t extra
agents_emit() { # <event> <pane> [kind] [extra]
    local line
    [ -d "$AGENTS_RUN" ] || mkdir -p "$AGENTS_RUN" 2>/dev/null || return 0
    # one variable, one printf, one write(2): O_APPEND keeps concurrent
    # emitters' lines intact
    printf -v line 'v1\t%s\t%s\t%s\t%s\t%s' \
        "${EPOCHSECONDS:-$(date +%s)}" "$1" "$2" "${3:-claude}" "${4:-}"
    printf '%s\n' "$line" >> "$AGENTS_SPOOL" 2>/dev/null || return 0
    # doorbell is advisory only — wait-for signals toggle (an even count
    # landing while nobody waits cancels out), so the daemon level-triggers
    # off the spool itself and the status tick backstops a lost edge
    tmux wait-for -S agents 2>/dev/null
    if [ "${AGENTS_AUTOSTART:-1}" != 0 ] && ! [ -s "$AGENTS_PID" ]; then
        "$AGENTS_DIR/agentsd.sh" >/dev/null 2>&1 &
    fi
    return 0
}
