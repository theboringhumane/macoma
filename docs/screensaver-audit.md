# Omarchy screensavers on macOS

Audited 10 October 2026, before implementation. The native app and screensaver have since been built; see [build qualification](build-qualification.md) for current delivery status.

All 37 effects in the inspected Omarchy animation engine are feasible to bring to macOS. The engine already runs on macOS, and Omacy already contains a native renderer and bridge for the same effect catalog. The main remaining engineering work is reliable macOS screensaver integration and a coherent configuration experience.

An Omarchy-inspired macOS companion is a useful project boundary: start with screensavers, then coordinate window-management presets and terminal themes through the same app. Each module should work independently.

## Sources and versions

| Component | Inspected version | Purpose |
| --- | --- | --- |
| Omarchy latest published release | [v4.0.4, `c668141`](https://github.com/omacom/omarchy/tree/c668141e9c42b13c80c9ca4ea108e11708c5e8a5) | Released screensaver behavior |
| Omarchy default branch | [quattro, `77bfaca`](https://github.com/omacom/omarchy/tree/77bfaca408d2993018d928e72cf84561480e5188) | Check current development behavior |
| ttfx | [v0.5.0 source, `921bd55`](https://github.com/omacom/ttfx/tree/921bd551c308c235e01c5867f0199efe0691c271) | Effect catalog and local macOS build |
| Omacy | [`45379ab`](https://github.com/dedene/omacy/tree/45379ab3257f5dd1e9cf4678f96c70ef1ac946bd) | Native bridge, renderer, host and integration limitations |
| Omacy published artifact | [v0.1.5, `23ac65a`](https://github.com/dedene/omacy/releases/tag/v0.1.5) | Release packaging and signature inspection |

Omarchy installs a `ttfx` package rather than vendoring its engine in the screensaver script. The 37-effect count refers to the inspected ttfx version; the exact package installed on another Omarchy machine can differ.

## What Omarchy actually runs

The [released screensaver script](https://github.com/omacom/omarchy/blob/c668141e9c42b13c80c9ca4ea108e11708c5e8a5/bin/omarchy-screensaver#L38-L49) repeatedly runs `ttfx --random-effect` against a text-art file. It centers the art on a black canvas and requests 120 FPS. It supplies no effect exclusions. The current default branch uses the same invocation.

The [launcher](https://github.com/omacom/omarchy/blob/77bfaca408d2993018d928e72cf84561480e5188/bin/omarchy-launch-screensaver) opens a supported terminal per monitor and uses Hyprland to manage focus and workspaces. That Linux integration needs replacement on macOS. The animation algorithms do not.

The [branding command](https://github.com/omacom/omarchy/blob/77bfaca408d2993018d928e72cf84561480e5188/bin/omarchy-branding-screensaver) supports edited text, PNG/SVG import, and resetting to the wordmark. Its [image converter](https://github.com/omacom/omarchy/blob/77bfaca408d2993018d928e72cf84561480e5188/bin/omarchy-transcode-ascii) produces block or Braille art with ImageMagick and awk.

These are 37 animations in one engine, rather than 37 independent screensaver applications.

## Complete effect inventory

The following grouping is for readability; it is not an upstream category system. Every name is present in both the inspected ttfx and Omacy registries, and every effect passed the bounded local engine check described below.

| Group | Effects | Count |
| --- | --- | ---: |
| Digital and text | `matrix`, `decrypt`, `binarypath`, `errorcorrect`, `vhstape`, `print`, `overflow` | 7 |
| Particles and orbits | `blackhole`, `bouncyballs`, `bubbles`, `fireworks`, `swarm`, `orbittingvolley` | 6 |
| Weather and flow | `burn`, `smoke`, `thunderstorm`, `rain`, `pour` | 5 |
| Light and color | `beams`, `laseretch`, `highlight`, `spotlights`, `colorshift`, `synthgrid`, `waves` | 7 |
| Movement and assembly | `expand`, `middleout`, `scattered`, `slice`, `slide`, `rings`, `crumble`, `unstable` | 8 |
| Reveals | `wipe`, `sweep`, `spray`, `randomsequence` | 4 |
| Total | | **37** |

See the [upstream animated gallery](https://github.com/omacom/ttfx/blob/921bd551c308c235e01c5867f0199efe0691c271/README.md#the-effects) and [effect registry](https://github.com/omacom/ttfx/blob/921bd551c308c235e01c5867f0199efe0691c271/src/effects/mod.rs).

## What was tested here

Built the pinned ttfx source with `cargo build --release --locked` on Apple Silicon, macOS 26.5.2, using Rust 1.98.1. Build succeeded with three upstream unused-code warnings.

Executed each of the 37 effects with the released Omarchy wordmark, default effect settings, a centered 100×30 canvas, seed 42, and a virtual 120 FPS clock. Each run stopped after 240 frames or natural completion, whichever came first. The check validated frame lengths, UTF-8 decoding, nonblank content, changing frames, frame-count reporting and successful process exit.

**Result: 37/37 passed.** Per-effect results and the reproduction command are in [ttfx-macos-smoke.json](evidence/ttfx-macos-smoke.json).

This proves bounded native engine execution. It does not establish full-animation correctness, visual parity with Linux, sustained power use, Metal presentation, System Settings discovery, idle activation, or multi-display behavior. Recorded execution times are not a performance benchmark.

The inspected upstream [CI run also succeeded](https://github.com/omacom/ttfx/actions/runs/36426209424). Its workflow includes macOS tests; its byte-exact Python parity checks are explicitly limited to Linux/glibc.

## How much Omacy already solves

Omacy supplies a Rust ttfx engine, C ABI bridge, shared Swift/Metal cell renderer, companion app, effect selection, custom text art and PNG/SVG conversion. Its [native bridge constructs effects from the shared registry](https://github.com/dedene/omacy/blob/45379ab3257f5dd1e9cf4678f96c70ef1ac946bd/crates/omacy-engine/src/session.rs#L577-L610); an empty selection pool enables all 37.

There are several material qualifications to the pasted description:

| Claim | Verified finding |
| --- | --- |
| Companion `.saver` extension | Omacy packages **`.appex`**, with extension point `com.apple.screensaver`. A legacy `.saver` is a different packaging/API route. |
| Identical movement | Same effect designs, but Omacy steps at 60 Hz and Omarchy requests 120 FPS. Omacy explicitly excludes identical wall-clock durations and pixels from its parity claim. |
| Native Mac support | Its current build targets Apple Silicon and declares macOS 15+. Intel support is not supplied by this build. |
| Install and select in Settings | Release packaging is real, but current checked-in docs still mark actual signed-install discovery, idle activation, sandbox access, teardown and multi-display behavior unverified. |
| Current ttfx engine | Omacy vendors ttfx **v0.3.2**, commit `7203e35`, with bridge patches. Updating it to the inspected v0.5.0 requires reconciling those patches and rerunning the bridge checks. |
| Every effect option | All 37 effect names are exposed. That does not mean the app exposes every upstream per-effect CLI parameter. |

Evidence: [architecture](https://github.com/dedene/omacy/blob/45379ab3257f5dd1e9cf4678f96c70ef1ac946bd/docs/architecture.md), [engine pin](https://github.com/dedene/omacy/blob/45379ab3257f5dd1e9cf4678f96c70ef1ac946bd/vendor/ttfx/PIN), [parity limits](https://github.com/dedene/omacy/blob/45379ab3257f5dd1e9cf4678f96c70ef1ac946bd/docs/parity.md), [open macOS gates](https://github.com/dedene/omacy/blob/45379ab3257f5dd1e9cf4678f96c70ef1ac946bd/docs/macos-gates.md).

The v0.1.5 release ZIP was downloaded and inspected without installation or launch. Its SHA-256 matched the GitHub asset digest; deep/strict code-signature verification and stapled notarization validation passed. The app and embedded extension are arm64, version 0.1.5 build 54, minimum macOS 15.0. This establishes artifact signing and packaging, not screensaver runtime behavior.

Omacy's `.appex` uses [undocumented ScreenSaver classes](https://github.com/dedene/omacy/blob/45379ab3257f5dd1e9cf4678f96c70ef1ac946bd/apps/Omacy/OmacyScreensaver/PrivateHeaders/ScreenSaverPrivate.h). Apple's documented [ScreenSaver framework](https://developer.apple.com/documentation/screensaver) exposes `ScreenSaverView` and `.saver` bundles. Keep the renderer separate from its host so we can assess both routes on the macOS versions we support before choosing the shipping integration.

## Recommended first release

Use a SwiftUI companion app with a shared Rust engine and Metal renderer. Evaluate reuse of Omacy's bridge and presentation code before writing equivalents. Give the product its own branding and retain upstream attribution.

1. Prove one effect in the actual system screensaver host: signed installation, System Settings discovery, real idle activation, display painting and clean exit. Preview alone does not complete this milestone.
2. Expose all 37 effects through the shared engine, with single-effect selection and a random pool. Add text-art editing, PNG/SVG import, reset, and preview.
3. Qualify every complete effect, repeated rotation, Retina scaling, external displays, sleep/wake, settings updates, resource cleanup and sustained CPU/GPU use. Decide and document the animation speed policy.
4. Ship the install/update/uninstall path and verify the system's existing password requirement still works. macOS should own authentication and locking; the app supplies the visuals.

Omarchy, ttfx/TTE and Omacy use MIT licenses. Preserve their required copyright notices. Omacy's [trademark policy](https://github.com/dedene/omacy/blob/45379ab3257f5dd1e9cf4678f96c70ef1ac946bd/TRADEMARKS.md) requires separate naming and branding for modified distributions.

## Later project modules

| Module | Practical approach | Boundary |
| --- | --- | --- |
| Window management | Integrate [AeroSpace](https://github.com/nikitabobko/AeroSpace/blob/74a1bf17e82d70e0a21945ba04bb4f590bf19f83/README.md) presets for tiling, workspace navigation and shortcuts. | Its virtual workspaces and macOS Accessibility APIs differ from Hyprland's compositor behavior. |
| Terminal themes | Import Omarchy palettes and generate supported Ghostty, Kitty and Alacritty settings. | Port color data and supported settings; Omarchy's orchestration and some terminal options are Linux-specific. |
| Consistent setup | One selected style can coordinate supported apps, fonts, wallpaper and optional saver colors. | Back up existing user configuration and provide restore. Theme-colored effects would be an added product feature, not established Omarchy saver behavior. |

The inspected Omarchy tree contains 23 theme `colors.toml` files and a reusable [Ghostty palette template](https://github.com/omacom/omarchy/blob/77bfaca408d2993018d928e72cf84561480e5188/default/themed/ghostty.conf.tpl). Its [theme application script](https://github.com/omacom/omarchy/blob/77bfaca408d2993018d928e72cf84561480e5188/bin/omarchy-theme-set) needs macOS-specific adapters.

The linked [Try Omarchy](https://github.com/omacom/try-omarchy/blob/3c6056d1d28c03fb6d51df68c88e12e2a583639d/README.md) is an ARM64 Linux VM using QEMU/HVF. [omarchy-mac](https://github.com/omacom/omarchy-mac/blob/ba546a61f881c1fe9d79d75ec050eab048b8cb63/README.md) describes an Asahi-based M1/M2 installation alongside macOS. Neither is required for this native companion project. The newer [Mac installer candidate](https://github.com/omacom/omarchy-mac-installer/blob/1b66b38b4558bd00342fcd87004a9920c3ab23a9/README.md) explicitly says it is not an installation release; broad claims of released native GPU support across M3/M4/M5 are not established by these sources.
