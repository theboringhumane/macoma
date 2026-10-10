# Only sourced by the managed ZDOTDIR after the user's own .zshrc.
[[ ${MACARCHY_MANAGED-} == 1 ]] || return
typeset -U path
path+=(/opt/homebrew/bin /usr/local/bin)
export CLICOLOR=1

# Use the integration shipped by the installed Ghostty; do not redistribute it.
if [[ -n ${GHOSTTY_RESOURCES_DIR-} && -r "$GHOSTTY_RESOURCES_DIR/shell-integration/zsh/ghostty-integration" ]]; then
  source "$GHOSTTY_RESOURCES_DIR/shell-integration/zsh/ghostty-integration"
fi

if (( $+commands[eza] )); then
  alias ls='eza --group-directories-first --icons=auto'
  alias ll='eza --long --all --group-directories-first --icons=auto'
  alias lt='eza --tree --level=2 --group-directories-first --icons=auto'
else
  alias ls='ls -G'
  alias ll='ls -lahG'
fi

# Avoid loading a second copy when the user's .zshrc already loaded a tool.
if (( $+commands[starship] )); then
  export STARSHIP_CONFIG="$MACARCHY_TERMINAL_PROFILE/starship.toml"
  [[ ${STARSHIP_SHELL-} == zsh ]] || eval "$(starship init zsh)"
else
  PROMPT='%F{blue}%~%f %F{magenta}❯%f '
fi
if (( $+commands[zoxide] && ! $+functions[__zoxide_z] )); then
  eval "$(zoxide init zsh)"
fi
if (( $+commands[fzf] && ! $+functions[fzf-history-widget] )); then
  # --zsh is supported by current fzf; older versions keep working without it.
  _macarchy_fzf_init=$(fzf --zsh 2>/dev/null) && eval "$_macarchy_fzf_init"
  unset _macarchy_fzf_init
fi
if (( $+commands[mise] )) && [[ ${MISE_SHELL-} != zsh ]]; then
  eval "$(mise activate zsh)"
fi

if [[ ${MACARCHY_SHOW_LISTING-} == 1 ]]; then
  unset MACARCHY_SHOW_LISTING
  if (( $+commands[eza] )); then
    command eza --grid --group-directories-first --icons=auto
  else
    /bin/ls -G
  fi
fi
