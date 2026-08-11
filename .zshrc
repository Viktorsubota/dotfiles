# Disable dotenv confirmation
ZSH_DOTENV_PROMPT=false

# Enable Powerlevel10k instant prompt. Should stay close to the top of ~/.zshrc.
# Initialization code that may require console input (password prompts, [y/n]
# confirmations, etc.) must go above this block; everything else may go below.
if [[ -r "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh" ]]; then
  source "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh"
fi

if [[ -f "/opt/homebrew/bin/brew" ]] then
  # If you're using macOS, you'll want this enabled
  eval "$(/opt/homebrew/bin/brew shellenv)"
fi

# Set the directory we want to store zinit and plugins
ZINIT_HOME="${XDG_DATA_HOME:-${HOME}/.local/share}/zinit/zinit.git"

# Download Zinit, if it's not there yet
if [ ! -d "$ZINIT_HOME" ]; then
   mkdir -p "$(dirname $ZINIT_HOME)"
   git clone https://github.com/zdharma-continuum/zinit.git "$ZINIT_HOME"
fi

# Source/Load zinit
source "${ZINIT_HOME}/zinit.zsh"

# Preferred editor for local and remote sessions
if [[ -n $SSH_CONNECTION ]]; then
  export EDITOR='vim'
else
  export EDITOR='nvim'
fi

# Add in Powerlevel10k
zinit ice depth=1; zinit light romkatv/powerlevel10k

# Add in zsh plugins
zinit light zsh-users/zsh-syntax-highlighting
zinit light zsh-users/zsh-completions
zinit light zsh-users/zsh-autosuggestions
zinit light Aloxaf/fzf-tab
zinit light zsh-users/zsh-history-substring-search

# Add in snippets
zinit snippet OMZP::git
zinit snippet OMZP::sudo
zinit snippet OMZP::aws
zinit ice wait lucid
zinit snippet OMZP::kubectl
zinit ice wait lucid
zinit snippet OMZP::kubectx
zinit snippet OMZP::command-not-found

zinit snippet OMZP::dotenv

# Load completions (cached for fast shell startup)
autoload -Uz compinit
if [[ -n ${ZDOTDIR:-$HOME}/.zcompdump(N.m-1) ]]; then
  compinit -C
else
  compinit
fi

zinit cdreplay -q

# To customize prompt, run `p10k configure` or edit ~/.p10k.zsh.
[[ ! -f ~/.p10k.zsh ]] || source ~/.p10k.zsh

# Keybindings
bindkey -e # Emacs mode
bindkey '^p' history-substring-search-up
bindkey '^n' history-substring-search-down
bindkey '^[w' kill-region
# Ctrl + f - to apply a suggestion word-by-word.
# Ctrl + e - to apply it to the end of line.
bindkey '^f' forward-word

# History
HISTSIZE=500000
HISTFILE=~/.zsh_history
SAVEHIST=$HISTSIZE
setopt appendhistory
setopt sharehistory
setopt hist_ignore_space
setopt hist_ignore_all_dups
setopt hist_save_no_dups
setopt hist_ignore_dups
setopt hist_find_no_dups


# Check for dark mode via a fast file cache updated by tmux, falling back to defaults read
is_dark() {
  if [[ -f ~/.cache/tmux_theme ]]; then
    [[ "$(< ~/.cache/tmux_theme)" == "dark" ]]
  else
    defaults read -g AppleInterfaceStyle &>/dev/null
  fi
}
# Initialize the theme file cache once at shell startup if missing
if [[ ! -f ~/.cache/tmux_theme ]]; then
  mkdir -p ~/.cache
  if defaults read -g AppleInterfaceStyle &>/dev/null; then
    echo "dark" > ~/.cache/tmux_theme
  else
    echo "light" > ~/.cache/tmux_theme
  fi
fi

export FZF_CTRL_R_OPTS="--reverse"
export FZF_TMUX_OPTS="-p"

_update_fzf_theme() {
  if is_dark; then
    # Catppuccin Frappe
    export FZF_DEFAULT_OPTS=" \
--multi \
--color=bg+:#414559,bg:#303446,spinner:#F2D5CF,hl:#E78284 \
--color=fg:#C6D0F5,header:#E78284,info:#CA9EE6,pointer:#F2D5CF \
--color=marker:#BABBF1,fg+:#C6D0F5,prompt:#CA9EE6,hl+:#E78284 \
--color=selected-bg:#51576D \
--color=border:#414559,label:#C6D0F5"
    # Catppuccin Macchiato (unused)
    # export FZF_DEFAULT_OPTS=" \
    # --multi \
    # --color=bg+:#363A4F,bg:#24273A,spinner:#F4DBD6,hl:#ED8796 \
    # --color=fg:#CAD3F5,header:#ED8796,info:#C6A0F6,pointer:#F4DBD6 \
    # --color=marker:#B7BDF8,fg+:#CAD3F5,prompt:#C6A0F6,hl+:#ED8796 \
    # --color=selected-bg:#494D64 \
    # --color=border:#363A4F,label:#CAD3F5"
  else
    export FZF_DEFAULT_OPTS=" \
--multi \
--color=bg+:#CCD0DA,bg:#EFF1F5,spinner:#DC8A78,hl:#D20F39 \
--color=fg:#4C4F69,header:#D20F39,info:#8839EF,pointer:#DC8A78 \
--color=marker:#7287FD,fg+:#4C4F69,prompt:#8839EF,hl+:#D20F39 \
--color=selected-bg:#BCC0CC \
--color=border:#CCD0DA,label:#4C4F69"
  fi
}
autoload -Uz add-zsh-hook
add-zsh-hook precmd _update_fzf_theme
_update_fzf_theme

