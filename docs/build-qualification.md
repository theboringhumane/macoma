# Macarchy build qualification

Local development release **0.2.0, build 4**, verified on 2026-10-11. Target: Apple Silicon, macOS 15+. Qualification machine: arm64, macOS 26.5.2, Xcode 26.6 / Swift 6.3.3, Swift 5 language mode.

The built and installed companion and native `.saver` include 40 effects: all 37 ttfx effects plus Aurora, Starfield and Circuit. The app separates Macarchy Originals from ttfx in its native sidebar, with descriptions and attribution. The macOS 26 Liquid Glass interface, artwork editor and saved configuration remain available.

## Current checks

| Area | Evidence |
| --- | --- |
| Engine and C ABI | 74 Rust tests passed. All 40 effects completed through the native cell grid and actual process-main-thread C ABI, followed by 40 configuration transitions. The unchanged 37-effect ANSI parity matrix passed. |
| Original effects | Nine acceptance tests cover seeded variation and repeatability, exact final artwork, Unicode, narrow canvases, finite completion and mixed pools. The native C harness also completed eight original/upstream pool cycles. |
| Native saver loading | The packaged `.saver` loads through `NSBundle` with `NSPrincipalClass = MacarchySaverView`. |
| AppKit preview | 145 software callbacks produced 39 distinct frame signatures in the packaged host check. |
| Metal host | The visible full-display host check presented 368 callbacks with an active engine and shared display synchronization disabled. |
| Lifecycle | Stop, restart, resize while stopped, detach, reattach, simulated display sleep/wake and deallocation passed. Callbacks stopped after explicit stop. |
| Companion interface | Installed build 4 exposed all 40 effects and the Originals section. Starfield and Circuit rendered live motion and the existing custom artwork. The original saved pool was preserved on first launch; the user subsequently included and saved all 40 effects. |
| GIF previews | The three original GIFs were exported from the production release C ABI with Fairfax HD. Frame counts, durations and final artwork pixels were checked. All 37 pinned upstream GIF URLs returned HTTP 200 with `image/gif`. |
| Packaging and installation | Built app, saver, embedded saver and installed bundles pass strict code-signature verification. Installed and ZIP executable hashes match the build. Source fingerprints and packaged license files were verified. |

See [build 4 evidence](evidence/build-0.2.0-4.json), [engine qualification](engine-qualification.md) and [preview manifest](effects/manifest.json). Detailed engine logs remain under `target/qualification/`; native host reports and snapshots remain under `build/evidence/`.

The host harness exercises the packaged saver in a controlled process. It does not establish automatic inactivity-triggered activation for build 4. No system password, display-sleep or screensaver idle policies were changed.

## Earlier system-host evidence

Build 3 passed an actual automatic idle launch on 2026-10-10 at 23:55:20 IST. `loginwindow` measured 60 seconds of inactivity and entered `kLWLockFromScreenSaverIdleLaunch (3)`. WallpaperAgent initialized Macarchy and Apple's host started the installed build 3 executable. The mapped file identity and SHA-256 matched that artifact; the user confirmed that animated artwork appeared. No Macarchy errors or display-barrier warnings appeared in the following 94.6 seconds.

This remains historical build 3 evidence: [automatic idle check](evidence/idle-activation-0.1.0-3.json), [build 3 packaging and interface](evidence/build-0.1.0-3.json), and [build 2 native-host checks](evidence/build-0.1.0-2.json). It has not been relabeled as build 4 qualification.

Before that check, an Apple host still mapped an earlier executable from the installer's backup directory. The exact stale host was terminated after verifying its mapped module, and WallpaperAgent created a replacement. Settings previews use a separate host, so reopening Settings alone did not refresh the active wallpaper host. Computer-use automation was paused during the idle wait because its display-sleep assertion suppresses automatic launch.

## Fix found in the real macOS host

The initial build inherited a shared display barrier from Omacy. Apple's host can create preview, retired and full-size contexts in the same process. A stalled participant advanced the shared cycle while another engine was still running, and the bridge correctly rejected an early `beginNext` call.

The shipping saver runs independent loops per view. Shared renderer catch-up also recreates an active session instead of attempting an illegal boundary transition. Build 2's packaged host tests assert that display synchronization is disabled. The new installed binary loaded in a fresh Apple host process; no Macarchy errors were found in the captured logs for that process. This is a bounded observation, not a long-duration soak test.

Other integration fixes include bundle-relative resource loading inside Apple's host, cached runtime Metal shader compilation, a preferences fallback that preserves readable public configuration, rollback error reporting, fresh build staging, and the macOS 26 Wallpaper settings shortcut.

## Scope of remaining qualification

- Automatic inactivity-triggered activation has not been repeated for build 4. The earlier one-minute idle check passed on build 3; neither run establishes long-duration reliability.
- Physical multiple-monitor and sleep/wake testing remain open; simulated lifecycle notifications passed.
- macOS 15 hardware has not been tested.
- The app is an ad-hoc signed local build. Developer ID signing and notarization have not been performed.

The `.saver` uses Apple's documented ScreenSaver framework. macOS owns authentication and locking.
