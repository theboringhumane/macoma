ZDOTDIR=${MACARCHY_ORIGINAL_ZDOTDIR:-$HOME}
[[ -r "$ZDOTDIR/.zshrc" ]] && source "$ZDOTDIR/.zshrc"
export MACARCHY_ORIGINAL_ZDOTDIR=${ZDOTDIR:-$HOME}
export ZDOTDIR="$MACARCHY_TERMINAL_PROFILE/zsh"
# New native tabs in a Work-profile window also join Work. Existing tmux panes
# already have TMUX, so this never nests another client inside the workspace.
if [[ ${MACARCHY_MANAGED-} == 1 && ${MACARCHY_WORK-} == 1 && -z ${TMUX-} && -x ${MACARCHY_TMUX_BINARY-} ]]; then
  exec /bin/zsh "$MACARCHY_TERMINAL_PROFILE/work-session.zsh" "$MACARCHY_TERMINAL_PROFILE" "$MACARCHY_TMUX_BINARY" macarchy
fi
[[ ${MACARCHY_MANAGED-} == 1 ]] && source "$MACARCHY_TERMINAL_PROFILE/shell-enhancements.zsh"
