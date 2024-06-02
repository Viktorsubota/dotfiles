# If this module depends on an external Tmux plugin, say so in a comment.
# E.g.: Requires https://github.com/aaronpowell/tmux-weather

show_pane-zoom() { # This function name must match the module name!
  local index icon color text module left_separator right_separator

  icon=" "
  color="$thm_orange"
  text=""

  left_separator=""
  right_separator=""

  module="#{?window_zoomed_flag,#[fg=$color]$left_separator#[fg=$thm_bg bg=$color]$icon#[fg=$thm_bg]$text#[bg=default fg=$color]$right_separator,}"

  echo "$module"
}
