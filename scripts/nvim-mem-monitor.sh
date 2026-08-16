#!/bin/bash
# nvim-detailed memory + CPU: every nvim instance plus its LSP/linter/
# formatter children (nvim-cmp itself is a Lua plugin — it runs inside
# nvim's own RSS, there is no separate completion process to track).
# Orphaned instances (ppid=1: their terminal is gone, nvim never exited)
# are flagged since they are pure dead weight.
# %CPU is macOS's decaying-average estimate (ps pcpu), not an instant
# sample — fine for "is something actually busy right now" at a glance.
# Usage: ./nvim-mem-monitor.sh            one-shot snapshot to stdout
#        ./nvim-mem-monitor.sh 60 480     log every 60s for 480min, TSV
#        ./nvim-mem-monitor.sh 60 480 > ~/nvim-mem.log

INTERVAL=${1:-0}
DURATION_MIN=${2:-480}
TOTAL_SECS=$((DURATION_MIN * 60))
ELAPSED=0

snapshot() {
	local now total_rss=0 n=0 orphan_rss=0 orphan_n=0
	now=$(date '+%Y-%m-%d %H:%M:%S')
	if [ "$INTERVAL" -gt 0 ]; then
		echo -e "timestamp\ttype\tpid\tppid\torphan\trss_kb\tcpu_pct\tuptime\tcommand"
	else
		printf "%-8s %-8s %7s %6s %6s %10s  %s\n" "PID" "PARENT" "RSS(MB)" "CPU%" "ORPHAN" "UPTIME" "COMMAND"
	fi

	pgrep -x nvim | while read -r NPID; do
		# one ps call per pid instead of three — same info, fewer forks
		read -r PARENT RSS PCPU ETIME < <(ps -o ppid=,rss=,pcpu=,etime= -p "$NPID" 2>/dev/null)
		[ -z "$RSS" ] && continue
		# some launch chains re-exec nvim under nvim (a wrapper spawning
		# the real instance) — skip listing it again at top level, it is
		# already nested as a child under its true parent below
		PARENT_COMM=$(ps -o comm= -p "$PARENT" 2>/dev/null | xargs basename 2>/dev/null)
		[ "$PARENT_COMM" = "nvim" ] && continue
		ORPHAN=""
		[ "$PARENT" = "1" ] && ORPHAN="yes"
		if [ "$INTERVAL" -gt 0 ]; then
			echo -e "${now}\tnvim\t${NPID}\t${PARENT}\t${ORPHAN}\t${RSS}\t${PCPU}\t${ETIME}\tnvim"
		else
			printf "%-8s %-8s %7.1f %5s%% %6s %10s  %s\n" "$NPID" "$PARENT" "$(echo "scale=1; $RSS/1024" | bc)" "$PCPU" "${ORPHAN:--}" "$ETIME" "nvim"
		fi

		# direct children only (LSP servers, formatters, linters) — one
		# level deep, matching what nvim itself spawns
		pgrep -P "$NPID" | while read -r CPID; do
			read -r CRSS CPCPU CETIME CCMD < <(ps -o rss=,pcpu=,etime=,comm= -p "$CPID" 2>/dev/null)
			[ -z "$CRSS" ] && continue
			CCMD=$(basename "$CCMD" 2>/dev/null)
			if [ "$INTERVAL" -gt 0 ]; then
				echo -e "${now}\tchild\t${CPID}\t${NPID}\t\t${CRSS}\t${CPCPU}\t${CETIME}\t${CCMD}"
			else
				printf "  %-6s %-8s %7.1f %5s%% %6s %10s  %s\n" "$CPID" "$NPID" "$(echo "scale=1; $CRSS/1024" | bc)" "$CPCPU" "-" "$CETIME" "$CCMD"
			fi
		done
	done

	if [ "$INTERVAL" -eq 0 ]; then
		total_rss=$(pgrep -x nvim | xargs -I{} ps -o rss= -p {} 2>/dev/null | awk '{s+=$1} END{print s+0}')
		total_cpu=$(pgrep -x nvim | xargs -I{} ps -o pcpu= -p {} 2>/dev/null | awk '{s+=$1} END{printf "%.1f", s+0}')
		n=$(pgrep -x nvim | wc -l | tr -d ' ')
		orphan_n=$(ps -axo ppid=,pid=,comm= | awk '$1==1 && $3=="nvim"' | wc -l | tr -d ' ')
		orphan_rss=$(ps -axo ppid=,rss=,comm= | awk '$1==1 && $3=="nvim" {s+=$2} END{print s+0}')
		printf "\n%d nvim instances, %.1fMB total, %s%% CPU" "$n" "$(echo "scale=1; $total_rss/1024" | bc)" "$total_cpu"
		[ "$orphan_n" -gt 0 ] && printf "  (%d ORPHANED — no terminal, %.1fMB dead weight)" "$orphan_n" "$(echo "scale=1; $orphan_rss/1024" | bc)"
		echo
	fi
}

if [ "$INTERVAL" -eq 0 ]; then
	snapshot
	exit 0
fi

echo -e "timestamp\ttype\tpid\tppid\torphan\trss_kb\tcpu_pct\tuptime\tcommand"
while [ $ELAPSED -lt $TOTAL_SECS ]; do
	snapshot
	sleep "$INTERVAL"
	ELAPSED=$((ELAPSED + INTERVAL))
done
