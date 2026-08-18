#!/usr/bin/env bash
# Fork of jeffnguyen695/tmux-zoxide-session (zoxide-session.sh).
# Same behavior, but options/header/help are inlined instead of fetched via
# ~60 subprocess spawns per launch — that overhead was ~0.8s per open.

source "$(dirname "$0")/fzf-theme.sh"

AGENTS_DIR="$(cd "$(dirname "$0")" && pwd)/agents"
AGENTS_RENDER="$AGENTS_DIR/agents-render.sh"
AGENTS_CTL="$AGENTS_DIR/agents-ctl.sh"
AGENT_STATE="$AGENTS_DIR/agent-state.sh"

preview_location="top"
preview_ratio="70%"
window_height="65%"
window_width="65%"

key_accept="enter"
key_new="ctrl-e"
key_kill="ctrl-x"
key_rename="ctrl-r"
key_find="ctrl-f"
key_window="ctrl-w"
key_select_up="ctrl-p"
key_select_down="ctrl-n"
key_preview_up="ctrl-u"
key_preview_down="ctrl-d"
key_agents="ctrl-g"
key_urgent="ctrl-t"
key_mute="ctrl-b"
key_dismiss="ctrl-o"
AGENTS_SETTINGS="$AGENTS_DIR/agents-settings.sh"
key_help="ctrl-h"
key_quit="esc"

prompt_sessions="Sessions"
prompt_windows="Windows"
prompt_find="Directories"
prompt_kill_session="Kill sessions"
prompt_kill_window="Kill windows"
prompt_rename_session="Rename session"
prompt_rename_window="Rename window"
prompt_agents="Agents"
prompt_agent_send="Send to agent"
prompt_kill_agent="Kill agents"
prompt_name_agent="Name agent"
prompt_help="Help"

Y=$'\033[0;33m'
R=$'\033[0m'

header=":: <${Y}${key_help}${R}> for ${Y}Help${R} | 󰿄 <${Y}${key_accept}${R}> |  <${Y}${key_new}${R}> |  <${Y}${key_find}${R}> |  <${Y}${key_window}${R}> | 󱂧 <${Y}${key_kill}${R}> | 󰑕 <${Y}${key_rename}${R}> |  <${Y}${key_quit}${R}>"

printf -v header_agents ':: 󰿄 jump  ${Y}^e${R} prompt  ${Y}^x${R} kill  ${Y}^t${R} urgent  ${Y}^b${R} mute  ${Y}^q${R} disable  ${Y}^o${R} dismiss  ${Y}^r${R} name  ${Y}^l${R} refresh  ${Y}^v${R} diff'
header_agents="${header_agents//\$\{Y\}/$Y}"
header_agents="${header_agents//\$\{R\}/$R}"

# non-default global settings surface in the agents header
SETTINGS_FILE="${XDG_STATE_HOME:-$HOME/.local/state}/tmux-agents/settings.tsv"
if [ -f "$SETTINGS_FILE" ]; then
    settings_badge="$(awk -F'\t' '$1 == "*" {
        if ($2 == "mute" && $3 == "on") b = b "  ALL MUTED"
        if ($2 == "desktop" && $3 == "on") b = b "  desktop-notify"
        if ($2 == "enabled" && $3 == "off") b = b "  LAYER OFF"
    } END { printf "%s", b }' "$SETTINGS_FILE" 2>/dev/null)"
    [ -n "$settings_badge" ] && header_agents="${header_agents}${Y}${settings_badge}${R}"
fi

# format: yellow "icon key" padded to 10 chars, built with printf -v (no forks)
fmt() { printf -v "$1" '%s%s %-10s%s' "$Y" "$2" "$3" "$R"; }
fmt f_accept "󰿄" "$key_accept"
fmt f_new "" "$key_new"
fmt f_find "" "$key_find"
fmt f_window "" "$key_window"
fmt f_agents "󰊠" "$key_agents"
fmt f_kill "󱂧" "$key_kill"
fmt f_rename "󰑕" "$key_rename"
fmt f_quit "" "$key_quit"
fmt f_up "" "$key_select_up"
fmt f_down "" "$key_select_down"
fmt f_pup "" "$key_preview_up"
fmt f_pdown "" "$key_preview_down"
fmt f_help "" "$key_help"

printf -v help '
%s Go to selected session / window
             If no match, create a new session from the best matching directory
%s Create a new session with the query as its name
%s Find directories with zoxide
%s List session windows
%s Agents view: enter jumps to agent, ctrl-e sends a prompt,
             ctrl-x kills agent, ctrl-r names the agent, ctrl-l refreshes,
             ctrl-v toggles diff preview,
             ctrl-t marks agent urgent — always red, always loud,
             ctrl-b mutes the session — also works on session rows,
             ctrl-q disables an agent — visible here, invisible elsewhere,
             ctrl-o dismisses a stuck red state — ESC inside an agent fires
             no hook, so tmux cannot see it; this is the manual override
             NOTE: keep this help free of parentheses — it is embedded in a
             change-preview action and a stray paren kills fzf at startup
