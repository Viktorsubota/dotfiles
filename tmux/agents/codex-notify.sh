#!/usr/bin/env bash
# tmux agent-state adapter for Codex CLI. Codex passes one JSON argv arg;
# only agent-turn-complete exists as of Aug 2026 (approvals surface via
# tui.notifications only — enable those too for bell-level fidelity):
#   ~/.codex/config.toml:
#     notify = ["/bin/bash", "<this file>"]
#     [tui]
#     notifications = ["agent-turn-complete", "approval-requested"]
#     notification_method = "bel"
set -u
S="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/agent-state.sh"
case "${1:-}" in
    *agent-turn-complete*) [ -x "$S" ] && "$S" stop codex </dev/null ;;
esac
exit 0
