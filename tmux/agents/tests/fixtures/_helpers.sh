# Shared fixture-setup helpers. Sourced, never executed.
#
# Putting text on a scratch pane's screen is racy twice over: the login
# shell may not accept input yet (keystrokes are swallowed silently), and
# the prompt renders asynchronously (p10k draws an instant prompt, then
# redraws). Both show up only under full-suite load, as intermittent
# fixture failures.

# Scratch panes are short (an 80x24 window split in two ~= 11 rows), and
# capture-pane only sees the VISIBLE screen — staged text long enough to
# scroll past the top makes a different line match the probe pattern, so
# the captured message flips run to run. Every staging clears first and
# keeps its content a few lines, so nothing scrolls out of view.
stage_screen() { # <pane> <command> <grep-pattern>  — run until output shows
    local p="$1" cmd="$2" pat="$3" attempt tick
    for attempt in 1 2 3; do
        tmux send-keys -t "$p" "clear; $cmd" Enter 2>/dev/null
        for tick in $(seq 1 30); do
            tmux capture-pane -p -t "$p" 2>/dev/null | grep -q "$pat" && return 0
            sleep 0.1
        done
    done
    return 1
}

stage_file() { # <path> — mkdir -p the parent, then read content from stdin
    mkdir -p "${1%/*}"
    cat > "$1"
}
