# Macarchy

A native macOS companion that brings Omarchy's terminal-art screensavers to the Mac. The first release includes all 37 effects, a live preview, custom artwork, and a real `ScreenSaverView` system screensaver.

Apple Silicon · macOS 15 or later · SwiftUI, Metal and Rust

On macOS 26, the app follows native Liquid Glass styling with a system sidebar, toolbar and inspector. Earlier supported macOS versions use standard native controls. The app follows the system appearance.

## Use the local build

Open `build/Macarchy.app`. Select an effect to preview it. Check the effects you want in the random rotation, or choose **Use Only [effect]** in the inspector to repeat the selected effect. **Edit Artwork…** accepts text, PNG and SVG files. **Apply Changes** saves your artwork and settings.

Choose **Install Screensaver**, then select **Macarchy** in System Settings → Wallpaper → Screen Saver on macOS 26, or System Settings → Screen Saver on macOS 15. The installer writes only to your user's `Library/Screen Savers` folder and preserves an existing Macarchy bundle in `Library/Application Support/Macarchy/Backups`. It does not change the system's password or lock-screen policy. Use the **Screensaver → Install Screensaver…** menu to replace an installed version after rebuilding.

Choose **Full Screen** in the controls below the preview or use the **Screensaver** menu. The full-screen preview exits on any key or click. It previews the selected effect; your system screensaver uses the saved rotation.

## Build

Requires Xcode 26 with the macOS 26 SDK, Python 3, and Rust/Cargo. Swift sources use Swift 5 language mode on the current Swift toolchain. Liquid Glass APIs are availability-gated so the built app also runs on macOS 15. No package-manager installation or third-party updater is required.

```sh
python3 scripts/build.py
open build/Macarchy.app
```

The build produces self-contained `build/Macarchy.app` and `build/Macarchy.saver` bundles. The app embeds the saver. Metal shaders are compiled by the system at runtime and cached in the process, so the optional Xcode Metal command-line toolchain is not required.

Local builds are ad-hoc signed by default. Set `MACARCHY_SIGN_IDENTITY` to an installed identity to sign with that identity. This repository does not claim notarized public distribution. Both artifacts target arm64 and declare macOS 15 as the minimum; current runtime qualification is on macOS 26.5.2.

To install both bundles for the current user:

```sh
python3 scripts/install.py
open ~/Applications/Macarchy.app
```

After Swift-only changes, `python3 scripts/build.py --skip-engine` reuses the existing Rust release library. Builds use fresh staging bundles and retain the immediately preceding successful artifacts as `.previous` directories.

## Configuration

The companion writes `~/.config/macarchy/settings.json` and `~/.config/macarchy/screensaver.txt`. The saver reloads them at effect boundaries. Malformed input falls back to the last valid configuration. A copy saved through Apple's `ScreenSaverDefaults` API is available to hosts that cannot read the public files.

Text art supports UTF-8 block and Braille characters, up to 256 columns, 128 lines and 64 KiB. PNG/SVG import converts to an 80×26 grid with block/Braille, threshold and invert controls. The app supports a saved background color and text size. Effects use the original per-effect color palettes.

The engine steps at 60 Hz, and app previews present at 30 FPS. The display link controls full-screen presentation. This follows the native bridge's timing policy; it does not claim identical duration or pixels to Omarchy's 120 FPS terminal loop.

Each display rotates independently. macOS can create several preview and full-screen contexts in one host process; those contexts never wait on a shared display barrier.

## Verification

```sh
./scripts/test-engine.sh
Tests/SaverHost/run.sh --bundle build/Macarchy.saver --output build/evidence/saver-host
```

The engine suite exercises all 37 effects to completion through the native grid and actual main-thread C ABI, repeated random transitions, conversion, errors and ABI compatibility. The saver harness loads the packaged `NSPrincipalClass`, captures moving previews, and verifies stop, resize, detach, sleep/wake notifications and deallocation. Add `--visible` to the saver harness for its brief visible Metal host check.

Automatic idle activation was also verified on macOS 26.5.2: after 60 seconds of inactivity, macOS launched the installed build 3 through its system screensaver host. See [engine qualification](docs/engine-qualification.md), [build qualification](docs/build-qualification.md), and the earlier [portability audit](docs/screensaver-audit.md) for evidence and limits. Physical external-monitor behavior remains unqualified.

## Source layout

- `Sources/App`: native companion, artwork editor and full-screen preview.
- `Sources/ScreenSaver`: documented `ScreenSaverView` host, CPU preview and configure sheet.
- `Sources/Shared`: reusable engine bridge, Metal cell renderer and validated configuration.
- `Sources/Integration`: user-level saver installation.
- `crates/omacy-engine`: Rust bridge, conversion and engine tests.
- `vendor/ttfx`: pinned v0.3.2 engine with the existing native bridge patch.
- `Resources`: original Macarchy artwork/icon and licensed Fairfax HD font.

Window-management presets and coordinated terminal themes are planned as later modules; this release delivers screensavers.

## Credits

Macarchy adapts the MIT-licensed native engine bridge and renderer from [Omacy](https://github.com/dedene/omacy), pinned at `45379ab`. The animation designs originate in [TerminalTextEffects](https://github.com/ChrisBuilds/terminaltexteffects) by ChrisBuilds, via [ttfx](https://github.com/omacom/ttfx). The font is Fairfax HD under SIL OFL. See [NOTICE](NOTICE), [LICENSE](LICENSE) and `ThirdParty/Omacy` for preserved attribution.

This is an independent project with its own branding. It is not an official Omarchy or Omacy distribution.
