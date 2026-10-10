# Forward the normal zsh startup files, then return to the managed startup path.
if [[ ${MACARCHY_MANAGED-} == 1 && -n ${MACARCHY_TERMINAL_PROFILE-} ]]; then
  ZDOTDIR=${MACARCHY_ORIGINAL_ZDOTDIR:-$HOME}
  if [[ -r "$ZDOTDIR/.zshenv" && "$ZDOTDIR" != "$MACARCHY_TERMINAL_PROFILE/zsh" ]]; then
    source "$ZDOTDIR/.zshenv"
  fi
  export MACARCHY_ORIGINAL_ZDOTDIR=${ZDOTDIR:-$HOME}
  export ZDOTDIR="$MACARCHY_TERMINAL_PROFILE/zsh"
fi
