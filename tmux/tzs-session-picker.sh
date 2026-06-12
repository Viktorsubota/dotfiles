#!/usr/bin/env bash
# Fork of jeffnguyen695/tmux-zoxide-session (zoxide-session.sh).
# Same behavior, but options/header/help are inlined instead of fetched via
# ~60 subprocess spawns per launch — that overhead was ~0.8s per open.

source "$(dirname "$0")/fzf-theme.sh"

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
key_help="ctrl-h"
key_quit="esc"

prompt_sessions="Sessions"
prompt_windows="Windows"
prompt_find="Directories"
prompt_kill_session="Kill sessions"
prompt_kill_window="Kill windows"
prompt_rename_session="Rename session"
prompt_rename_window="Rename window"
prompt_help="Help"

Y=$'\033[0;33m'
R=$'\033[0m'

header=":: <${Y}${key_help}${R}> for ${Y}Help${R} | 󰿄 <${Y}${key_accept}${R}> |  <${Y}${key_new}${R}> |  <${Y}${key_find}${R}> |  <${Y}${key_window}${R}> | 󱂧 <${Y}${key_kill}${R}> | 󰑕 <${Y}${key_rename}${R}> |  <${Y}${key_quit}${R}>"

# format: yellow "icon key" padded to 10 chars, built with printf -v (no forks)
fmt() { printf -v "$1" '%s%s %-10s%s' "$Y" "$2" "$3" "$R"; }
fmt f_accept "󰿄" "$key_accept"
fmt f_new "" "$key_new"
fmt f_find "" "$key_find"
fmt f_window "" "$key_window"
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
%s Kill selected session / window
%s Rename selected session / window
%s Back / Quit
%s Select up
%s Select down
%s Scroll preview up
%s Scroll preview down
%s Show help' "$f_accept" "$f_new" "$f_find" "$f_window" "$f_kill" "$f_rename" "$f_quit" "$f_up" "$f_down" "$f_pup" "$f_pdown" "$f_help"

list_sessions='tmux list-sessions | sed -E \"s/:.*$//\"'

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

handle_window='load_windows="clear-query+enable-search+change-prompt('"$prompt_windows"' > )+reload('"$list_windows"')+change-preview(tmux capture-pane -ep -t \{1})"
if [[ $FZF_PROMPT =~ '"$prompt_find"' ]]; then
  echo "toggle-sort+$load_windows"
elif [[ ! $FZF_PROMPT =~ '"$prompt_windows"' ]]; then
  echo "$load_windows"
fi'

handle_kill='if [[ $FZF_PROMPT =~ '"$prompt_sessions"' ]]; then
  echo "clear-query+change-prompt('"$prompt_kill_session"' (y/n) > )+reload(echo {+1})+disable-search"
elif [[ $FZF_PROMPT =~ '"$prompt_windows"' ]]; then
  echo "clear-query+change-prompt('"$prompt_kill_window"' (y/n) > )+reload(echo {+1})+disable-search"
fi'

handle_rename='if [[ $FZF_PROMPT =~ '"$prompt_sessions"' ]]; then
  echo "clear-query+change-prompt('"$prompt_rename_session"' > )+change-preview(echo "New session name: \{q}")+reload(echo {})+disable-search"
elif [[ $FZF_PROMPT =~ '"$prompt_windows"' ]]; then
  echo "clear-query+change-prompt('"$prompt_rename_window"' > )+change-preview(echo "New window name: \{q}")+reload(echo {})+disable-search"
fi'

handle_accept='load_sessions="clear-query+enable-search+change-prompt('"$prompt_sessions"' > )+change-preview(tmux capture-pane -ep -t \{1})+reload('"$list_sessions"')"
load_windows="clear-query+enable-search+change-prompt('"$prompt_windows"' > )+change-preview(tmux capture-pane -ep -t \{1})+reload('"$list_windows"')"

if [[ $FZF_PROMPT =~ '"$prompt_sessions"' ]]; then
  echo "replace-query+print-query"
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
  echo "execute-silent(tmux rename-session -t {1} {q})+$load_sessions"
elif [[ $FZF_PROMPT =~ "'"$prompt_rename_window"'" ]]; then
  echo "execute-silent(tmux rename-window -t {1} {q})+$load_windows"
fi'

handle_new='if [[ $FZF_PROMPT =~ '"$prompt_sessions"' ]]; then
  echo "execute-silent(tmux new-session -ds "{q}")+print-query"
fi'

handle_quit='load_sessions="clear-query+enable-search+change-prompt('"$prompt_sessions"' > )+reload('"$list_sessions"')+change-preview(tmux capture-pane -ep -t \{1})"
load_windows="clear-query+enable-search+change-prompt('"$prompt_windows"' > )+change-preview(tmux capture-pane -ep -t \{1})+reload('"$list_windows"')"

if [[ $FZF_PROMPT =~ '"$prompt_find"' ]]; then
  echo "toggle-sort+$load_sessions"
elif [[ $FZF_PROMPT =~ ('"$prompt_windows"'|'"$prompt_find"'|"'"$prompt_kill_session"'"|"'"$prompt_rename_session"'"|'"$prompt_help"') ]]; then
  echo "$load_sessions"
elif [[ $FZF_PROMPT =~ ("'"$prompt_kill_window"'"|"'"$prompt_rename_window"'") ]]; then
  echo "$load_windows"
else
  echo "abort"
fi'

handle_help="change-prompt($prompt_help > )+reload()+change-preview(echo '$help')"

launch() {
	local sessions
	sessions=$(tmux list-sessions | sed -E "s/:.*$//")

	echo -e "${sessions// /}" | fzf-tmux \
		-p "$window_width,$window_height" \
		--preview-window="${preview_location},${preview_ratio},," \
		--border bold \
		--header="$header" \
		--prompt="$prompt_sessions > " \
		--preview="tmux capture-pane -ep -t {1}" \
		--border-label " Current: $(tmux display-message -p '#S') " \
		--bind 'focus:transform-preview-label:echo [ {1} ]' \
		--bind "$key_window:transform:$handle_window" \
		--bind "$key_find:transform:$handle_find" \
		--bind "$key_kill:transform:$handle_kill" \
		--bind "$key_rename:transform:$handle_rename" \
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

handle_output "$(launch)"
