# Sourced by the tmux picker scripts — sets fzf colors from the macOS appearance.
# (fzf-tmux forwards FZF_DEFAULT_OPTS into the popup, so exporting here is enough.)

is_dark() {
  defaults read -g AppleInterfaceStyle &>/dev/null
}

if is_dark; then
    # Catppuccin Frappe
    export FZF_DEFAULT_OPTS=" \
--color=bg+:#414559,bg:#303446,spinner:#F2D5CF,hl:#E78284 \
--color=fg:#C6D0F5,header:#E78284,info:#CA9EE6,pointer:#F2D5CF \
--color=marker:#BABBF1,fg+:#C6D0F5,prompt:#CA9EE6,hl+:#E78284 \
--color=selected-bg:#51576D \
--color=border:#414559,label:#C6D0F5"
else
    # Catppuccin Latte
    export FZF_DEFAULT_OPTS=" \
--color=bg+:#CCD0DA,bg:#EFF1F5,spinner:#DC8A78,hl:#D20F39 \
--color=fg:#4C4F69,header:#D20F39,info:#8839EF,pointer:#DC8A78 \
--color=marker:#7287FD,fg+:#4C4F69,prompt:#8839EF,hl+:#D20F39 \
--color=selected-bg:#BCC0CC \
--color=border:#CCD0DA,label:#4C4F69"
fi