# Shell integrations
eval "$(fzf --zsh)"

# Update theme dynamically on fzf widget invocations
for widget in fzf-history-widget fzf-file-widget fzf-cd-widget; do
  if (( ${+functions[$widget]} )); then
    orig_func="_${widget//-/_}_orig"
    eval "
      functions[$orig_func]=\$functions[$widget]
      $widget() {
        _update_fzf_theme
        $orig_func \"\$@\"
      }
    "
  fi
done

# Completion styling
zstyle ':completion:*' matcher-list 'm:{a-z}={A-Za-z}'
zstyle ':completion:*' list-colors "${(s.:.)LS_COLORS}"
zstyle ':completion:*' menu no
zstyle ':fzf-tab:complete:cd:*' fzf-preview 'eza -1 --color=always $realpath'
zstyle ':fzf-tab:complete:__zoxide_z:*' fzf-preview 'eza -1 --color=always $realpath'
zstyle ':fzf-tab:*' fzf-command ftb-tmux-popup
# apply to all command
zstyle ':fzf-tab:*' popup-min-size 70 8
# only apply to 'diff'
zstyle ':fzf-tab:complete:diff:*' popup-min-size 80 12

# Aliases
alias k="kubectl"
alias vim="nvim"
alias v="nvim"
alias ls="eza --icons=auto --group-directories-first"
alias c="claude"

# Custom
export KUBE_EDITOR="nvim"
if [[ $commands[kubectl] ]]; then
  # Lazy-load kubectl completion to avoid running slow kubectl subprocess on startup
  compdef _kubectl kubectl
  _kubectl() {
    unset -f _kubectl
    local KUBECTL_COMP_FILE="${XDG_CACHE_HOME:-$HOME/.cache}/kubectl_completion"
    if [[ ! -f "$KUBECTL_COMP_FILE" ]]; then
      mkdir -p "$(dirname "$KUBECTL_COMP_FILE")"
      kubectl completion zsh > "$KUBECTL_COMP_FILE"
    fi
    source "$KUBECTL_COMP_FILE"
    _kubectl "$@"
  }
fi

# Go defaults GOPATH to ~/go (brew-managed go, no GOROOT/GOPROXY overrides needed)
export PATH=$PATH:$HOME/go/bin

if command -v pyenv >/dev/null; then
  # Keep pyenv shims out of brew's PATH so `brew doctor` stays quiet
  alias brew='env PATH="${PATH//$(pyenv root)\/shims:/}" brew'
  export PYENV_ROOT="$HOME/.pyenv"
  [[ -d $PYENV_ROOT/bin ]] && export PATH="$PYENV_ROOT/bin:$PATH"

  # Fast native zsh initialization (replaces eval "$(pyenv init -)" to avoid bash subshell)
  export PATH="$PYENV_ROOT/shims:${PATH}"
  export PYENV_SHELL=zsh
  pyenv() {
    local command=${1:-}
    [ "$#" -gt 0 ] && shift
    case "$command" in
    rehash|shell)
      eval "$(pyenv "sh-$command" "$@")"
      ;;
    *)
      command pyenv "$command" "$@"
      ;;
    esac
  }
fi

autoload -z edit-command-line
zle -N edit-command-line
bindkey "^X^E" edit-command-line

# Treat these characters part of words for word operations
WORDCHARS='*?_-.[]~=&;!#$%^(){}<>'

export NVM_DIR="$HOME/.nvm"
if [ -s "/opt/homebrew/opt/nvm/nvm.sh" ]; then
  # Lazy-load NVM on first execution of node/npm/npx etc. to save ~0.8s on shell startup
  declare -a __nvm_commands=(nvm node npm npx yarn pnpm)
  function __load_nvm() {
    unalias $__nvm_commands
    unset -f __load_nvm
    [ -s "/opt/homebrew/opt/nvm/nvm.sh" ] && \. "/opt/homebrew/opt/nvm/nvm.sh"
    [ -s "/opt/homebrew/opt/nvm/etc/bash_completion.d/nvm" ] && \. "/opt/homebrew/opt/nvm/etc/bash_completion.d/nvm"
    "$@"
  }
  for cmd in $__nvm_commands; do
    alias $cmd="__load_nvm $cmd"
  done
fi

# Must be last — zoxide hooks into cd
# Silence zoxide's doctor inside AI CLI tools (their shell snapshots drop chpwd_functions).
[[ -n $CLAUDECODE || -n $OPENCODE || -n $GEMINI_CLI ]] && export _ZO_DOCTOR=0
eval "$(zoxide init --cmd cd zsh)"