%s Kill selected session / window
%s Rename selected session / window
%s Back / Quit
%s Select up
%s Select down
%s Scroll preview up
%s Scroll preview down
%s Show help' "$f_accept" "$f_new" "$f_find" "$f_window" "$f_agents" "$f_kill" "$f_rename" "$f_quit" "$f_up" "$f_down" "$f_pup" "$f_pdown" "$f_help"

list_sessions="$AGENTS_RENDER --sessions"
list_agents="$AGENTS_RENDER --rows"

list_windows='max_len=-1
for line in \$(tmux list-windows -a -F \"#{session_name}:#{window_index}\"); do
  if [[ \${#line} -gt \$max_len ]]; then
    max_len=\${#line}
  fi
done
tmux list-windows -a -F \"#{p\${max_len}:#{session_name}:#{window_index}}  #{T:tree_mode_format}\"'

handle_find='if [[ ! $FZF_PROMPT =~ '"$prompt_find"' ]]; then
  echo "clear-query+enable-search+toggle-sort+change-prompt('"$prompt_find"' > )+reload(zoxide query --list)+change-preview(ls --color=always -Cp \{1})"
fi'

handle_window='load_windows="clear-query+enable-search+change-prompt('"$prompt_windows"' > )+reload('"$list_windows"')+change-preview(tmux capture-pane -ep -t \{1} | tail -n $FZF_PREVIEW_LINES)+change-header('"$header"')"
if [[ $FZF_PROMPT =~ '"$prompt_find"' ]]; then
  echo "toggle-sort+$load_windows"
elif [[ ! $FZF_PROMPT =~ '"$prompt_windows"' ]]; then
  echo "$load_windows"
fi'

handle_agents='if [[ ! $FZF_PROMPT =~ '"$prompt_agents"' ]]; then
  echo "clear-query+enable-search+change-prompt('"$prompt_agents"' > )+reload('"$list_agents"')+change-preview(tmux capture-pane -ep -t \{1} | tail -n $FZF_PREVIEW_LINES)+change-header('"$header_agents"')"
fi'

handle_urgent='if [[ $FZF_PROMPT =~ '"$prompt_agents"' ]]; then
  echo "execute-silent('"$AGENTS_CTL"' --urgent {1})+reload-sync('"$list_agents"')"
fi'

handle_disable='if [[ $FZF_PROMPT =~ '"$prompt_agents"' ]]; then
  echo "execute-silent('"$AGENTS_CTL"' --disable {1})+reload-sync('"$list_agents"')"
fi'

handle_dismiss='if [[ $FZF_PROMPT =~ '"$prompt_agents"' ]]; then
  echo "execute-silent('"$AGENT_STATE"' dismiss claude {1})+reload-sync('"$list_agents"')"
fi'

handle_mute='if [[ $FZF_PROMPT =~ '"$prompt_agents"' ]]; then
  echo "execute-silent('"$AGENTS_CTL"' --mute {1})+reload-sync('"$list_agents"')"
elif [[ $FZF_PROMPT =~ '"$prompt_sessions"' ]]; then
  echo "execute-silent('"$AGENTS_SETTINGS"' toggle {-1} mute)+reload-sync('"$list_sessions"')"
fi'

handle_kill='if [[ $FZF_PROMPT =~ '"$prompt_agents"' ]]; then
  echo "clear-query+change-prompt('"$prompt_kill_agent"' (y/n) > )+reload(echo {+1})+disable-search"
elif [[ $FZF_PROMPT =~ '"$prompt_sessions"' ]]; then
  echo "clear-query+change-prompt('"$prompt_kill_session"' (y/n) > )+reload(echo {+-1})+disable-search"
elif [[ $FZF_PROMPT =~ '"$prompt_windows"' ]]; then
  echo "clear-query+change-prompt('"$prompt_kill_window"' (y/n) > )+reload(echo {+1})+disable-search"
fi'

handle_rename='if [[ $FZF_PROMPT =~ '"$prompt_agents"' ]]; then
  echo "clear-query+change-prompt('"$prompt_name_agent"' > )+change-preview(echo "New agent name: \{q}")+reload(echo {})+disable-search"
elif [[ $FZF_PROMPT =~ '"$prompt_sessions"' ]]; then
  echo "clear-query+change-prompt('"$prompt_rename_session"' > )+change-preview(echo "New session name: \{q}")+reload(echo {})+disable-search"
elif [[ $FZF_PROMPT =~ '"$prompt_windows"' ]]; then
  echo "clear-query+change-prompt('"$prompt_rename_window"' > )+change-preview(echo "New window name: \{q}")+reload(echo {})+disable-search"
fi'

handle_accept='load_sessions="clear-query+enable-search+change-prompt('"$prompt_sessions"' > )+change-preview(tmux capture-pane -ep -t \{-1} | tail -n $FZF_PREVIEW_LINES)+reload('"$list_sessions"')+change-header('"$header"')"
load_windows="clear-query+enable-search+change-prompt('"$prompt_windows"' > )+change-preview(tmux capture-pane -ep -t \{1} | tail -n $FZF_PREVIEW_LINES)+reload('"$list_windows"')+change-header('"$header"')"
load_agents="clear-query+enable-search+change-prompt('"$prompt_agents"' > )+change-preview(tmux capture-pane -ep -t \{1} | tail -n $FZF_PREVIEW_LINES)+reload-sync('"$list_agents"')+change-header('"$header_agents"')"

if [[ $FZF_PROMPT =~ '"$prompt_agents"' ]]; then
  echo "execute-silent(tmux select-window -t \{1} && tmux select-pane -t \{1} && tmux switch-client -t \{1} || tmux display-message \"agent gone — ctrl-l refreshes\")+abort"
elif [[ $FZF_PROMPT =~ "'"$prompt_agent_send"'" ]]; then
  echo "execute-silent('"$AGENTS_CTL"' --send \{1} \{q})+$load_agents"
elif [[ $FZF_PROMPT =~ "'"$prompt_kill_agent"'" ]]; then
  if [[ $FZF_QUERY == "y" ]]; then
    echo "execute-silent('"$AGENTS_CTL"' --kill {+})+$load_agents"
  else
    echo "$load_agents"
  fi
elif [[ $FZF_PROMPT =~ "'"$prompt_name_agent"'" ]]; then
  echo "execute-silent(tmux set -p -t {1} @agent_name {q})+$load_agents"
elif [[ $FZF_PROMPT =~ '"$prompt_sessions"' ]]; then
  echo "transform-query(echo {-1})+print-query"
elif [[ $FZF_PROMPT =~ '"$prompt_windows"' ]]; then
  echo "transform-query(echo {1})+print-query"
elif [[ $FZF_PROMPT =~ '"$prompt_find"' ]]; then
  echo "replace-query+print-query"
elif [[ $FZF_PROMPT =~ "'"$prompt_kill_session"'" ]]; then
  if [[ $FZF_QUERY == "y" ]]; then
    echo "execute-silent(for sess in \$(echo "{}"); do tmux kill-session -t \$sess; done)+$load_sessions"
  else
    echo "$load_sessions"
  fi
elif [[ $FZF_PROMPT =~ "'"$prompt_kill_window"'" ]]; then
  if [[ $FZF_QUERY == "y" ]]; then
    echo "execute-silent(for win in \$(echo "{}"); do tmux kill-window -t \$win; done)+$load_windows"
  else
    echo "$load_windows"
  fi
elif [[ $FZF_PROMPT =~ "'"$prompt_rename_session"'" ]]; then
  echo "execute-silent(tmux rename-session -t {-1} {q})+$load_sessions"
elif [[ $FZF_PROMPT =~ "'"$prompt_rename_window"'" ]]; then
  echo "execute-silent(tmux rename-window -t {1} {q})+$load_windows"
fi'

handle_new='if [[ $FZF_PROMPT =~ '"$prompt_agents"' ]]; then
  echo "clear-query+change-prompt('"$prompt_agent_send"' > )+reload(echo {})+disable-search"
elif [[ $FZF_PROMPT =~ '"$prompt_sessions"' ]]; then
  echo "execute-silent(tmux new-session -ds "{q}" -c "#{pane_current_path}")+print-query"
fi'

handle_quit='load_sessions="clear-query+enable-search+change-prompt('"$prompt_sessions"' > )+reload('"$list_sessions"')+change-preview(tmux capture-pane -ep -t \{-1} | tail -n $FZF_PREVIEW_LINES)+change-header('"$header"')"
load_windows="clear-query+enable-search+change-prompt('"$prompt_windows"' > )+change-preview(tmux capture-pane -ep -t \{1} | tail -n $FZF_PREVIEW_LINES)+reload('"$list_windows"')+change-header('"$header"')"
load_agents="clear-query+enable-search+change-prompt('"$prompt_agents"' > )+change-preview(tmux capture-pane -ep -t \{1} | tail -n $FZF_PREVIEW_LINES)+reload-sync('"$list_agents"')+change-header('"$header_agents"')"

if [[ $FZF_PROMPT =~ '"$prompt_find"' ]]; then
  echo "toggle-sort+$load_sessions"
elif [[ $FZF_PROMPT =~ ("'"$prompt_agent_send"'"|"'"$prompt_kill_agent"'"|"'"$prompt_name_agent"'") ]]; then
  echo "$load_agents"
elif [[ $FZF_PROMPT =~ '"$prompt_agents"' ]]; then
  echo "abort"
elif [[ $FZF_PROMPT =~ ('"$prompt_windows"'|'"$prompt_find"'|"'"$prompt_kill_session"'"|"'"$prompt_rename_session"'"|'"$prompt_help"') ]]; then
  echo "$load_sessions"
elif [[ $FZF_PROMPT =~ ("'"$prompt_kill_window"'"|"'"$prompt_rename_window"'") ]]; then
  echo "$load_windows"
else
  echo "abort"
fi'

handle_sessions='if [[ ! $FZF_PROMPT =~ '"$prompt_sessions"' ]]; then
  echo "clear-query+enable-search+change-prompt('"$prompt_sessions"' > )+reload('"$list_sessions"')+change-preview(tmux capture-pane -ep -t \{-1} | tail -n $FZF_PREVIEW_LINES)+change-header('"$header"')"
fi'

handle_refresh='if [[ $FZF_PROMPT =~ '"$prompt_agents"' ]]; then
  echo "reload-sync('"$list_agents"')"
fi'

handle_help="change-prompt($prompt_help > )+reload()+change-preview(echo '$help')"

launch() {
	local rows init_prompt="$prompt_sessions" init_preview="tmux capture-pane -ep -t {-1} | tail -n \$FZF_PREVIEW_LINES" init_header="$header"
	# the daemon holds its status repaints while this popup is open —
	# each refresh-client blinks the popup cursor; one repaint flushes
	# on close via the resync
	tmux set -g @agents_popup 1 2>/dev/null
	trap 'tmux set -gu @agents_popup 2>/dev/null; "$AGENT_STATE" resync claude - >/dev/null 2>&1' RETURN
	if [[ "${1:-}" == "agents" ]]; then
		init_prompt="$prompt_agents"
		init_header="$header_agents"
		init_preview="tmux capture-pane -ep -t {1} | tail -n \$FZF_PREVIEW_LINES"
		rows=$("$AGENTS_RENDER" --rows)
	else
		rows=$("$AGENTS_RENDER" --sessions)
	fi

	printf '%s\n' "$rows" | fzf \
		--tmux "center,$window_width,$window_height" \
		--ansi \
		--preview-window="${preview_location},${preview_ratio},," \
		--border bold \
		--header="$init_header" \
		--prompt="$init_prompt > " \
		--preview="$init_preview" \
		--border-label " Current: $(tmux display-message -p '#S') " \
		--bind "focus:transform-preview-label:if [[ \$FZF_PROMPT == '"$prompt_agents"'* ]]; then echo [ {1} ]; else echo [ {-1} ]; fi" \
		--bind "$key_agents:transform:$handle_agents" \
		--bind "ctrl-s:transform:$handle_sessions" \
		--bind "ctrl-a:transform:$handle_agents" \
		--bind "$key_urgent:transform:$handle_urgent" \
		--bind "$key_mute:transform:$handle_mute" \
		--bind "$key_dismiss:transform:$handle_dismiss" \
		--bind "ctrl-q:transform:$handle_disable" \
		--bind "ctrl-v:change-preview($AGENTS_CTL --diff {1})|change-preview(tmux capture-pane -ep -t {1} | tail -n \$FZF_PREVIEW_LINES)" \
		--bind "$key_window:transform:$handle_window" \
		--bind "$key_find:transform:$handle_find" \
		--bind "$key_kill:transform:$handle_kill" \
		--bind "$key_rename:transform:$handle_rename" \
		--bind "ctrl-l:transform:$handle_refresh" \
		--bind "$key_accept:transform:$handle_accept" \
		--bind "$key_new:transform:$handle_new" \
		--bind "$key_quit:transform:$handle_quit" \
		--bind "$key_help:$handle_help" \
		--bind "$key_preview_up:preview-half-page-up" \
		--bind "$key_preview_down:preview-half-page-down" \
		--bind "$key_select_up:up" \
		--bind "$key_select_down:down" \
		--scrollbar '▌▐' \
		--print-query \
		--multi \
		--exit-0
}

handle_output() {
	target=$(echo "$1" | tr -d '\n')
	if [[ -z "$target" ]]; then
		exit 0
	fi

	if ! tmux has-session -t="$target" 2>/dev/null; then
		if test -d "$target"; then
			tmux new-session -ds "${target##*/}" -c "$target"
			target="${target##*/}"
		else
			z_target=$(zoxide query "$target")
			target="${z_target##*/}"
			tmux new-session -ds "$target" -c "$z_target"
		fi
	fi
	tmux switch-client -t "$target"
}

handle_output "$(launch "${1:-}")"
