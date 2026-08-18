#!/usr/bin/env bash
# Claude Code adapter: install/remove agent-state hooks in
# ~/.claude/settings.json (or $CLAUDE_CONFIG_DIR). Idempotent — re-running
# never duplicates entries. Usage: claude-install.sh [--remove]
set -euo pipefail

CFG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"
cp "$CFG" "$CFG.bak"

python3 - "${1:-install}" "$CFG" <<'PY'
import json, sys

mode, path = sys.argv[1], sys.argv[2]
marker = "tmux/agents/agent-state.sh"
cmd = ('S="${DOTFILES_DIR:-$HOME/dotfiles}/tmux/agents/agent-state.sh"; '
       '[ -x "$S" ] && "$S" %s claude; exit 0')
wanted = [
    ("UserPromptSubmit", "", "running"),
    ("PermissionRequest", "", "action"),
    ("Notification", "permission_prompt", "action"),
    # agent_needs_input fires for a blocking multi-choice question
    # (AskUserQuestion-style) — the agent is fully stopped waiting on a
    # discrete decision, same as a permission dialog: dialog-class red,
    # not the softer waiting-class yellow
    ("Notification", "agent_needs_input", "action"),
    # idle_prompt alone is a softer signal: it just means quiet for a
    # while, escalates quiet agents only, never overrides running (late
    # notifications flap states)
    ("Notification", "idle_prompt", "waiting"),
    # a tool actually executing means a pending permission was answered —
    # resolves `action` back to `running` (approval itself fires no hook)
    ("PostToolUse", "", "running"),
    ("PostToolUseFailure", "", "running"),
    ("Stop", "", "stop"),
    ("StopFailure", "", "stop"),
]

with open(path) as f:
    settings = json.load(f)

hooks = settings.setdefault("hooks", {})
for ev in list(hooks):
    kept = [e for e in hooks[ev]
            if not any(marker in h.get("command", "") for h in e.get("hooks", []))]
    if kept:
        hooks[ev] = kept
    else:
        del hooks[ev]

if mode != "--remove":
    for ev, matcher, state in wanted:
        entry = {"hooks": [{"type": "command", "command": cmd % state}]}
        if matcher:
            entry["matcher"] = matcher
        hooks.setdefault(ev, []).append(entry)

if not hooks:
    settings.pop("hooks", None)

with open(path, "w") as f:
    json.dump(settings, f, indent=2)
    f.write("\n")

print(("removed from " if mode == "--remove" else "installed into ") + path)
PY
