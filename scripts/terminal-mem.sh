#!/usr/bin/env zsh
# Total memory + CPU usage grouped by tool, across the whole CLI setup:
# editor, multiplexer, the tmux-agents layer itself, every AI coding
# agent, LSP/linter/formatter servers, and MCP servers (child processes
# of whichever agent spawned them — grouped as one bucket since names
# vary per server). %CPU is macOS's decaying-average estimate (ps pcpu),
# not an instant sample — fine for "is something actually busy" at a
# glance, not for profiling a single moment.
# Usage: ./terminal-mem.sh

typeset -A tool_rss tool_cpu tool_count

tools=(nvim lazygit zsh tmux fzf node ruff gopls terraform-ls lua-language-server pyright bash-language-server stylua claude codex opencode agy gemini aider)

add_pid() { # <bucket> <pid>
	local rss cpu
	read -r rss cpu < <(ps -o rss=,pcpu= -p "$2" 2>/dev/null)
	[ -z "$rss" ] && return
	tool_rss[$1]=$(( ${tool_rss[$1]:-0} + rss ))
	tool_cpu[$1]=$(echo "${tool_cpu[$1]:-0} + $cpu" | bc)
	tool_count[$1]=$(( ${tool_count[$1]:-0} + 1 ))
}

for tool in $tools; do
	# Exact-name match only. -f (full command line) is reserved for
	# "node" below — it substring-matches ANYTHING in argv, and on this
	# machine that includes launch-env tokens some npm/npx wrappers pass
	# through (verified: an unrelated MCP server's PATH contains the
	# literal string "codex.system", which falsely matched a bare "codex"
	# -f search even though codex was not installed).
	pids=$(pgrep -x "$tool" 2>/dev/null)
	if [ -z "$pids" ] && [ "$tool" = "node" ]; then
		pids=$(pgrep -f "node" 2>/dev/null)
	fi
	for pid in ${=pids}; do
		add_pid "$tool" "$pid"
	done
done

# tmux-agents daemon: process name is bare "bash" running agentsd.sh, plus
# its doorbell bridge child and parked wait-for client — pgrep -f catches
# all three per running daemon (one per tmux server)
for pid in $(pgrep -f 'agentsd\.sh|wait-for agents' 2>/dev/null); do
	add_pid tmux-agentsd "$pid"
done

# MCP servers: spawned per-agent-session, name varies by server (mcp-server-*,
# or an npm-exec wrapper around one) — grouped as one bucket
for pid in $(pgrep -f 'mcp-server|npm exec .*mcp|npx .*mcp' 2>/dev/null); do
	add_pid mcp-servers "$pid"
done

printf "%-25s %8s %10s %7s %7s\n" "TOOL" "COUNT" "TOTAL(MB)" "AVG(MB)" "CPU%"
printf "%-25s %8s %10s %7s %7s\n" "-------------------------" "--------" "----------" "-------" "-------"
grand_total=0
grand_cpu=0
# Sort by total RSS descending
for tool in $(for k in ${(k)tool_rss}; do echo "${tool_rss[$k]} $k"; done | sort -rn | awk '{print $2}'); do
	rss=${tool_rss[$tool]}
	cnt=${tool_count[$tool]}
	cpu=${tool_cpu[$tool]}
	mb=$(echo "scale=1; $rss / 1024" | bc)
	avg=$(echo "scale=1; $rss / $cnt / 1024" | bc)
	grand_total=$((grand_total + rss))
	grand_cpu=$(echo "$grand_cpu + $cpu" | bc)
	printf "%-25s %8s %10s %7s %6s%%\n" "$tool" "$cnt" "${mb}M" "${avg}M" "$cpu"
done

grand_mb=$(echo "scale=1; $grand_total / 1024" | bc)
printf "%-25s %8s %10s %7s %7s\n" "-------------------------" "--------" "----------" "-------" "-------"
printf "%-25s %8s %10s %7s %6s%%\n" "TOTAL" "" "${grand_mb}M" "" "$grand_cpu"
