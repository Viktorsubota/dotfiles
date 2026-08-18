#!/usr/bin/env bash
# agentsd.sh — resident event daemon: the single writer of all agent state.
#
# Adapters append one line per event to the spool (>> to a regular file
# never blocks — a dead daemon can never stall a hook) and ring the
# doorbell (tmux wait-for -S agents). This loop drains the spool to EOF,
# applies every transition, derives the widget counts and tab signals,
# and repaints at most once per drain — only when derived facts changed.
#
# Facts live in tmux options: the server is the database, `tmux show` the
# debugger. A restart re-derives everything from them; the spool left by a
# dead daemon is replayed only if small (stale history is worse than a
# resync). The doorbell is latency, never correctness: wait-for signals
# TOGGLE on tmux 3.7b (a pair landing while nobody waits cancels out), so
# the loop drains until dry before parking and the status tick backstops
# the residual window. Any tmux command failure is terminal — the server
# is gone and a retry loop would only orphan the process.
#
# Events: turn.work ask.permission ask.input turn.end focus.enter
#         agent.launch agent.exit user.dismiss user.urgent user.mute
#         user.disable sense.probe sense.dialog_gone
#         tick resync settings.changed
#
# Sensors run in-loop: dialog-class reds are screen-probed each probe
# cycle while any exist (ESC on a dialog fires no hook), and a liveness sweep
# judges every tracked pane against one ps snapshot. Timers ride the park:
# the doorbell bridge converts wait-for signals into FIFO bytes so the
# daemon can block with a timeout; hooks never touch the FIFO (a FIFO
# write with no reader blocks — only the spool append is hook-safe).
#
# Usage: agentsd.sh            start; exits silently if a daemon is live
#        agentsd.sh --replay   apply events from stdin and exit — no lock,
#                              no park; event timestamps are the clock
set -u
[ -n "${TMUX:-}" ] || exit 0
# bash 5: assoc arrays, EPOCHSECONDS, and empty-array expansion under
# set -u (4.0-4.3 crash on those) — /bin/bash 3.2 stays inert
[ "${BASH_VERSINFO[0]:-3}" -ge 5 ] || exit 0

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/agents-env.sh" || exit 0
US=$'\x1f'
TAB=$'\t'
STALL_SECS=900
# ESC on a streaming Claude fires no hook at all — Stop means natural
# completion only — so an interrupted turn would sit at running until the
# stall stamp 15 minutes later. The pane title is the one witness: Claude
# spins a braille frame while it generates and wears this mark otherwise.
IDLE_MARK=$'✳'
# long enough that a turn whose first token is slow to arrive — the old
# title still showing — is never mistaken for an interrupted one
IDLE_SILENCE=10
# Claude spins a braille frame while it generates. Whether a range glob
# over a multibyte block works at all is the locale's business, and under
# C it can match far too much, so it is proved here rather than trusted:
# the spinner must match and the idle mark must not. Failing that, the
# title sensor stays off and hooks remain the only source — never a
# sensor that reports every calm pane as busy.
SPIN_OK=1
case $'⠐' in [$'⠀'-$'⣿']*) ;; *) SPIN_OK="" ;; esac
case "$IDLE_MARK" in [$'⠀'-$'⣿']*) SPIN_OK="" ;; esac
# error text that means a stalled agent is blocked on the user, not busy
FAULT_RE='API Error|Request failed|rate.?limit|credit balance|quota exceeded|overloaded_error|invalid api key'
PROBE_SECS=0.5   # park timeout while dialog-class reds need screen probes:
                 # ESC fires no hook, this cadence IS the dismiss latency.
                 # One capture-pane per open dialog per cycle — runs only
                 # while an unanswered permission dialog exists
BOOT_MAX_BYTES=65536
ROTATE_BYTES=1048576
ATT_FMT='#{&&:#{pane_active},#{&&:#{window_active},#{session_attached}}}'

REPLAY=""
[ "${1:-}" = "--replay" ] && REPLAY=1

mkdir -p "$AGENTS_RUN" 2>/dev/null || exit 0

NOW=0
NOW_MS=0
PARK_T=3600
PENDING_MAIN=""
PENDING_BOOT=""
LAST_DERIVED=""
FORCE_DERIVE=1
LAST_SWEEP=0
SPOOL_FD=""
BOOT_FD=""
BOOT_CYCLES=0
DB_FD=""
BRIDGE_PID=""
DOORBELL="$AGENTS_RUN/doorbell"
# every assoc array initialized: bash 5.3 treats a declared-but-never-
# assigned assoc as unbound under set -u the moment ${#arr[@]} is asked
declare -a EVENTS=() ARGS=() ALERTS=()
declare -A P_STATE=() P_TS=() P_PREV=() P_KIND=() P_URGENT=() P_MUTE=() \
           P_DIS=() P_SESS=() P_WIN=() P_TTY=() P_ATT=() P_PID=() P_TITLE=()
declare -A P_SIDS=() P_MSGO=() ALARM_TS=() DIALOG_RE=() HP_TS=()
declare -A RECHECK_TS=() RECHECK_N=() IP_CHECKED=()
# a hook-less turn.end's screen check can race the agent's own render (Stop
# fires before the new question has drawn) — a short, bounded retry ladder
# closes that gap instead of falling all the way back to the 20-30s
# silence probe every time
RECHECK_DELAYS=(3 5 10)

# per-kind approval-dialog screen patterns — data, not code: dialog text
# rots as agent UIs change. The claude row is also compiled in: a missing
# file must not stop claude reds from clearing on ESC.
DIALOG_RE[claude]='Do you want|Would you like|❯ 1'
while IFS=$'\t' read -r _k _re; do
    case "$_k" in ''|\#*) continue ;; esac
    DIALOG_RE[$_k]="$_re"
done < "$DIR/dialog-patterns.tsv" 2>/dev/null || true

# --- spool ------------------------------------------------------------------

# Persistent read fds: EOF on a regular file is not sticky, so one open fd
# sees every later append — no offsets, no truncation, no rename races.
read_fd_lines() { # <fd> <pending-varname> — appends whole lines to EVENTS
    local fd="$1" line
    local -n pend="$2"
    while IFS= read -r line <&"$fd"; do
        EVENTS+=("${pend}${line}")
        pend=""
    done
    # a partial tail (no newline yet) is an emitter mid-write: stash the
    # fragment — read consumed it — and glue it to the rest next drain
    pend+="$line"
}

boot_spool() {
    # events left by a dead daemon: replay if small, discard if large —
    # the resync that follows re-derives truth from pane options anyway
    if [ -s "$AGENTS_SPOOL" ]; then
        mv "$AGENTS_SPOOL" "$AGENTS_SPOOL.boot" 2>/dev/null
        if [ "$(( $(wc -c < "$AGENTS_SPOOL.boot" 2>/dev/null || echo 0) ))" -le "$BOOT_MAX_BYTES" ]; then
            exec {BOOT_FD}<"$AGENTS_SPOOL.boot"
        else
            rm -f "$AGENTS_SPOOL.boot"
        fi
    fi
    : >> "$AGENTS_SPOOL"
    exec {SPOOL_FD}<"$AGENTS_SPOOL"
}

