# Omarchy on an existing Mac

This implementation uses Omarchy source at [`77bfaca`](https://github.com/omacom/omarchy/tree/77bfaca408d2993018d928e72cf84561480e5188), the `quattro` development branch inspected on 2026-10-11. The latest published release found during research was v4.0.4; this source pin is not that release.

The visual reference is DHH's [Omarchy Quattro preview](https://www.youtube.com/watch?v=F7fe9pa8OeE): the tmux layout around 8:27 and scrolling desktop around 22:30. Those sections and user-supplied frames informed the implementation; the entire video was not reviewed.

| Omarchy experience | Macoma mapping | Boundary |
| --- | --- | --- |
| Terminal | Native Ghostty, managed theme and shell startup wrapper | Current default Foot is Wayland-specific; no Foot port is claimed |
| Work panes | Separate tmux server, upper pane plus two lower panes, top status bar | Existing Work panes survive relaunch |
| Scrolling columns | Native AX window placement with gaps, stacks and focus border | One display/current Space, visible overflow edges; no compositor clipping |
| Coordinated themes | 23 resolved ANSI palettes with canonical cursor/selection colors | Terminal Apply is explicit; applications need their own future adapters |
| Backgrounds | 96 pinned wallpaper catalog entries and local import | Image bytes downloaded on demand; no blanket redistribution claim |
| Terminal-art idle screen | 37 ttfx effects plus 3 Macoma originals in a native saver | Engine timing/font metrics can differ from Linux terminal output |

Sources: [terminal manual](https://github.com/omacom/omarchy/blob/77bfaca408d2993018d928e72cf84561480e5188/manual/15-terminal.md), [tmux configuration](https://github.com/omacom/omarchy/blob/77bfaca408d2993018d928e72cf84561480e5188/config/tmux/tmux.conf), [window appearance](https://github.com/omacom/omarchy/blob/77bfaca408d2993018d928e72cf84561480e5188/default/hypr/looknfeel.lua), [theme resolver](https://github.com/omacom/omarchy/blob/77bfaca408d2993018d928e72cf84561480e5188/bin/omarchy-theme-color).

## Future candidates

Apple Terminal is a candidate for a second terminal adapter. Its installed scripting dictionary exposes profiles, fonts, colors and per-tab settings, so it can host the same tmux Work session with a separate Macoma profile. Independent shell panes would come from tmux. Command-T currently belongs to Terminal's New Tab action; matching Ghostty's pane shortcut needs a scoped shortcut implementation and native qualification. Apple Terminal support is not included in v0.3.0.

Neovim profiles, coordinated editor themes, an app/command launcher, and optional shell tools such as Starship, eza, fzf and zoxide fit the same model: separate managed configuration with explicit setup and restoration. A future adapter can discover each installed application and report what a theme application changes before writing it.

Hyprland, Waybar, Linux lock/login screens, system services and package management depend on the Linux desktop stack. They need native equivalents or should stay outside Macoma's scope. Exact foreign-window corner rounding and dimming cannot be promised through public macOS APIs. Multi-display scrolling needs its own design and real display qualification before support can be claimed.
