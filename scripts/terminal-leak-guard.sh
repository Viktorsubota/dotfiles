#!/bin/bash
# Catches the silent leaks in this terminal setup — the ones that stay
# invisible until swap fills and the machine crawls.
#
# Measures FOOTPRINT, not RSS. This matters: an idle orphan gets fully
# compressed, so RSS reads near zero while the process still holds all its
# pages. top's MEM column counts compressed pages, so it reports the truth.
#
# What it looks for:
#   1. Orphaned nvim servers. Modern nvim splits into a TUI client plus a
#      `nvim --embed` server child that lives in its own process group with no
#      controlling terminal. Normally the server exits when the TUI's pipes
#      close; when it does not, it survives with no UI that can ever reattach
#      and grows unbounded. ppid=1 plus no tty means dead beyond doubt.
#   2. Live embed servers past a size threshold — the same growth, caught early.
#   3. Orphaned zsh / gitstatusd trees, one per shell whose terminal is gone.
#   4. Stray tmux servers. Beyond their own debris, a second server makes
#      tmux-continuum skip installing its autosave trigger, so session saves
#      stop silently.
#   5. Whether continuum's autosave trigger is actually in status-right, and
#      how stale the newest save is.
#
# Usage: ./terminal-leak-guard.sh              report only
#        ./terminal-leak-guard.sh --reap       also SIGKILL the dead processes
#        ./terminal-leak-guard.sh --bloat 2048 raise the live-server threshold
#
# SIGKILL is deliberate: SIGTERM makes nvim run its exit handler, which pages
# every compressed byte back in to write swapfiles — the opposite of the goal.
# Exits 1 when anything is found, so it can gate a cron or LaunchAgent.

REAP=0
BLOAT_MB=1024
while [ $# -gt 0 ]; do
	case "$1" in
		--reap) REAP=1 ;;
		--bloat) BLOAT_MB="$2"; shift ;;
		-h|--help) sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
		*) echo "unknown option: $1" >&2; exit 2 ;;
	esac
	shift
done

TMPD=$(mktemp -d) || exit 2
trap 'rm -rf "$TMPD"' EXIT
findings=0

# One top pass for real memory, one ps pass for lineage — joined by pid rather
# than shelling out per process, which would fork hundreds of times on a busy box.
top -l 1 -stats pid,mem > "$TMPD/top" 2>/dev/null
ps -Ao pid,ppid,tty,etime,args > "$TMPD/ps" 2>/dev/null

# pid -> footprint in MB
awk '
	$1 ~ /^[0-9]+$/ && $2 ~ /^[0-9.]+[BKMG]?$/ {
		v = $2; u = substr(v, length(v), 1)
		gsub(/[BKMG]$/, "", v)
		if (u == "G") v = v * 1024
		else if (u == "K") v = v / 1024
		else if (u == "B") v = v / 1048576
		printf "%s %.1f\n", $1, v
	}
' "$TMPD/top" > "$TMPD/mem"

section() { printf "\n\033[1m%s\033[0m\n" "$1"; }

# ---- 1. orphaned nvim embed servers -----------------------------------------
awk 'NR==FNR { mb[$1] = $2; next }
	$2 == 1 && $3 == "??" && /nvim --embed/ { printf "%s\t%s\t%s\n", $1, (mb[$1] ? mb[$1] : 0), $4 }
' "$TMPD/mem" "$TMPD/ps" > "$TMPD/orphan_nvim"

if [ -s "$TMPD/orphan_nvim" ]; then
	section "ORPHANED nvim SERVERS — no terminal, no UI can reattach"
	printf "%-8s %12s %14s  %s\n" "PID" "FOOTPRINT" "AGE" "CWD"
	total=0
	while IFS=$'\t' read -r pid mb age; do
		# cwd only for the few that matched — lsof is far too slow to run broadly
		cwd=$(lsof -a -p "$pid" -d cwd -Fn 2>/dev/null | grep '^n' | head -1 | cut -c2-)
		printf "%-8s %9s MB %14s  %s\n" "$pid" "$mb" "$age" "${cwd:-?}"
		total=$(echo "$total + $mb" | bc)
	done < "$TMPD/orphan_nvim"
	n=$(wc -l < "$TMPD/orphan_nvim" | tr -d ' ')
	printf "  => %s dead server(s), %s MB reclaimable\n" "$n" "$total"
	findings=1
	if [ "$REAP" -eq 1 ]; then
		cut -f1 "$TMPD/orphan_nvim" | xargs kill -9 2>/dev/null
		printf "  reaped.\n"
	fi