collect_events() {
    EVENTS=()
    if [ -n "$BOOT_FD" ]; then
        read_fd_lines "$BOOT_FD" PENDING_BOOT
        # emitters holding a pre-rotation fd land in the renamed file;
        # keep its fd a few cycles as grace, then retire it
        BOOT_CYCLES=$((BOOT_CYCLES + 1))
        if [ "$BOOT_CYCLES" -ge 3 ]; then
            exec {BOOT_FD}<&-
            BOOT_FD=""
            rm -f "$AGENTS_SPOOL.boot"
        fi
    fi
    read_fd_lines "$SPOOL_FD" PENDING_MAIN
}

rotate_if_big() {
    # steady-state growth cap: rename the spool and open a fresh one; the
    # drained fd we already hold BECOMES the grace fd — emitters holding a
    # pre-rename fd land their lines there and the retire cycle reaps them
    [ -z "$BOOT_FD" ] || return 0
    [ "$(( $(wc -c < "$AGENTS_SPOOL" 2>/dev/null || echo 0) ))" -gt "$ROTATE_BYTES" ] || return 0
    mv "$AGENTS_SPOOL" "$AGENTS_SPOOL.boot" 2>/dev/null || return 0
    BOOT_FD="$SPOOL_FD"
    PENDING_BOOT="$PENDING_MAIN"
    PENDING_MAIN=""
    BOOT_CYCLES=0
    : >> "$AGENTS_SPOOL"
    exec {SPOOL_FD}<"$AGENTS_SPOOL"
}

# --- state ------------------------------------------------------------------

snapshot() { # all pane facts in one server round-trip
    local out p st ts prev kind urg mut dis sess win tty att ppid sid pmsg title
    # pane_title trails the row: it is free-form text, so anything odd in
    # it lands in the last field instead of shifting the ones that matter
    out="$(tmux list-panes -a -F "#{pane_id}${US}#{@agent_state}${US}#{@agent_ts}${US}#{@agent_prev}${US}#{@agent_kind}${US}#{@agent_urgent}${US}#{@agent_mute}${US}#{@agent_disabled}${US}#{session_name}${US}#{window_index}${US}#{pane_tty}${US}#{pane_pid}${US}#{@agent_sid}${US}#{@agent_msg}${US}${ATT_FMT}${US}#{pane_title}" 2>/dev/null)" || return 1
    P_STATE=(); P_TS=(); P_PREV=(); P_KIND=(); P_URGENT=(); P_MUTE=()
    P_DIS=(); P_SESS=(); P_WIN=(); P_TTY=(); P_ATT=(); P_PID=()
    P_SIDS=(); P_MSGO=(); P_TITLE=()
    while IFS="$US" read -r p st ts prev kind urg mut dis sess win tty ppid sid pmsg att title; do
        [ -n "$p" ] || continue
        P_STATE[$p]="$st"; P_TS[$p]="$ts"; P_PREV[$p]="$prev"
        P_KIND[$p]="$kind"; P_URGENT[$p]="$urg"; P_MUTE[$p]="$mut"
        P_DIS[$p]="$dis"; P_SESS[$p]="$sess"; P_WIN[$p]="$win"
        P_TTY[$p]="$tty"; P_PID[$p]="$ppid"; P_ATT[$p]="$att"
        P_SIDS[$p]="$sid"; P_MSGO[$p]="$pmsg"; P_TITLE[$p]="$title"
    done <<< "$out"
    return 0
}

clear_msg() { # <pane> — the stored question is stale once state moves on
    [ -n "${P_MSGO[$1]:-}" ] || return 0
    ARGS+=(set -p -t "$1" -u @agent_msg ";")
    P_MSGO[$1]=""
}

forget_pane() { # <pane> — exit and reap MUST tear down identically: every
    # option the layer writes (AGENT_PANE_OPTS), every in-memory trace
    local g
    for g in $AGENT_PANE_OPTS; do
        ARGS+=(set -p -t "$1" -u "@agent_$g" ";")
    done
    unset "P_STATE[$1]" "P_TS[$1]" "P_PREV[$1]" "P_KIND[$1]" \
          "HP_TS[$1]" "ALARM_TS[$1]" "RECHECK_TS[$1]" "RECHECK_N[$1]" \
          "IP_CHECKED[$1]" 2>/dev/null
    P_URGENT[$1]=""; P_MUTE[$1]=""; P_DIS[$1]=""
    P_SIDS[$1]=""; P_MSGO[$1]=""
}

w4() { # <pane> <state> <ts> <prev> <kind> — the full transition write
    ARGS+=(set -p -t "$1" @agent_state "$2" ";" \
           set -p -t "$1" @agent_ts "$3" ";" \
           set -p -t "$1" @agent_prev "$4" ";" \
           set -p -t "$1" @agent_kind "$5" ";")
    P_STATE[$1]="$2"; P_TS[$1]="$3"; P_PREV[$1]="$4"; P_KIND[$1]="$5"
}

w2() { # <pane> <state> <prev> — ts and kind untouched
    ARGS+=(set -p -t "$1" @agent_state "$2" ";" \
           set -p -t "$1" @agent_prev "$3" ";")
    P_STATE[$1]="$2"; P_PREV[$1]="$3"
}

set_msg() { # <pane> <text> — what the agent is asking, for notifications
    # and renderers; hard-truncated, control chars stripped structurally
    # (a \x1f would shift the snapshot's US-delimited fields)
    [ -n "$2" ] || return 0
    local m="${2:0:120}"
    m="${m//[[:cntrl:]]/ }"
    ARGS+=(set -p -t "$1" @agent_msg "$m" ";")
    P_MSGO[$1]="$m"
}

