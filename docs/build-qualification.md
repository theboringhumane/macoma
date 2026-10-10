# Macarchy build qualification

Local development release 0.1.0, build 3. Target: Apple Silicon, macOS 15+. Qualification machine: arm64, macOS 26.5.2, Xcode 26.6 / Swift 6.3.3, Swift 5 language mode.

The companion and native `.saver` are built and installed for the current user. The app exposes all 37 effects, rotation selection, custom artwork, PNG/SVG conversion, appearance settings, live preview and a system screensaver installer. On macOS 26, the interface uses native SwiftUI Liquid Glass controls, toolbar, sidebar and inspector rather than a custom dashboard shell.

## Checks completed

| Area | Evidence |
| --- | --- |
| Rust engine and native bridge | 65 Rust tests passed. All 37 effects ran to completion through the production C ABI on the macOS main thread, followed by 37 content/effect/geometry transitions. |
| Repeated rotation | 40 seeded random cycles with 39 artwork/pool/geometry changes passed. |
| Input and ABI | PNG/SVG conversion, input budgets, error paths, wrong-thread rejection, C/C++ layout and prior declaration compatibility passed. |
| Packaged saver loading | The compiled `.saver` loads through `NSBundle` and `NSPrincipalClass = MacarchySaverView`. |
| Native preview | Real engine frames rendered into AppKit snapshots; distinct frames verified and a resulting image visually inspected. |
| Metal host | A visible full-display test presented 367 callbacks in the build 2 check, with engine active and shared display synchronization disabled. |
| Lifecycle | Stop, restart, resize while stopped, detach, reattach, simulated display sleep/wake and deallocation passed. No rendering continued after explicit stop. |
| macOS integration | System Settings showed `SelectedScreenSaver: Macarchy` in Custom mode. Apple's `legacyScreenSaver` loaded the installed build 2 executable; its mapped inode matched the installed bundle. |
| Automatic idle activation | On 2026-10-10 at 23:55:20 IST, `loginwindow` measured 60 seconds of inactivity and entered `kLWLockFromScreenSaverIdleLaunch (3)`. WallpaperAgent then initialized Macarchy, and its native host started animation with the installed build 3 executable. The mapped file identity and SHA-256 matched the current artifact. This was an automatic idle launch, with no preview command. The user confirmed that animated artwork appeared. No Macarchy errors or display-barrier warnings were logged during the following 94.6 seconds of observation. |
| Native interface | Installed build 3 was visually inspected with the standard sidebar, title bar, inspector and artwork sheet. The live preview and full-screen window were observed. Glass APIs are gated to macOS 26, with native macOS 15 fallbacks. |
| Packaging | Build 3 app, saver, embedded saver and installed bundles pass `codesign --verify --deep --strict`. Installed and ZIP executable hashes match the current build; bundle source fingerprints match the current `Sources/` tree. The app embeds the saver, font, artwork, shader source and license notices. |

See [engine qualification](engine-qualification.md), [current build 3 evidence](evidence/build-0.1.0-3.json), [automatic idle evidence](evidence/idle-activation-0.1.0-3.json), and [build 2 host evidence](evidence/build-0.1.0-2.json). Native host snapshots and detailed reports are retained under `build/evidence/`; the engine runner retains its logs under `target/qualification/`.

Build 3 changes the companion interface. The engine and saver implementation are unchanged from build 2. The scripted native saver lifecycle checks were collected on build 2 and were not rerun for this interface update. Build 3 has its own packaging, installed-identity, visual interface and actual automatic idle-launch checks.

Before the idle check, macOS still had a host mapping an earlier build from the installer's backup directory. That exact stale host was terminated after verifying its mapped module; WallpaperAgent created a replacement using build 3. Settings previews use a separate host, so reopening Settings alone did not refresh the active wallpaper host. Neither the idle interval nor the display-sleep or password settings were changed during this validation. Computer-use automation was paused during the idle wait because its display-sleep assertion otherwise suppresses automatic screensaver launch.

## Fix found in the real macOS host

The initial build inherited a shared display barrier from Omacy. Apple's host can create preview, retired and full-size contexts in the same process. A stalled participant advanced the shared cycle while another engine was still running, and the bridge correctly rejected an early `beginNext` call.

The shipping saver runs independent loops per view. Shared renderer catch-up also recreates an active session instead of attempting an illegal boundary transition. Build 2's packaged host tests assert that display synchronization is disabled. The new installed binary loaded in a fresh Apple host process; no Macarchy errors were found in the captured logs for that process. This is a bounded observation, not a long-duration soak test.

Other integration fixes include bundle-relative resource loading inside Apple's host, cached runtime Metal shader compilation, a preferences fallback that preserves readable public configuration, rollback error reporting, fresh build staging, and the macOS 26 Wallpaper settings shortcut.

## Scope of remaining qualification

- Automatic inactivity-triggered activation passed on the qualification machine with a 1-minute screensaver interval and 10-minute display-sleep interval. This bounded run does not establish long-duration reliability.
- Physical multiple-monitor and sleep/wake testing remain open; simulated lifecycle notifications passed.
- macOS 15 hardware has not been tested.
- The app is a local ad-hoc signed build. Public Developer ID signing and notarization have not been performed.

The `.saver` uses Apple's documented ScreenSaver framework, rather than an extension with private ScreenSaver class declarations. macOS owns authentication and locking.
