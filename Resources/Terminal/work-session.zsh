#!/bin/zsh
# Arguments are passed directly by Ghostty. No generated shell command is evaluated.
emulate -L zsh
setopt errexit nounset pipefail extendedglob

profile=${1:?Missing managed profile directory}
tmux_binary=${2:?Missing tmux executable}
socket=${3:-macarchy}
mode=${4:-attach}
[[ "$socket" == [A-Za-z0-9._-]## ]] || exit 64
[[ -x "$tmux_binary" && -f "$profile/tmux.conf" ]] || exit 66
typeset -a tmux_command
tmux_command=("$tmux_binary" -L "$socket" -f "$profile/tmux.conf")

if ! "${tmux_command[@]}" has-session -t '=Work' 2>/dev/null; then
  # new-session is the arbiter if two windows start Work at the same time.
  if upper=$("${tmux_command[@]}" new-session -d -P -F '#{pane_id}' \
      -s Work -n Work -x 160 -y 48 -c "$HOME" \
      -e "MACARCHY_TERMINAL_PROFILE=$profile" -e 'MACARCHY_MANAGED=1' \
      -e "ZDOTDIR=$profile/zsh" \
      -e "MACARCHY_ORIGINAL_ZDOTDIR=${MACARCHY_ORIGINAL_ZDOTDIR:-$HOME}" \
      -e "STARSHIP_CONFIG=$profile/starship.toml" \
      -e 'MACARCHY_SHOW_LISTING=1' /bin/zsh -l 2>/dev/null); then
    lower=$("${tmux_command[@]}" split-window -v -p 42 -P -F '#{pane_id}' -t "$upper" -c "$HOME" /bin/zsh -l)
    "${tmux_command[@]}" split-window -h -p 50 -t "$lower" -c "$HOME" /bin/zsh -l
    "${tmux_command[@]}" select-pane -t "$upper"
  else
    # Never recreate or reset an existing session.
    "${tmux_command[@]}" has-session -t '=Work'
  fi
fi

if [[ "$mode" != prepare ]]; then
  exec "${tmux_command[@]}" attach-session -t '=Work'
fi