apply_event() { # <spool line>
    local ver ets ev pane kind extra ts0 esid="" emsg="" dline="" was_action
    IFS="$TAB" read -r ver ets ev pane kind extra <<< "$1"
    [ "$ver" = v1 ] || return 0
    case "$ets" in ''|*[!0-9]*) return 0 ;; esac
    [ -n "$REPLAY" ] && NOW="$ets"
    [ -n "$extra" ] && read -r esid emsg <<< "$extra"
    case "$ev" in
        tick) return 0 ;;
        resync) FORCE_DERIVE=1; return 0 ;;
        settings.changed)
            FORCE_DERIVE=1
            # master switch went off: wipe every visible trace; shims stop
            # emitting while it stays off, so the daemon just idles after.
            # Flush pending writes first — the wipe must land after every
            # transition already in this drain, not before.
            agents_setting '*' enabled
            if [ "$AGENTS_VAL" = off ]; then
                apply_batch
                wipe_all
            fi
            return 0 ;;
    esac
    case "$pane" in
        %*) ;;
        *)  pane="$(tmux display -p -t "$pane" '#{pane_id}' 2>/dev/null)" || return 0
            [ -n "$pane" ] || return 0 ;;
    esac
    # pane absent from the snapshot = closed since emission — nothing to do
    [ -n "${P_SESS[$pane]:-}" ] || return 0
    kind="${kind:-claude}"
    # A pane is pinned to the session id of the turn it is running: a
    # nested headless instance run by the agent's own tool inherits
    # TMUX_PANE and would otherwise flap the state, so its foreign sid is
    # dropped for the duration.
    # The pin is only ever enforced WHILE a turn is in flight, because that
    # is the only time a nested instance can exist — it runs inside a tool
    # call. Between turns the pane belongs to whoever speaks next, and a
    # session id is not stable across a pane's life: /clear, resume and
    # compaction all mint a new one. Enforcing the pin while idle is how a
    # pane went permanently deaf, its every hook silently dropped.
    if [ -n "$esid" ]; then
        case "$ev" in
            agent.launch|agent.exit) ;;
            *)
                # running only. A nested instance is spawned BY a tool call,
                # so it cannot exist while the pane sits blocked on a
                # permission prompt — no tool is running yet. Enforcing the
                # pin through action made a red pane deaf for as long as it
                # stayed red, which is exactly when it must keep up.
                case "${P_STATE[$pane]:-}" in
                    running)
                        [ -n "${P_SIDS[$pane]:-}" ] \
                            && [ "${P_SIDS[$pane]}" != "$esid" ] && return 0
                        ;;
                esac
                if [ "${P_SIDS[$pane]:-}" != "$esid" ]; then
                    ARGS+=(set -p -t "$pane" @agent_sid "$esid" ";")
                    P_SIDS[$pane]="$esid"
                fi
                ;;
        esac
    fi
    case "$ev" in
        turn.work)
            w4 "$pane" running "$ets" running "$kind"
            clear_msg "$pane"
            ;;
        agent.launch)
            w4 "$pane" idle "$ets" launch "$kind"
            clear_msg "$pane"
            if [ -n "$esid" ]; then
                ARGS+=(set -p -t "$pane" @agent_sid "$esid" ";")
                P_SIDS[$pane]="$esid"
            else
                ARGS+=(set -p -t "$pane" -u @agent_sid ";")
                P_SIDS[$pane]=""
            fi
            ;;
        ask.permission)
            # a Notification trailing a stop by <=2s is hook noise, not a
            # real prompt — hooks fire out of order in practice. Guards
            # compare event ts to event ts: drain delay must not skew them.
            if [ "${P_PREV[$pane]:-}" = stop ]; then
                ts0="${P_TS[$pane]:-}"
                [ -n "$ts0" ] && [ $((ets - ts0)) -le 2 ] && return 0
            fi
            # capture BEFORE w4 overwrites it: a pane already sitting in
            # action is still blocked on the SAME incident, not a fresh
            # one — subagent tool calls and PermissionRequest+Notification
            # both firing for one dialog can retrigger this event many
            # times a second while the pane never actually left red
            was_action="${P_STATE[$pane]:-}"
            w4 "$pane" action "$ets" action "$kind"
            set_msg "$pane" "$emsg"
            # a dialog is now open: the park timeout drops to the probe
            # cadence and each wake screen-checks it (ESC fires no hook).
            # The noise settles one beat before ringing — an auto-approved
            # tool resolves its dialog faster than a banner can render,
            # and those must stay silent. Urgent never waits.
            if [ -n "${P_URGENT[$pane]:-}" ]; then
                ALERTS+=("$pane")
            elif [ "$was_action" != action ] && [ -z "${ALARM_TS[$pane]:-}" ]; then
                # arm once per incident — a burst of repeats while already
                # red must not keep pushing the timer out of reach, or a
                # sustained blocking episode rings never instead of once
                now_ms
                ALARM_TS[$pane]="$NOW_MS"
            fi
            ;;
        ask.input)
            # idle-waiting escalates only a QUIET agent — never overrides
            # running (late notifications flap it), never repaints an
            # unread unseen, never downgrades a stuck pane, never races a
            # turn.end in the same drain.
            case "${P_STATE[$pane]:-}" in running|unseen|action|stuck|ENDING) return 0 ;; esac
            if [ -z "${P_URGENT[$pane]:-}" ]; then
                # SEEN ONCE, SEEN FOREVER: attention is decided when the
                # message appears, not a minute later. A pane whose turn
                # ended under the user's eyes (stop), or that they focused
                # (seen), dismissed, or answered (escheck), is already
                # known to them — a "waiting for input" ping afterwards
                # tells them nothing and must not repaint it yellow.
                case "${P_PREV[$pane]:-}" in stop|seen|dismiss|escheck) return 0 ;; esac
                # and never paint the pane the user is sitting in:
                # "waiting for your reply" is noise while it is being typed
                [ "${P_ATT[$pane]:-0}" = 1 ] && return 0
            fi
            w4 "$pane" action "$ets" waiting "$kind"
            set_msg "$pane" "$emsg"
            [ -n "${P_URGENT[$pane]:-}" ] && ALERTS+=("$pane")
            ;;
        turn.end)
            # a repeated stop keeps the original timestamp
            case "${P_STATE[$pane]:-}" in unseen|ENDING) return 0 ;; esac
            # hook-less kinds can end a turn with a dialog still on
            # screen: red beats unseen when the pattern shows
            # A turn cannot be over while a prompt is on the screen. Every
            # kind gets that one look now: claude normally announces its own
            # prompts, but a session whose hooks have stopped firing would
            # otherwise paint calm yellow over a live "Do you want to
            # proceed?" — seen live, and yellow reads as "read me later"
            # when the agent is in fact blocked.
            case "$kind" in
                agy|codex|claude)
                    if dline="$(screen_dialog_line "$pane" "$kind")"; then
                        w4 "$pane" action "$ets" action "$kind"
                        set_msg "$pane" "$dline"
                        ALERTS+=("$pane")
                        return 0
                    fi
                    # Nothing on screen yet. For the kinds that announce no
                    # dialogs at all a question can still be mid-render, so
                    # they retry briefly; claude gets one look and no ladder,
                    # which keeps this to a single capture per turn end.
                    case "$kind" in
                        agy|codex)
                            RECHECK_TS[$pane]=$(( ets + RECHECK_DELAYS[0] ))
                            RECHECK_N[$pane]=0
                            ;;
                    esac
                    ;;
            esac
            # unseen only if nobody is looking — decided by the server
            # atomically at apply time; no drain-side focus cache is as
            # fresh as asking tmux in the same command sequence
            ARGS+=(set -p -t "$pane" @agent_ts "$ets" ";" \
                   set -p -t "$pane" @agent_prev stop ";" \
                   set -p -t "$pane" @agent_kind "$kind" ";" \
                   if -F -t "$pane" "$ATT_FMT" \
                   "set -p -t $pane @agent_state idle" \
                   "set -p -t $pane @agent_state unseen" ";")
            clear_msg "$pane"
            P_STATE[$pane]=ENDING; P_TS[$pane]="$ets"
            P_PREV[$pane]=stop; P_KIND[$pane]="$kind"
            # urgent agents make noise on turn end too, not just on prompts
            [ -n "${P_URGENT[$pane]:-}" ] && ALERTS+=("$pane")
            ;;
        focus.enter)
            # reading clears the yellow story: unseen, and waiting-class
            # awaits (visiting an open conversation acknowledges it).
            # Dialog-class red stays until actually resolved — visiting a
            # pending permission prompt is not dealing with it. A focus
            # landing in the same drain as the turn.end (ENDING) means
            # the user looked after the turn finished: clear it — the
            # batch applies in event order, so idle wins either way.
            case "${P_STATE[$pane]:-}" in
                unseen|ENDING) ;;
                action) [ "${P_PREV[$pane]:-}" = waiting ] || return 0 ;;
                *) return 0 ;;
            esac
            w2 "$pane" idle seen
            ;;
        user.dismiss)
            # manual override from the agents view — the escape hatch for
            # reds no hook can clear, and for a stale session pin deafening
            # a wrapperless-restarted agent
            w2 "$pane" idle dismiss
            clear_msg "$pane"
            ARGS+=(set -p -t "$pane" -u @agent_sid ";")
            P_SIDS[$pane]=""
            ;;
        user.urgent)
            # modifiers are exclusive: setting one clears the others
            if [ -n "${P_URGENT[$pane]:-}" ]; then
                ARGS+=(set -p -t "$pane" -u @agent_urgent ";")
                P_URGENT[$pane]=""
            else
                ARGS+=(set -p -t "$pane" @agent_urgent 1 ";" \
                       set -p -t "$pane" -u @agent_mute ";" \
                       set -p -t "$pane" -u @agent_disabled ";")
                P_URGENT[$pane]=1; P_MUTE[$pane]=""; P_DIS[$pane]=""
            fi
            ;;
        user.mute)
            # tier-aware: a session-level mute wins the display, so it must
            # win the toggle too — unmute the session first, pane bit on
            # later presses
            agents_setting "${P_SESS[$pane]}" mute
            if [ "$AGENTS_VAL" = on ]; then
                "$DIR/agents-settings.sh" toggle "${P_SESS[$pane]}" mute >/dev/null 2>&1
            elif [ -n "${P_MUTE[$pane]:-}" ]; then
                ARGS+=(set -p -t "$pane" -u @agent_mute ";")
                P_MUTE[$pane]=""
            else
                ARGS+=(set -p -t "$pane" @agent_mute 1 ";" \
                       set -p -t "$pane" -u @agent_urgent ";" \
                       set -p -t "$pane" -u @agent_disabled ";")
                P_MUTE[$pane]=1; P_URGENT[$pane]=""; P_DIS[$pane]=""
            fi
            ;;
        user.disable)
            # visible in the view, invisible everywhere else — no counts,
            # no tab signal, no jump targeting
            if [ -n "${P_DIS[$pane]:-}" ]; then
                ARGS+=(set -p -t "$pane" -u @agent_disabled ";")
                P_DIS[$pane]=""
            else
                ARGS+=(set -p -t "$pane" @agent_disabled 1 ";" \
                       set -p -t "$pane" -u @agent_urgent ";" \
                       set -p -t "$pane" -u @agent_mute ";")
                P_DIS[$pane]=1; P_URGENT[$pane]=""; P_MUTE[$pane]=""
            fi
            ;;
        sense.probe)
            # focus left an awaiting pane: check its screen right now
            probe_pane "$pane"
            ;;
        sense.dialog_gone)
            # sensor says the dialog markers left the screen; re-guard
            # against this drain's own transitions before trusting it
            [ "${P_STATE[$pane]:-}" = action ] && [ "${P_PREV[$pane]:-}" = action ] || return 0
            w2 "$pane" idle escheck
            clear_msg "$pane"
            ;;
        agent.exit)
            # modifiers mark the agent, not the pane: a future agent in
            # this pane must not inherit urgency or mutes
            forget_pane "$pane"
            ;;
    esac
    return 0
}

