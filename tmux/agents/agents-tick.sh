#!/usr/bin/env bash
# Status-line tick: runs from a #() in status-right, once per
# status-interval. Watchdog for agentsd — the daemon owns every sensor
# (dialog probes, liveness sweep, stall stamping); this only makes sure it
# is alive and feeds it a heartbeat event so quiet stretches still drain.
# Prints nothing (a #() must stay invisible). Near-free: two stats and one
# list-panes.
set -u
[ -n "${TMUX:-}" ] || exit 0
DIR="${BASH_SOURCE[0]%/*}"
[ "$DIR" = "${BASH_SOURCE[0]}" ] && DIR=.
US=$'\x1f'
. "$DIR/agents-env.sh" 2>/dev/null || exit 0

now="${EPOCHSECONDS:-$(date +%s)}"
hb="$(stat -f %m "$AGENTS_HEARTBEAT" 2>/dev/null)" || hb=0

# watchdog first — a daemon wedged before its first drain must restart
# even while no pane carries state yet
pid=""
IFS= read -r pid < "$AGENTS_PID" 2>/dev/null || pid=""
if [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; then
    rm -f "$AGENTS_PID" 2>/dev/null
    "$DIR/agentsd.sh" >/dev/null 2>&1 &
elif [ $(( now - hb )) -gt 60 ] && [ "$AGENTS_SPOOL" -nt "$AGENTS_HEARTBEAT" ]; then
    # alive but not draining while events flow: wedged — replace it.
    # kill -9 because a wedge is by definition stuck inside a command;
    # facts live in tmux options, there is nothing graceful to save.
    kill -9 "$pid" 2>/dev/null
    rm -f "$AGENTS_PID" 2>/dev/null
    "$DIR/agentsd.sh" >/dev/null 2>&1 &
fi

# the tick only speaks when the daemon has actually gone quiet — status
# redraws run this every second during busy output, and a draining daemon
# needs no metronome
[ $(( now - hb )) -lt 3 ] && exit 0

states="$(tmux list-panes -a -F "#{pane_id}${US}#{@agent_state}" 2>/dev/null)" || exit 0
case "$states" in *"${US}"[a-z]*) ;; *) exit 0 ;; esac

# wakes the daemon while agents exist: backstops a lost doorbell edge and
# drives the sweep/stall cadence when attached
agents_emit tick - system
exit 0
