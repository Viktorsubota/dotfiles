#!/usr/bin/env bash
# Replay test rig: fixture event streams -> agentsd --replay on a scratch
# tmux server -> normalized option dump diffed against goldens.
#
# Fixture format (tab-separated, # comments and blank lines skipped):
#   v1 <TAB> <ts-offset> <TAB> event <TAB> pane <TAB> kind <TAB> extra
# ts-offset is relative to run time (-300 = five minutes ago), so goldens
# stay stable. Pane ids are literal %0/%1/%2 — the scratch server is
# rebuilt per fixture with a fixed layout, so ids are deterministic:
#   session t1: window 0 (panes %0 %1), window 1 (pane %2)
# An optional fixtures/<name>.setup script runs before the replay (with
# $TMUX pointing at the scratch server) for direct option seeding.
#
# Usage: run.sh [fixture-name ...]     (default: all)
#        UPDATE_GOLDEN=1 run.sh ...    (rewrite goldens from current output)
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENTS="$(dirname "$HERE")"
SOCK=agents-test
NOW="$(date +%s)"
# fixtures declare kind=zsh and the sweep judges kind against live
# processes, so the rig cannot run without it
ZSH_BIN="$(command -v zsh 2>/dev/null)"
[ -n "$ZSH_BIN" ] || { echo "rig needs zsh: fixtures declare kind=zsh" >&2; exit 1; }

WORK="$(mktemp -d)"
cleanup() {
    tmux -L "$SOCK" kill-server 2>/dev/null
    rm -rf "$WORK"
}
trap cleanup EXIT

pane_kind() { # <events-file> <pane> — the kind that fixture declares, else zsh
    local k
    k="$(awk -F'\t' -v p="$2" '/^v1/ && $4 == p { print $5 }' "$1" | tail -1)"
    printf '%s' "${k:-zsh}"
}

kind_bin() { # <kind> — an interactive shell whose process name IS the kind
    if [ "$1" = zsh ] || [ "$1" = ghost ]; then printf '%s' "$ZSH_BIN"; return; fi
    # a copy, not a symlink: the process name comes from the file's own name.
    # Copies of SYSTEM binaries are killed on sight for a broken signature,
    # which is why zsh — already on this machine's terms — is the stock.
    [ -x "$WORK/bin/$1" ] || { mkdir -p "$WORK/bin"; cp "$ZSH_BIN" "$WORK/bin/$1"; }
    printf '%s' "$WORK/bin/$1"
}

fresh_server() { # <kind-%0> <kind-%1> <kind-%2>
    tmux -L "$SOCK" kill-server 2>/dev/null
    # Panes are created in this order, which is what fixes the ids: the
    # session's pane is %0, the split %1, the second window's pane %2.
    tmux -L "$SOCK" -f /dev/null new-session -d -s t1 -x 80 -y 24 "$(kind_bin "$1")" -i || return 1
    tmux -L "$SOCK" split-window -d -t t1:0 "$(kind_bin "$2")" -i || return 1
    tmux -L "$SOCK" new-window -d -t t1: "$(kind_bin "$3")" -i || return 1
    TEST_TMUX="$(tmux -L "$SOCK" display -p '#{socket_path}'),0,0"
    # prove the premise rather than assume it: a pane not running what the
    # fixture declared would make the sweep's verdict meaningless
    # a shell still in its own startup reports whatever it is running just
    # then (stty, and so on), so wait for the name to settle
    local want got i=0 tick
    for want in "$1" "$2" "$3"; do
        [ "$want" = ghost ] && want=zsh
        for tick in $(seq 1 40); do
            got="$(tmux -L "$SOCK" display -p -t "%$i" '#{pane_current_command}' 2>/dev/null)"
            [ "$got" = "$want" ] && break
            sleep 0.1
        done
        [ "$got" = "$want" ] || {
            echo "rig: %$i runs '$got', fixture declares '$want'" >&2; return 1; }
        i=$((i + 1))
    done
}

run_fixture() { # <name> -> 0 pass, 1 fail
    local name="$1" fx="$HERE/fixtures/$1.events" golden="$HERE/golden/$1.txt"
    local got rc=0
    [ -f "$fx" ] || { echo "MISS $name (no fixture)"; return 1; }
    # The liveness sweep asks whether a process matching the pane's kind is
    # alive, so a fixture claiming kind=claude must HAVE a claude running:
    # each pane is started as an interactive copy of zsh named after the
    # kind that fixture declares for it. That makes the sweep answer the
    # fixture's own question instead of the shell's name, and the reaper is
    # exercised by every fixture rather than by none.
    # 'ghost' is reserved: a declared kind that is deliberately never
    # started, so a fixture can watch a dead agent be reaped.
    local k0 k1 k2
    k0="$(pane_kind "$fx" '%0')"; k1="$(pane_kind "$fx" '%1')"; k2="$(pane_kind "$fx" '%2')"
    fresh_server "$k0" "$k1" "$k2" || { echo "FAIL $name (server)"; return 1; }
    if [ -f "$HERE/fixtures/$name.setup" ]; then
        env TMUX="$TEST_TMUX" XDG_STATE_HOME="$WORK/state.$name" \
            bash "$HERE/fixtures/$name.setup" || { echo "FAIL $name (setup)"; return 1; }
    fi
    awk -F'\t' -v now="$NOW" 'BEGIN { OFS = "\t" }
        /^#/ || NF == 0 { next }
        { $2 = now + $2; print }' "$fx" \
    | env TMUX="$TEST_TMUX" XDG_STATE_HOME="$WORK/state.$name" AGENTS_AUTOSTART=0 \
        "$AGENTS/agentsd.sh" --replay
    got="$(env TMUX="$TEST_TMUX" XDG_STATE_HOME="$WORK/state.$name" TEST_NOW="$NOW" \
        bash "$HERE/dump-state.sh")"
    if [ -f "$HERE/fixtures/$name.check" ]; then
        # extra assertions beyond the option dump (e.g. jump --dry output)
        got="$got
$(env TMUX="$TEST_TMUX" XDG_STATE_HOME="$WORK/state.$name" AGENTS_AUTOSTART=0 \
    bash "$HERE/fixtures/$name.check")"
    fi
    if [ "${UPDATE_GOLDEN:-}" = 1 ]; then
        mkdir -p "$HERE/golden"
        printf '%s\n' "$got" > "$golden"
        echo "GOLD $name (written)"
        return 0
    fi
    [ -f "$golden" ] || { echo "MISS $name (no golden — UPDATE_GOLDEN=1 to create)"; return 1; }
    if diff -u "$golden" - <<< "$got" > "$WORK/diff.$name" 2>&1; then
        echo "PASS $name"
    else
        echo "FAIL $name"
        cat "$WORK/diff.$name"
        rc=1
    fi
    return "$rc"
}

names=("$@")
if [ "${#names[@]}" -eq 0 ]; then
    for f in "$HERE"/fixtures/*.events; do
        names+=("$(basename "$f" .events)")
    done
fi

pass=0 fail=0
for n in "${names[@]}"; do
    if run_fixture "$n"; then pass=$((pass + 1)); else fail=$((fail + 1)); fi
done
echo "----"
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