stall_pass() { # running with no transition for 15+ min becomes stuck
    local p ts tail_txt
    for p in "${!P_STATE[@]}"; do
        [ "${P_STATE[$p]}" = running ] || continue
        ts="${P_TS[$p]:-}"
        [ -n "$ts" ] && [ $((NOW - ts)) -gt "$STALL_SECS" ] || continue
        # a stall with a fatal error on screen is blocked on the user:
        # stuck goes red and rings. Checked once, at stamp time.
        tail_txt="$(tmux capture-pane -p -t "$p" 2>/dev/null)" || tail_txt=""
        [ "${#tail_txt}" -gt 2500 ] && tail_txt="${tail_txt: -2500}"
        if [ -n "$tail_txt" ] && printf '%s' "$tail_txt" | grep -qiE "$FAULT_RE"; then
            w2 "$p" stuck fault
            ALERTS+=("$p")
        else
            ARGS+=(set -p -t "$p" @agent_state stuck ";")
            P_STATE[$p]=stuck
        fi
    done
}

now_ms() { # sets NOW_MS — a global, not a subshell: this runs on the
    # per-wake path and a fork there costs ~0.85ms, which is most of an
    # otherwise near-free empty wake.
    # Digits only: some locales write EPOCHREALTIME with a comma, and
    # stripping one literal dot would leave the fraction glued on. Under
    # --replay the event timeline IS the clock, so the settle beat is as
    # deterministic as every other tested behaviour.
    if [ -n "$REPLAY" ]; then NOW_MS=$(( NOW * 1000 )); return 0; fi
    NOW_MS=$(( ${EPOCHREALTIME//[^0-9]/} / 1000 ))
}

fire_settled_alarms() {
    # a red that resolved before its settle beat stays silent; one that
    # survived it rings
    [ "${#ALARM_TS[@]}" -gt 0 ] || return 0
    local p
    now_ms
    for p in "${!ALARM_TS[@]}"; do
        if [ "${P_STATE[$p]:-}" != action ]; then
            unset "ALARM_TS[$p]"
        elif [ $(( NOW_MS - ALARM_TS[$p] )) -ge 700 ]; then
            ALERTS+=("$p")
            unset "ALARM_TS[$p]"
        fi
    done
}

recheck_pass() {
    # a hook-less turn.end that found no dialog gets a few more quick
    # looks (event-time domain, not wall-clock — deterministic in replay
    # too) before falling silent until the slower hookless_pass cadence
    local p k n line
    for p in "${!RECHECK_TS[@]}"; do
        [ "$NOW" -ge "${RECHECK_TS[$p]}" ] || continue
        k="${P_KIND[$p]:-claude}"
        if line="$(screen_dialog_line "$p" "$k")"; then
            w4 "$p" action "$NOW" action "$k"
            set_msg "$p" "$line"
            ALERTS+=("$p")
            unset "RECHECK_TS[$p]" "RECHECK_N[$p]"
            continue
        fi
        n=$(( ${RECHECK_N[$p]:-0} + 1 ))
        if [ "$n" -ge "${#RECHECK_DELAYS[@]}" ]; then
            unset "RECHECK_TS[$p]" "RECHECK_N[$p]"
        else
            RECHECK_N[$p]="$n"
            RECHECK_TS[$p]=$(( NOW + RECHECK_DELAYS[n] ))
        fi
    done
}

# --- sensors ------------------------------------------------------------------

probe_pane() { # <pane> — dialog-class reds only: ESC on a permission dialog
    # fires NO hook (proven), so the red would lie forever. Waiting-class
    # reds have markerless screens and must stay red. Fails toward keeping
    # red on markers, capture errors, other classes.
    local p="$1" tail_txt re
    [ "${P_STATE[$p]:-}" = action ] && [ "${P_PREV[$p]:-}" = action ] || return 0
    # a kind with no pattern row keeps its red: probing opencode against
    # claude's markers would falsely dismiss a live dialog
    re="${DIALOG_RE[${P_KIND[$p]:-claude}]:-}"
    [ -n "$re" ] || return 0
    tail_txt="$(tmux capture-pane -p -t "$p" 2>/dev/null)" || return 0
    # markers live at the bottom of the visible screen — a fork-free
    # byte-window suffices (an out-of-range negative offset would yield
    # empty — guard it)
    [ "${#tail_txt}" -gt 2500 ] && tail_txt="${tail_txt: -2500}"
    [ -n "$tail_txt" ] || return 0
    printf '%s' "$tail_txt" | grep -qE "$re" && return 0
    w2 "$p" idle escheck
    clear_msg "$p"
}

screen_dialog_line() { # <pane> <kind> — prints the matched dialog line
    local re tail_txt line
    re="${DIALOG_RE[$2]:-}"
    [ -n "$re" ] || return 1
    tail_txt="$(tmux capture-pane -p -t "$1" 2>/dev/null)" || return 1
    [ "${#tail_txt}" -gt 2500 ] && tail_txt="${tail_txt: -2500}"
    line="$(printf '%s' "$tail_txt" | grep -m1 -E "$re")" || return 1
    line="${line#"${line%%[![:space:]]*}"}"
    printf '%s' "${line//[$'\t\r']/ }"
}

hookless_pass() {
    # agy and codex announce no dialogs — but they emit tool events
    # steadily while working, so a running pane gone silent is exactly
    # where a hidden dialog can sit. One capture after 20s of silence,
    # re-checked at most every 30s; a match is a dialog-class red like
    # any other and clears through the same probe.
    local p k line
    for p in "${!P_STATE[@]}"; do
        [ "${P_STATE[$p]}" = running ] || continue
        k="${P_KIND[$p]:-claude}"
        case "$k" in agy|codex) ;; *) continue ;; esac
        [ $(( NOW - ${P_TS[$p]:-$NOW} )) -ge 20 ] || continue
        [ $(( NOW - ${HP_TS[$p]:-0} )) -ge 30 ] || continue
        HP_TS[$p]="$NOW"
        line="$(screen_dialog_line "$p" "$k")" || continue
        w4 "$p" action "$NOW" action "$k"
        set_msg "$p" "$line"
        ALERTS+=("$p")
    done
}

interrupt_pass() {
    # A running pane that has fallen quiet and is wearing the idle mark
    # stopped generating with nothing to announce it: the user pressed
    # ESC. End the turn through the ordinary handler so the attended /
    # unseen rule keeps living in exactly one place.
    # Testing FOR the idle mark rather than for the absence of a spinner
    # is the safe direction: a title we do not recognise changes nothing.
    # The mark is Claude's title convention; every other kind is carried
    # along for free, since a title it never writes can never match.
    local p
    for p in "${!P_STATE[@]}"; do
        [ "${P_STATE[$p]}" = running ] || continue
        [ $(( NOW - ${P_TS[$p]:-$NOW} )) -ge "$IDLE_SILENCE" ] || continue
        # One look per transition. park_timeout arms a single wake for the
        # deadline; this disarms it whether or not the title had moved, so
        # a working agent costs one wake per turn, never a cadence.
        IP_CHECKED[$p]="${P_TS[$p]:-}"
        case "${P_TITLE[$p]:-}" in "$IDLE_MARK"*) ;; *) continue ;; esac
        apply_event "v1${TAB}${NOW}${TAB}turn.end${TAB}${p}${TAB}${P_KIND[$p]:-claude}${TAB}"
    done

    # The same witness, read the other way: a spinning title is an agent
    # generating right now, whatever its hooks did or did not say. Hooks
    # are the fast path, not the only one — a session whose hooks died
    # (settings rewritten under a long-lived process, an agent started
    # outside the wrapper) would otherwise sit calm while visibly working.
    # Calm states only: a dialog-class red is the user's business to
    # answer and must never be overwritten by a repaint underneath it.
    [ -n "$SPIN_OK" ] || return 0
    for p in "${!P_STATE[@]}"; do
        case "${P_STATE[$p]}" in idle|unseen|stuck) ;; *) continue ;; esac
        case "${P_TITLE[$p]:-}" in
            [$'⠀'-$'⣿']*)
                apply_event "v1${TAB}${NOW}${TAB}turn.work${TAB}${p}${TAB}${P_KIND[$p]:-claude}${TAB}"
                ;;
        esac
    done
}