fi

# ---- 2. live embed servers past the threshold --------------------------------
awk -v lim="$BLOAT_MB" 'NR==FNR { mb[$1] = $2; next }
	$2 != 1 && /nvim --embed/ && mb[$1] + 0 > lim { printf "%-8s %9s MB %14s\n", $1, mb[$1], $4 }
' "$TMPD/mem" "$TMPD/ps" > "$TMPD/bloat"

if [ -s "$TMPD/bloat" ]; then
	section "LIVE nvim SERVERS OVER ${BLOAT_MB}MB — still attached, growing"
	printf "%-8s %12s %14s\n" "PID" "FOOTPRINT" "AGE"
	cat "$TMPD/bloat"
	printf "  => reopen these editors; they are not reapable while attached\n"
	findings=1
fi

# ---- 3. orphaned shells ------------------------------------------------------
orphan_sh=$(awk '$2 == 1 && ($5 ~ /zsh$/ || $5 ~ /gitstatusd/)' "$TMPD/ps" | wc -l | tr -d ' ')
if [ "$orphan_sh" -gt 0 ]; then
	section "ORPHANED SHELLS"
	printf "  %s zsh/gitstatusd process(es) whose terminal is gone\n" "$orphan_sh"
	findings=1
	if [ "$REAP" -eq 1 ]; then
		# ppid=1 is the whole safety argument: every shell owned by a live tmux
		# pane or a login session has a real parent and is never matched here.
		awk '$2 == 1 && ($5 ~ /zsh$/ || $5 ~ /gitstatusd/) {print $1}' "$TMPD/ps" | xargs kill -9 2>/dev/null
		printf "  reaped.\n"
	fi
fi

# ---- 4. stray tmux servers ---------------------------------------------------
sockdir="${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)"
stray=""
for sock in "$sockdir"/*; do
	[ -S "$sock" ] || continue
	name=$(basename "$sock")
	tmux -S "$sock" list-sessions >/dev/null 2>&1 || continue
	[ "$name" = "default" ] && continue
	stray="$stray $name"
done
if [ -n "$stray" ]; then
	section "STRAY tmux SERVERS"
	for name in $stray; do
		printf "  %-16s %s\n" "$name" "$(tmux -S "$sockdir/$name" list-sessions 2>/dev/null | tr '\n' ' ')"
	done
	printf "  => these suppress tmux-continuum autosave: kill with\n"
	printf "     tmux -L <name> kill-server\n"
	findings=1
fi

# ---- 5. continuum autosave health -------------------------------------------
hook=$(tmux show -g status-right 2>/dev/null | grep -c continuum_save)
if [ "$hook" -ne 1 ]; then
	section "CONTINUUM AUTOSAVE"
	if [ "$hook" -eq 0 ]; then
		printf "  trigger MISSING from status-right — sessions are not being saved\n"
	else
		printf "  trigger present %s times — duplicate save passes\n" "$hook"
	fi
	findings=1
fi

last=$(tmux show -gv @continuum-save-last-timestamp 2>/dev/null)
if [ -n "$last" ]; then
	age_min=$(( ($(date +%s) - last) / 60 ))
	interval=$(tmux show -gv @continuum-save-interval 2>/dev/null); interval=${interval:-15}
	if [ "$age_min" -gt $(( interval * 3 )) ]; then
		section "CONTINUUM AUTOSAVE"
		printf "  newest save is %s min old (interval %s min) — autosave has stalled\n" "$age_min" "$interval"
		findings=1
	fi
fi

if [ "$findings" -eq 0 ]; then
	printf "clean — no orphans, no stray servers, autosave healthy\n"
fi
exit "$findings"
