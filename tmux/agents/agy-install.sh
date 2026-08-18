#!/usr/bin/env bash
# Antigravity (agy) adapter: install/remove agent-state hooks in the shared
# ~/.gemini/config/hooks.json (agy has no permission or idle hook events —
# fidelity is running/stop; launch/off come from the .zshrc wrapper).
# Hooks run synchronously via sh -c with cwd = the hooks.json directory, so
# commands use absolute-ish paths and always end with echo '{}' — the
# output contract; for Stop anything but "continue" lets the agent stop.
# Idempotent — re-running never duplicates entries. Usage: agy-install.sh [--remove]
set -euo pipefail

CFG="${GEMINI_CONFIG_DIR:-$HOME/.gemini/config}/hooks.json"
mkdir -p "$(dirname "$CFG")"
[ -f "$CFG" ] || echo '{}' > "$CFG"
cp "$CFG" "$CFG.bak"

python3 - "${1:-install}" "$CFG" <<'PY'
import json, sys

mode, path = sys.argv[1], sys.argv[2]
key = "tmux-agent-status"
cmd = ('S="${DOTFILES_DIR:-$HOME/dotfiles}/tmux/agents/agent-state.sh"; '
       '[ -x "$S" ] && "$S" %s agy; echo \'{}\'')
handler = lambda verb: {"type": "command", "timeout": 5, "command": cmd % verb}

with open(path) as f:
    hooks = json.load(f)

hooks.pop(key, None)

if mode != "--remove":
    hooks[key] = {
        # every model invocation marks the agent busy; PostToolUse keeps
        # the stall clock moving through long tool phases. PreToolUse is
        # avoided on purpose: its output contract demands a decision and
        # malformed output denies every tool call.
        "PreInvocation": [handler("running")],
        "PostToolUse": [{"matcher": "*", "hooks": [handler("running")]}],
        "Stop": [handler("stop")],
    }

with open(path, "w") as f:
    json.dump(hooks, f, indent=2)
    f.write("\n")

print(("removed from " if mode == "--remove" else "installed into ") + path)
PY