run_passes() {
    # THE ordering of the derived passes, for the daemon and for --replay
    # alike. A pass added here reaches both; a pass that cannot work in a
    # replay says so itself, at its own top, where the reason lives.
    stall_pass
    probe_pass
    hookless_pass
    interrupt_pass
    recheck_pass
}

probe_pass() {
    # attended dialogs only: an unattended dialog cannot be dismissed by
    # anyone — its red resolves through events (answer, turn end, sweep)
    # or the instant focus-out probe when the user leaves right after an
    # ESC. Cost is bounded by attached clients, never by fleet size.
    # A replay has no attached client and no live screen to read, so it
    # declines here rather than by being left out of the pass list.
    [ -n "$REPLAY" ] && return 0
    local p
    for p in "${!P_STATE[@]}"; do
        [ "${P_STATE[$p]}" = action ] && [ "${P_PREV[$p]:-}" = action ] \
            && [ "${P_ATT[$p]:-0}" = 1 ] \
            && probe_pane "$p"
    done
}

sweep_pass() {
    # ONE ps snapshot judges every tracked pane: no process matching
    # @agent_kind alive under the pane's tree means the agent died without
    # a farewell hook. Doubt (pane pid gone from ps, empty snapshot) means
    # alive — state is only ever cleared on definitive evidence.
    local ps_out rows="" p dead
    LAST_SWEEP="$NOW"
    ps_out="$(ps -axo pid=,ppid=,comm= 2>/dev/null)" || return 0
    [ -n "$ps_out" ] || return 0
    for p in "${!P_STATE[@]}"; do
        [ -n "${P_STATE[$p]}" ] || continue
        # a fresh transition is proof of life: launch wrappers emit before
        # the CLI has exec'd, so give every new state a grace window
        case "${P_TS[$p]:-0}" in *[!0-9]*|'') ;; *)
            [ $((NOW - P_TS[$p])) -lt 10 ] && continue ;;
        esac
        rows+="${p}${US}${P_PID[$p]:-}${US}${P_KIND[$p]:-claude}"$'\n'
    done
    [ -n "$rows" ] || return 0
    dead="$(awk -v FS="$US" '
        NR == FNR {
            line = $0; sub(/^[ \t]+/, "", line)
            pid = line; sub(/[ \t].*/, "", pid)
            sub(/^[0-9]+[ \t]+/, "", line)
            pp = line; sub(/[ \t].*/, "", pp)
            sub(/^[0-9]+[ \t]+/, "", line)
            sub(/.*\//, "", line)
            comm[pid] = tolower(line)
            alive[pid] = 1
            kids[pp] = kids[pp] " " pid
            next
        }
        {
            root = $2
            if (!(root in alive)) next     # gone from ps? doubt -> keep
            kind = tolower($3 == "" ? "claude" : $3)
            n = 0; q[n++] = root; found = 0
            for (i = 0; i < n && !found; i++) {
                if (index(comm[q[i]], kind) > 0) { found = 1; break }
                m = split(kids[q[i]], arr, " ")
                for (j = 1; j <= m; j++) if (arr[j] != "") q[n++] = arr[j]
            }
            if (!found) print $1
        }' <(printf '%s\n' "$ps_out") <(printf '%s' "$rows"))"
    for p in $dead; do
        # a reaped corpse takes its modifiers with it — the next agent in
        # this pane starts unmarked
        forget_pane "$p"
    done
}

wipe_all() {
    # the layer was switched off: remove every trace in one batch — pane
    # facts, derived policy, widget globals — and forget what we knew
    local p g
    local -a wargs=()
    for p in "${!P_SESS[@]}"; do
        for g in $AGENT_PANE_OPTS; do
            wargs+=(set -p -t "$p" -u "@agent_$g" ";")
        done
    done
    for g in any n_running n_action n_unseen n_stuck; do
        wargs+=(set -g -u "@agents_$g" ";")
    done
    for g in running action unseen stuck; do
        wargs+=(set -g -u "@agents_n_${g}_cur" ";" set -g -u "@agents_n_${g}_oth" ";")
    done
    while IFS= read -r g; do
        [ -n "$g" ] && wargs+=(set -w -t "$g" -u @agent_win_sig ";")
    done < <(tmux list-windows -a -F '#{window_id}' 2>/dev/null)
    flush_cmds wargs
    tmux refresh-client -S 2>/dev/null
    P_STATE=(); P_TS=(); P_PREV=(); P_KIND=()
    P_URGENT=(); P_MUTE=(); P_DIS=()
    LAST_DERIVED=""
}

