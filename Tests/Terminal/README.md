Run `bash Tests/Terminal/run.sh` on macOS with Ghostty and tmux installed.

The executable validates generated profiles using the installed Ghostty CLI, checks palette semantics and argument boundaries, tests atomic activation and restore, and verifies normal zsh startup forwarding. It starts one unique temporary tmux server to check the Work layout and reconnection behavior, then kills that server and removes its temporary files. It does not launch Ghostty or modify the user's terminal configuration.

The app's terminal module requires `Resources/Terminal` in its bundle. Its public UI entry point is `TerminalControlView(theme: MacarchyTheme)`.

The tests also check Apply A → Apply B → new pane, followed by Restore A → new pane. Profile changes update the dedicated tmux server and each existing session's environment for future shells without replacing running processes. Command execution is bounded to 15 seconds and 1 MiB of output by default; timeout and output-limit failure paths are exercised with isolated processes.

Command-T opens a pane. Ordinary managed terminals use Ghostty's `new_split:auto`; the Work profile sends Control-B followed by T to tmux. The tmux binding splits wide panes side by side and tall panes top and bottom, keeping the active process alive. Command-Shift-T explicitly opens a native Ghostty tab; tabs created in the Work profile also attach to Work. Both Ghostty profiles are validated with the installed CLI, and tests execute the exact tmux direction command in wide and tall fixtures. Profiles created by an earlier app version require one Apply Profile action to enable these shortcuts.

Managed profiles live under `~/.config/macarchy/terminal/profiles/<UUID>`. `state.json` selects the applied generation and the previous generation. A failed Ghostty validation never activates a generation. Existing generations remain available for running shells and restore. Macoma only reloads tmux on its `-L macarchy` server. Existing Ghostty windows retain their launch profile; launch a new window to use a newly applied profile.

The managed zsh startup directory forwards the user's startup files in their normal order, including custom `ZDOTDIR` set by `.zshenv`, then loads optional installed enhancements. It does not copy or rewrite the user's dotfiles. Ghostty's installed shell integration is sourced at runtime, not redistributed. Work applies its three-pane layout only to a newly created `Work` session; subsequent launches attach without altering panes or commands.
