# Macoma control-plane qualification

Local development release **0.3.2, build 8**, verified on 2026-10-11. Target: Apple Silicon, macOS 15+. Qualification machine: arm64, macOS 26.5.2, Xcode 26.6 / Swift 6.3.3, Swift 5 language mode. Build 7 contains the screensaver resize fix described below; build 6 qualification remains historical evidence later in this report.

## Build 8 distribution packaging

Build 8 adds release automation for an arm64 DMG and its SHA-256 manifest, plus a current-user installer script. The workflow builds on an Apple Silicon macOS runner and attaches both assets to the tagged GitHub release. The app and saver remain ad-hoc signed until a Developer ID identity and notarization credentials are configured. A self-signed certificate is not a trusted distribution identity.

## Build 7 screensaver resize qualification

The packaged saver passed the preview and visible Metal host harness. In a full-size host window, the test resized the saver view from 1800×1169 to 480×320 and back. The Metal backend stayed active; the engine grid changed from 200×64 to 53×17 and returned to 200×64. The harness also passed start/stop, restart, detach/reattach, simulated display sleep/wake and release checks. It did not install the saver or change system settings.

The fix checks both the saver view and its host window before treating an unmarked view as a Settings thumbnail. This avoids switching a temporarily small saver view in a full-screen host to software preview mode. The system screensaver display link is capped at 30 FPS. This host check does not qualify automatic idle activation, physical multi-display transitions, long-duration stability or RAM use.

The control plane provides native SwiftUI navigation and a menu-bar menu for Appearance, Terminal, experimental Windows and Screensavers. Build 6 adds Command-T panes and the revised drag/resize handling. The user confirmed that Accessibility was allowed, dragging and resizing felt smooth, and Command-T created a new pane in a fresh Work session.

## Built and installed identity

The built app, built saver, embedded saver, installed app and installed saver all pass `codesign --verify --deep --strict`. Installed app content matches the built app; standalone, embedded and installed saver content also matches. The default MACOMA artwork is identical in all five bundles. The qualified bundles were copied into the main checkout without rebuilding.

| Identity | Value |
| --- | --- |
| Source fingerprint | `c6d93107d1cc9040e8899b0304b061c37e55e2bf74f595badcc89ff81c43f890` |
| App executable SHA-256 | `215639f83c30983420b2e864ac7409cf45ab0afb59b84955a225309fa6dc792e` |
| Saver executable SHA-256 | `46d49588ac261b442cf7e3f5f7e7d7989ea9a47b7882efbef5691106909be99d` |

The source fingerprint was recomputed from the source files, resources, engine crate, lock/pin/notice files and engine archive digest, and matches every packaged plist. Macoma retains its earlier bundle identifiers, executable name and installed saver location for compatibility. Full bundle hashes, code-directory hashes, plists and log digests are in [build 6 evidence](evidence/build-0.3.0-6.json).

## Module and runtime evidence

| Area | Evidence |
| --- | --- |
| Appearance | 21 checks pass: 23 canonical palettes, 96 pinned wallpaper records, rollback/recovery, external-change guards, pinned image verification, bounded decode and cache reuse. The tests made no live desktop writes. |
| Terminal | Six qualification groups pass with Ghostty 1.3.1 and tmux 3.5a: both managed profiles, Command-T adaptive splits in wide/tall panes, three-pane Work geometry, top status bar, running-process preservation, apply/restore for future-pane environments, zsh startup forwarding, timeouts and output limits. |
| Windows | 3,072 pure layout/identity/preparation assertions pass without Accessibility access or live window changes. The user separately confirmed smooth drag/resize on installed build 6. |
| Packaged saver host | Software preview produced 145 callbacks and 41 distinct frame signatures. The full-size Metal host produced 365 callbacks with an active engine. Shared display synchronization was disabled. Stop/restart, resize while stopped, detach/reattach, simulated display sleep/wake and release were exercised. System settings were not changed. |
| Interactive terminal | The user confirmed that Command-T creates a new pane in a fresh build-6 Work session. The earlier Work layout check showed one full-width upper pane and two lower panes. |
| Wallpaper runtime | On one display, a pinned wallpaper applied through the UI and AppKit readback returned the managed JPEG. Restore remained available after navigation, and the user confirmed the original wallpaper returned. This earlier workflow check is separate from the final bundle identity checks. |
| Gallery | Updated MACOMA previews were regenerated from the existing release engine: Aurora 129 frames / 8.52 s, Starfield 121 / 8.02 s, Circuit 136 / 9.02 s; all 672×384. Raw final grids and decoded final GIFs match the source artwork exactly: 88 glyph cells and zero colored pixels in expected empty cells. An Aurora animation sample and magnified final frame were visually inspected. |

The captured window log covers **83.546 seconds** with two managed windows. It contains four layout passes taking 17.924, 4.627, 4.680 and 3.414 ms, each using one public CG snapshot. Across those passes it records two exact frame writes, six application-clamped writes and zero failed writes. Three completed native gesture gates recorded seven deferred reads and zero deferred writes; a fourth gate was active when capture ended. These are bounded layout-pass observations, not an input-latency or display-frame-rate benchmark.

The GUI automation connection disconnected during the interactive sequence. User confirmations are recorded separately from automated tests. Build 5's earlier Enable, horizontal navigation and Pause/restore confirmation remains a basic historical workflow check; the build-6 smoothness confirmation supersedes the previously pending drag/resize note.

The engine dependency and Rust effect code are unchanged from build 4. The existing release archive was reused for the build and gallery exports; unchanged test suites were not rerun solely for this evidence update. Earlier engine and automatic-idle results below retain their original build identity.

## Limits

Window management is experimental and qualified for a bounded basic workflow on one display and the current native Space. Overflow uses public window placement and can leave visible edges or be clamped by applications. Hidden or other-Space windows wait for restoration until visible. A process crash loses the in-memory geometry receipt. Stacking, repeated create/close cycles, native Space transitions, permission revocation and the full application compatibility matrix remain unqualified.

Multi-display scrolling, native Space manipulation, compositor clipping, macOS 15 hardware, wallpaper multi-Space behavior and dynamic schedules remain unqualified. Physical multiple-display and sleep/wake checks and long-duration soak testing have not been completed for build 6. Its packaged-host test does not establish automatic inactivity-triggered activation; the historical automatic-idle result belongs to build 3. Builds are ad-hoc signed, without Developer ID signing or notarization.

Existing Ghostty windows retain their launch profile. The current pane shortcuts require an applied revision-2 profile and a fresh managed window.

---

# Screensaver build 4 qualification

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