flush_cmds() { # <array-name> — apply a ;-separated command batch in
    # chunks split at command boundaries: tmux silently drops a WHOLE
    # batch past ~1000 args, which would lose a big boot replay, a mass
    # reap, or a wipe in one gulp. Individual failures (a pane closing
    # mid-batch) are fine — the rest of the sequence still runs; server
    # death surfaces at the next park.
    local -n _cmds="$1"
    [ "${#_cmds[@]}" -gt 0 ] || return 0
    local -a chunk=()
    local x last
    for x in "${_cmds[@]}"; do
        chunk+=("$x")
        if [ "$x" = ";" ] && [ "${#chunk[@]}" -ge 600 ]; then
            unset "chunk[$(( ${#chunk[@]} - 1 ))]"
            tmux "${chunk[@]}" 2>/dev/null
            chunk=()
        fi
    done
    if [ "${#chunk[@]}" -gt 0 ]; then
        last=$(( ${#chunk[@]} - 1 ))
        [ "${chunk[$last]}" = ";" ] && unset "chunk[$last]"
        [ "${#chunk[@]}" -gt 0 ] && tmux "${chunk[@]}" 2>/dev/null
    fi
    _cmds=()
    return 0
}

apply_batch() {
    flush_cmds ARGS
}

# --- alerts -------------------------------------------------------------------

alert() { # <pane> — bell into the pane tty + optional macOS notification.
    # Urgent agents always alert; otherwise pane/session/global mute applies
    # and nothing rings while the user is already looking at the pane.
    local p="$1" tty
    if [ -z "${P_URGENT[$p]:-}" ]; then
        [ -n "${P_MUTE[$p]:-}" ] && return 0
        agents_setting '*' mute
        [ "$AGENTS_VAL" = on ] && return 0
        agents_setting "${P_SESS[$p]:-}" mute
        [ "$AGENTS_VAL" = on ] && return 0
        [ "${P_ATT[$p]:-0}" = 1 ] && return 0
    fi
    # Every gate above has been passed, so this pane really is ringing. A
    # replay records that fact instead of ringing: it must not touch a real
    # terminal, and an alert nobody can observe is an alert nobody can test.
    if [ -n "$REPLAY" ]; then
        printf '%s\n' "$p" >> "$AGENTS_RUN/alerts.log" 2>/dev/null
        return 0
    fi
    tty="${P_TTY[$p]:-}"
    [ -n "$tty" ] && printf '\a' > "$tty" 2>/dev/null
    # desktop notification, written straight to each attached client's
    # terminal — no passthrough needed, reaches the outer app even when
    # the red pane is not visible. No universal escape exists, and a
    # terminal that speaks several dialects pops one notification PER
    # ESCAPE (Ghostty renders OSC 9 and OSC 777 as two), so each client
    # gets exactly the one dialect its terminal prefers: OSC 777 for
    # ghostty, OSC 9 for everyone else (iTerm2/kitty/WezTerm/foot).
    # Bell-only terminals (Alacritty, Terminal.app) already got the BEL
    # above. alert() itself is the gate: dialog reds and urgent only,
    # muted silent, attended silent.
    local body ctty cterm
    # the agent's own question beats a generic summons — the CURRENT one
    # only; a cleared message must not resurface in a later alert
    if [ -n "${P_MSGO[$p]:-}" ]; then
        body="${P_KIND[$p]:-claude} (${P_SESS[$p]:-}:${P_WIN[$p]:-}): ${P_MSGO[$p]}"
    else
        body="${P_KIND[$p]:-claude} needs you (${P_SESS[$p]:-}:${P_WIN[$p]:-})"
    fi
    body="${body//;/ }"   # OSC args split on semicolons
    while IFS="$US" read -r ctty cterm; do
        [ -n "$ctty" ] || continue
        case "$cterm" in
            *ghostty*) printf '\033]777;notify;%s;%s\a' "tmux agents" "$body" > "$ctty" 2>/dev/null ;;
            *)         printf '\033]9;%s\a' "$body" > "$ctty" 2>/dev/null ;;
        esac
    done < <(tmux list-clients -F "#{client_tty}${US}#{client_termname}" 2>/dev/null)
    agents_setting '*' desktop
    if [ "$AGENTS_VAL" = on ]; then
        # backgrounded: osascript takes 100-200ms and must not stall the drain
        osascript -e "display notification \"$body\" with title \"tmux agents\"" \
            >/dev/null 2>&1 &
    fi
    return 0
}

run_alerts() {
    local p
    for p in "${ALERTS[@]}"; do alert "$p"; done
    ALERTS=()
}

# --- derived facts ------------------------------------------------------------

derive() {
    # THE policy pass, computed once for every renderer. Per pane:
    #   @agent_class  alert/warn/busy/stale/quiet/hidden — the effective
    #                 display class after the modifier law (urgent reddens
    #                 await AND unseen; muted yellows awaits; disabled is
    #                 view-only)
    #   @agent_rank   jump band: 0 urgent-pending, 1 await, 2 unseen incl
    #                 muted awaits, 3 stuck; unset when not a jump target.
    #                 Viewer-independent — closeness and age (@agent_ts)
    #                 are the renderer's business.
    #   @agent_mod    resolved modifier name for the MOD column (session
    #                 mutes count as muted)
    # Then one awk over the classed rows feeds the status-right widget
    # counts (muted awaits tally as unseen) and the per-window tab signal
    # (@agent_win_sig, read by SIGBLOCK: red = any alert, yellow = muted
    # await). Renderers read class/rank/mod and never look at modifiers
    # or settings.
    local current popup smuted rows out wins w sig cursig k v cleared="" newwins=" " sig_now
    local p sess win st ts prev urg mut dis cls rank mod ncls nrank nmod band cst sigc crows=""
    local -a dargs=() pdargs=()
    IFS="$US" read -r current popup < <(tmux display -p \
        "#{client_session}${US}#{@agents_popup}" 2>/dev/null) || true
    current="${current:-}"; popup="${popup:-}"
    smuted=" $(awk -F'\t' '$2 == "mute" && $3 == "on" { printf "%s ", $1 }' \
        "$AGENTS_SETTINGS" 2>/dev/null)"
    rows="$(tmux list-panes -a \
        -F "#{pane_id}${US}#{session_name}${US}#{window_id}${US}#{@agent_state}${US}#{@agent_ts}${US}#{@agent_prev}${US}#{@agent_urgent}${US}#{@agent_mute}${US}#{@agent_disabled}${US}#{@agent_class}${US}#{@agent_rank}${US}#{@agent_mod}" 2>/dev/null)" || return 1
    while IFS="$US" read -r p sess win st ts prev urg mut dis cls rank mod; do
        [ -n "$p" ] || continue
        ncls="" nrank="" nmod="" band=""
        if [ -n "$st" ]; then
            if [ -n "$dis" ]; then nmod=disabled
            elif [ -n "$urg" ]; then nmod=urgent
            elif [ -n "$mut" ]; then nmod=muted
            else case "$smuted" in *" $sess "*) nmod=muted ;; esac
            fi
            if [ -n "$dis" ]; then
                ncls=hidden
            else
                case "$st" in
                    action)
                        # two kinds of await: a dialog blocks the agent
                        # (red), idle-waiting is just an open conversation
                        # (yellow, tallies as unseen — like muted awaits)
                        if [ -n "$urg" ]; then ncls=alert band=0
                        elif [ "$prev" = waiting ]; then ncls=warn band=2
                        elif [ "$nmod" = muted ]; then ncls=warn band=2
                        else ncls=alert band=1; fi ;;
                    unseen)
                        if [ -n "$urg" ]; then ncls=alert band=0
                        else ncls=warn band=2; fi ;;
                    stuck)
                        # a fault-stall is blocked on the user, and urgent
                        # reddens all events — both escalate stuck to red
                        if [ "$prev" = fault ] || [ -n "$urg" ]; then ncls=alert
                        else ncls=stale; fi
                        band=3
                        [ -n "$urg" ] && band=0 ;;
                    running) ncls=busy ;;
                    *) ncls=quiet ;;
                esac
            fi
            nrank="$band"
        fi
        # count bucket and tab signal derive from the class HERE — one
        # policy site: alert-class panes tally as action (the red pill)
        # and paint red; warn-class awaits tally as unseen and paint
        # yellow; calm stuck keeps its own pill
        cst=""; sigc=""
        if [ -n "$st" ] && [ "$ncls" != hidden ]; then
            cst="$st"
            [ "$st" = action ] && [ "$ncls" = warn ] && cst=unseen
            [ "$ncls" = alert ] && cst=action
            [ "$ncls" = alert ] && sigc=red
            # warn covers both muted/waiting awaits AND plain unseen
            # (a finished turn you haven't looked at) — the tab lights
            # yellow for either, not just the await half of the story
            [ "$ncls" = warn ] && sigc=yellow
        fi
        if [ "$ncls" != "$cls" ]; then
            if [ -n "$ncls" ]; then pdargs+=(set -p -t "$p" @agent_class "$ncls" ";")
            else pdargs+=(set -p -t "$p" -u @agent_class ";"); fi
        fi
        if [ "$nrank" != "$rank" ]; then
            if [ -n "$nrank" ]; then pdargs+=(set -p -t "$p" @agent_rank "$nrank" ";")
            else pdargs+=(set -p -t "$p" -u @agent_rank ";"); fi
        fi
        if [ "$nmod" != "$mod" ]; then
            if [ -n "$nmod" ]; then pdargs+=(set -p -t "$p" @agent_mod "$nmod" ";")
            else pdargs+=(set -p -t "$p" -u @agent_mod ";"); fi
        fi
        [ -n "$cst" ] && crows+="${sess}${US}${win}${US}${cst}${US}${sigc}"$'\n'
    done <<< "$rows"
    # pane-level derived facts self-filter on change and repaint nothing:
    # the status line reads only the globals below
    flush_cmds pdargs
    out="$(awk -F "$US" -v cur="$current" '
        NF {
            # pure arithmetic — the policy (bucket, signal color) was
            # decided per pane in the loop above, in one place
            if ($4 == "red") sig[$2] = "red"
            else if ($4 == "yellow" && sig[$2] == "") sig[$2] = "yellow"
            n[$3]++; total++
            if ($1 == cur) c[$3]++
        }
        END {
            # counts always land (0 included) so widget segments hold their
            # positions; only "any" unsets at zero and hides the whole widget
            split("running action unseen stuck", S, " ")
            for (i = 1; i <= 4; i++) {
                s = S[i]; t = n[s] ? n[s] : 0; k = c[s] ? c[s] : 0
                print "n_" s "\t" t
                print "n_" s "_cur\t" k
                print "n_" s "_oth\t" (t - k)
            }
            print "any\t" (total ? total : "")
            for (w in sig) print "winsig\t" w "=" sig[w]
        }' <<< "$crows")"
    while IFS="$TAB" read -r k v; do
        [ -n "$k" ] || continue
        case "$k" in
            winsig)
                w="${v%%=*}"; sig="${v#*=}"
                dargs+=(set -w -t "$w" @agent_win_sig "$sig" ";")
                newwins="${newwins}${w} "
                ;;
            *)
                if [ -n "$v" ]; then dargs+=(set -g "@agents_$k" "$v" ";")
                else dargs+=(set -g -u "@agents_$k" ";"); fi
                ;;
        esac
    done <<< "$out"
    # windows whose signal ended: clear the option so the tab goes quiet
    wins="$(tmux list-windows -a -F "#{window_id}${US}#{@agent_win_sig}" 2>/dev/null)" || return 1
    while IFS="$US" read -r w cursig; do
        [ -n "$cursig" ] || continue
        case "$newwins" in *" $w "*) ;; *)
            dargs+=(set -w -t "$w" -u @agent_win_sig ";")
            cleared="$cleared $w"
            ;;
        esac
    done <<< "$wins"
    # repaint only when derived facts changed — every refresh-client wraps
    # the redraw in cursor hide/show, which reads as prompt flicker in an
    # open popup (the C-s a view). awk map order is unstable: sort first.
    sig_now="$(LC_ALL=C sort <<< "$out")|$cleared"
    if [ -n "$FORCE_DERIVE" ] || [ "$sig_now" != "$LAST_DERIVED" ]; then
        LAST_DERIVED="$sig_now"
        FORCE_DERIVE=""
        flush_cmds dargs
        # a repaint blinks the cursor of an open picker popup — hold it
        # while one is up; the picker's closing resync flushes the bar
        [ -z "$popup" ] && tmux refresh-client -S 2>/dev/null
    fi
    return 0
}

