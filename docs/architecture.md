# Macoma control plane

Macoma brings selected Omarchy workflows to existing macOS installations. The app coordinates native tools through small modules; macOS continues to own login, security, displays, Spaces and the system screensaver host.

`Sources/App` owns the SwiftUI scene, navigation and selected palette. Each module owns its controls, operations, configuration and tests. The sidebar provides Overview, Appearance, Terminal, Windows and Screensavers. Navigation uses native SwiftUI containers and follows the system appearance, including Liquid Glass on macOS 26.

## Module boundaries

| Module | Runtime and state | Changes on explicit action |
| --- | --- | --- |
| Appearance | Codable catalogs, bounded image cache, AppKit desktop API, persistent recovery journal | Downloads/imports images; applies and restores connected-display wallpapers |
| Terminal | Versioned profiles under `~/.config/macarchy/terminal`, Ghostty CLI, dedicated tmux server | Validates and activates a profile, launches native Ghostty, restores the previous profile |
| Windows | Pure scrolling model, public AX/CG discovery, Carbon shortcuts, AppKit border overlay | Moves/resizes supported windows after Enable; restores remembered frames on Pause/quit |
| Screensavers | SwiftUI companion, Swift/Metal grid, Rust engine, independent `ScreenSaverView` extension | Saves artwork/settings and installs the user-level saver |

The selected palette is stored in Macoma preferences. Terminal profile application is explicit. Window border color follows the selected palette. Screensaver effects retain their own animation palettes.

Terminal generations preserve running shell references. Wallpaper restoration persists across app launches. Window geometry restoration is session-only; a process crash loses that receipt. No module changes SIP, authentication, disk partitions, system binaries or existing shell dotfiles.

## Build boundaries

`scripts/build.py` compiles the saver from `Screensavers/Shared` and `Screensavers/Extension`. The app compiles `Sources/App`, each companion module and `Screensavers/Shared`, then embeds the independently signed saver. Desktop catalogs and terminal templates belong only to the app bundle. The saver cannot start the window manager or terminal services.

The Rust workspace remains under `crates/omacy-engine`. `vendor/ttfx` is a pinned native-bridge submodule. Moving Swift files does not change that dependency or the 40 effect implementations. The build uses fresh staging bundles and preserves the previous successful artifacts.

## Qualification

Module tests exercise operations, failure recovery and external tool integration. Packaged native host tests load the actual saver bundle. GUI qualification must separately check the app, permissions and observable desktop behavior; model tests cannot establish Accessibility or multi-display correctness. Evidence records must identify the tested build and keep earlier idle-activation evidence separate.
