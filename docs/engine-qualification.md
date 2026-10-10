# Macarchy engine qualification

Verified locally on 2026-10-11 with macOS 26.5.2 (25F84), Apple Silicon arm64,
and Rust 1.98.1. The native packed-cell catalog contains all 37 upstream effects
plus three Macarchy originals: `aurora`, `starfield`, and `circuit`.

The engine uses the `vendor/ttfx` submodule from
[`theboringhumane/ttfx`](https://github.com/theboringhumane/ttfx), pinned at
[`5e19b78b263e067492b07a044c789d63ece5176d`](https://github.com/theboringhumane/ttfx/commit/5e19b78b263e067492b07a044c789d63ece5176d).
That native bridge fork retains upstream v0.3.2 at
`7203e354498462064b7c0a89375051f65cf2ce99` and the existing Omacy bridge patch.
The imported Omacy bridge is pinned at
`45379ab3257f5dd1e9cf4678f96c70ef1ac946bd`. Exact upstream and submodule pins are
recorded in [`vendor/ttfx.PIN`](../vendor/ttfx.PIN); the original patch remains in
[`vendor/patches/ttfx-omacy.patch`](../vendor/patches/ttfx-omacy.patch).
The earlier [fresh-checkout qualification](evidence/ttfx-submodule-2026-10-11.json)
records the submodule's equivalence to the previous vendor snapshot. The three
new effects live in `crates/omacy-engine/src/custom_effects/`; they do not modify
the pinned submodule or its upstream effect implementations.

Run from the repository root:

```sh
CARGO_BUILD_JOBS=2 ./scripts/test-engine.sh
```

This run used two Cargo build jobs. The script defaults to four jobs when the
environment does not specify a limit and shares the repository `target/`
directory. It writes detailed results to `target/qualification/`.

| Check | Result |
| --- | --- |
| Rust engine suite | 74 passed, 0 failed; 35.46 seconds |
| Complete catalog with virtual 60 Hz clock | 40/40 effects; 25,738 frames |
| Seeded random playback | 40 complete cycles; 39 artwork, pool, and geometry changes; 28,010 frames |
| Original-effect acceptance | 9 tests passed for all three originals |
| Upstream packed-cell / ANSI parity | Unchanged 37-effect oracle matrix passed |
| Production C ABI, process main thread | 40/40 effects completed; 40 subsequent configuration transitions completed; 23,446 frames |
| Original and upstream pools through the C ABI | 8 complete cycles; 7 configuration transitions |
| Public effect catalog | All 40 names in order; stable string pointers; out-of-range outputs cleared |
| C ABI layouts and process-main-thread lifecycle | Passed |
| Previous published C declaration compatibility | Passed |
| C++ header layout and declarations | Passed |

Every complete catalog lifecycle check requires a changing grid, visible text, valid glyphs,
valid cell flags, and a retained final frame. Each cycle has a 40,000-frame limit
and a 45-second host-time limit. The C harness uses the shipped real clock.
Matrix and Thunderstorm run with timed frame intervals because they read wall
time; this run completed them in 25.766 and 16.920 seconds respectively. Other
effects run as quickly as possible. These timings are completion evidence, not
rendering performance measurements.

The C harness changes the effect, artwork, and grid size after every catalog
cycle. Its additional pool test forces each original and `wipe`, then mixes
original and upstream effects. The Rust random test alternates the full
40-effect catalog and a selected four-effect pool, changes artwork, and
alternates 48×16 and 80×24 grids.

The nine original-effect tests require visible changing native cells, completion
within 1,800 virtual frames, and a stable final-art hold of at least 30 frames.
They check exact final ASCII and Unicode glyph positions without stray particles,
same-seed repeatability, different-seed variation, 1×1 and narrow canvases,
graceful blank-art rejection, singleton and mixed random pools, and artwork and
geometry changes across generations. The real C ABI completed `aurora` in 511
steps, `starfield` in 481, and `circuit` in 541, including each terminating step.

The inherited ANSI parity oracle remains restricted to the **37 upstream
effects**. It compares their packed cells with decoded ANSI output for both
artwork fixtures and 80×24 / 160×48 canvases. The three originals are qualified
through their native-cell and session behavior; this document does not claim
an upstream ANSI oracle for them. Existing tests also check image conversion
fixtures and input limits, and verify that failed configuration changes leave
the previous state intact.

## Why both Rust and C tests run

The session C API requires the process main thread. Rust's standard test runner
uses worker threads, and several inherited FFI tests return early on those
threads. Their `ok` labels do not establish main-thread session coverage. The
separately compiled C executables run on the process main thread and exercise
the actual exported functions against `libomacy_engine.a`.

The inherited Omacy `.appex` thumbnail test was removed from test registration:
it targets assets under `apps/Omacy/OmacyScreensaver/Assets.xcassets`, which this
native `.saver` project does not ship. Its source remains in the imported test
directory. Macarchy application-resource packaging is checked by its own build
workflow.

## Native bridge artifacts

- C header: `crates/omacy-engine/include/omacy.h`
- Development static library: `target/debug/libomacy_engine.a` (verified arm64)
- Release static library after the application build: `target/release/libomacy_engine.a`
- Repeatable native lifecycle executable: `target/qualification/catalog_lifecycle`
- Rust result log: `target/qualification/rust-tests.log`
- Native lifecycle log: `target/qualification/catalog_lifecycle.log`

## Verification boundary

This establishes engine and native-ABI behavior in the development build. It
does not establish Metal drawing performance, macOS idle activation, System
Settings selection, lock-screen behavior, multiple displays, or sleep/wake.
Those require verification of the built application and screen saver on macOS.