# --- drain --------------------------------------------------------------------

any_dialog_red() {
    local p
    for p in "${!P_STATE[@]}"; do
        [ "${P_STATE[$p]}" = action ] && [ "${P_PREV[$p]:-}" = action ] && return 0
    done
    return 1
}

interrupt_due() {
    # An armed interrupt deadline that has come due. The cheap-wake guard
    # MUST consult this: park_timeout re-arms until the pass disarms, so a
    # wake short-circuited before interrupt_pass would be rescheduled at
    # once, and the daemon would spin instead of sleeping.
    local p
    for p in "${!P_STATE[@]}"; do
        [ "${P_STATE[$p]}" = running ] && [ "${P_ATT[$p]:-0}" = 1 ] || continue
        [ "${IP_CHECKED[$p]:-}" = "${P_TS[$p]:-}" ] && continue
        [ $(( NOW - ${P_TS[$p]:-$NOW} )) -ge "$IDLE_SILENCE" ] && return 0
    done
    return 1
}

process_pass() {
    local e changed="" sweep_ran=""
    NOW="$EPOCHSECONDS"
    # a wake with nothing to act on (stray doorbell byte, ack re-ring) is
    # free: no snapshot, no derive — the heartbeat still bumps in the main
    # loop, which the ack counter depends on
    if [ "${#EVENTS[@]}" -eq 0 ] && [ -z "$FORCE_DERIVE" ] \
        && [ $((NOW - LAST_SWEEP)) -lt 5 ] && [ "${#ALARM_TS[@]}" -eq 0 ] \
        && [ "${#RECHECK_TS[@]}" -eq 0 ] && ! any_dialog_red && ! interrupt_due; then
        return 0
    fi
    snapshot || return 1
    ARGS=(); ALERTS=()
    for e in "${EVENTS[@]}"; do apply_event "$e"; done
    run_passes
    if [ $((NOW - LAST_SWEEP)) -ge 5 ]; then
        sweep_pass
        sweep_ran=1
    fi
    fire_settled_alarms
    [ "${#ARGS[@]}" -gt 0 ] && changed=1
    apply_batch
    run_alerts
    # derive notices two kinds of change: our own writes, and panes that
    # vanished without an event — the sweep-cadence pass covers the latter,
    # so probe wakes that cleared nothing skip the whole readback
    if [ -n "$changed" ] || [ -n "$FORCE_DERIVE" ] || [ -n "$sweep_ran" ]; then
        derive || return 1
    fi
    return 0
}

drain_dry() {
    # level-triggered: keep draining until a read finds nothing new, so a
    # doorbell edge lost to wait-for's toggle can cost latency, never events
    local passes=0
    while :; do
        collect_events
        [ "${#EVENTS[@]}" -eq 0 ] && [ "$passes" -gt 0 ] && return 0
        process_pass || return 1
        passes=$((passes + 1))
    done
}

# --- replay -------------------------------------------------------------------

if [ -n "$REPLAY" ]; then
    snapshot || exit 0
    while IFS= read -r line; do EVENTS+=("$line"); done
    ARGS=(); ALERTS=()
    for e in "${EVENTS[@]}"; do apply_event "$e"; done
    run_passes
    # the reaper judges pane options against live processes, both of which a
    # replay has: it is the one pass that decides an agent is gone, so it is
    # exercised here rather than only in production
    sweep_pass
    # the settle beat is deterministic under replay (now_ms follows the
    # event timeline), so the debounce is exercised like anything else
    fire_settled_alarms
    apply_batch
    run_alerts
    derive
    exit 0
fi

# --- daemon -------------------------------------------------------------------

acquire_lock() {
    if command -v shlock >/dev/null 2>&1; then
        shlock -f "$AGENTS_PID" -p $$
        return
    fi
    # no shlock: noclobber create is atomic; steal a stale lock by rename
    # so only one of two racing starters wins the takeover
    local pid
    pid="$(cat "$AGENTS_PID" 2>/dev/null)"
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then return 1; fi
    if [ -f "$AGENTS_PID" ]; then
        mv "$AGENTS_PID" "$AGENTS_PID.stale.$$" 2>/dev/null || return 1
        rm -f "$AGENTS_PID.stale.$$"
    fi
    ( set -C; echo $$ > "$AGENTS_PID" ) 2>/dev/null
}

open_doorbell() {
    # daemon-private FIFO opened read-write so nothing ever blocks on it;
    # hooks stay on the spool + wait-for side and never touch this file
    if ! [ -p "$DOORBELL" ]; then
        rm -f "$DOORBELL"
        mkfifo "$DOORBELL" 2>/dev/null || return 1
    fi
    exec {DB_FD}<>"$DOORBELL"
}

start_bridge() {
    # converts wait-for signals into FIFO bytes the daemon can block on
    # with a timeout. Poison byte X reports server death from inside the
    # blocking wait — the daemon then verifies and exits instead of
    # sleeping through a full timeout as an orphan.
    (
        while kill -0 "$$" 2>/dev/null; do
            if ! tmux wait-for agents 2>/dev/null; then
                printf X >&"$DB_FD" 2>/dev/null
                exit 0
            fi
            printf . >&"$DB_FD" 2>/dev/null || exit 0
        done
    ) &
    BRIDGE_PID=$!
}

park_timeout() { # sets PARK_T — no subshell on the per-park path
    # probe cadence while any dialog-class red needs screen checks; time
    # to the next liveness sweep while anything is tracked; near-forever
    # when idle — zero wakeups when no agent exists
    local p left
    PARK_T=3600
    if [ "${#ALARM_TS[@]}" -gt 0 ]; then
        PARK_T="$PROBE_SECS"
        return
    fi
    if [ "${#RECHECK_TS[@]}" -gt 0 ]; then
        left=3600
        for p in "${!RECHECK_TS[@]}"; do
            (( RECHECK_TS[p] - NOW < left )) && left=$(( RECHECK_TS[p] - NOW ))
        done
        [ "$left" -lt 1 ] && left=1
        PARK_T="$left"
        return
    fi
    for p in "${!P_STATE[@]}"; do
        if [ "${P_STATE[$p]}" = action ] && [ "${P_PREV[$p]:-}" = action ] \
            && [ "${P_ATT[$p]:-0}" = 1 ]; then
            PARK_T="$PROBE_SECS"
            return
        fi
    done
    # A running pane under the user's eyes is the one that can be ESC'd,
    # and nothing announces that: tmux has no title-change hook, and its
    # silence alerts skip the current window — the very pane in question.
    # So one wake is scheduled for the deadline of each transition and
    # disarmed once taken. Edge-triggered, not a cadence: an agent working
    # through ten tools costs ten wakes, and one sitting still costs none.
    # An unattended pane keeps the long park — nobody is watching it.
    for p in "${!P_STATE[@]}"; do
        if [ "${P_STATE[$p]}" = running ] && [ "${P_ATT[$p]:-0}" = 1 ] \
            && [ "${IP_CHECKED[$p]:-}" != "${P_TS[$p]:-}" ]; then
            left=$(( ${P_TS[$p]:-$NOW} + IDLE_SILENCE - NOW ))
            [ "$left" -lt 1 ] && left=1
            PARK_T="$left"
            return
        fi
    done
    for p in "${!P_STATE[@]}"; do
        if [ -n "${P_STATE[$p]}" ]; then
            left=$(( LAST_SWEEP + 60 - NOW ))
            [ "$left" -lt 5 ] && left=5
            [ "$left" -gt 60 ] && left=60
            PARK_T="$left"
            return
        fi
    done
}

park() {
    local ch="" rest="" poison=""
    kill -0 "$BRIDGE_PID" 2>/dev/null || start_bridge
    park_timeout
    IFS= read -r -N 1 -t "$PARK_T" -u "$DB_FD" ch 2>/dev/null
    [ "$ch" = X ] && poison=1
    # absorb queued bytes so a burst costs one drain, not one per doorbell
    while IFS= read -r -t 0 -u "$DB_FD" 2>/dev/null; do
        IFS= read -r -N 1 -t 1 -u "$DB_FD" rest 2>/dev/null || break
        [ "$rest" = X ] && poison=1
    done
    if [ -n "$poison" ]; then
        tmux display -p '' >/dev/null 2>&1 || return 1
    fi
    return 0
}

acquire_lock || exit 0
cleanup() {
    [ -n "$BRIDGE_PID" ] && kill "$BRIDGE_PID" 2>/dev/null
    # only ever remove our own lock — a watchdog may already have replaced it
    [ "$(cat "$AGENTS_PID" 2>/dev/null)" = "$$" ] && rm -f "$AGENTS_PID"
}
trap cleanup EXIT
trap 'exit 0' TERM INT

exec 2>>"$AGENTS_RUN/log"
[ "$(( $(wc -c < "$AGENTS_RUN/log" 2>/dev/null || echo 0) ))" -gt 102400 ] && : > "$AGENTS_RUN/log"
# heartbeat carries a drain counter: the watchdog reads its mtime, acks
# read the number — a waiter that saw N can trust N+2 came after its emit
DRAINS=0
printf '%s\n' "$DRAINS" > "$AGENTS_HEARTBEAT"
open_doorbell || exit 0
boot_spool

while :; do
    drain_dry || break
    rotate_if_big
    DRAINS=$((DRAINS + 1))
    printf '%s\n' "$DRAINS" > "$AGENTS_HEARTBEAT"
    park || break
done
exit 0
