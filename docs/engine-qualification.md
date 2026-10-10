# Macarchy engine qualification

Verified locally on 2026-10-10 with macOS 26.5.2 (25F84), Apple Silicon arm64,
Rust 1.98.1, and the imported Omacy engine at
`45379ab3257f5dd1e9cf4678f96c70ef1ac946bd`. The vendored `ttfx` package reports
version 0.3.2. These checks use the native packed-cell rendering path.

Run from the repository root:

```sh
./scripts/test-engine.sh
```

The script limits Cargo to four build jobs by default and shares the repository
`target/` directory. It writes detailed results to `target/qualification/`.

| Check | Result |
| --- | --- |
| Rust engine suite | 65 passed, 0 failed; 34.49 seconds |
| Complete catalog with virtual 60 Hz clock | 37/37 effects; 24,205 frames |
| Seeded random playback | 40 complete cycles; 39 artwork, pool, and geometry changes; 27,872 frames |
| Production C ABI, process main thread | 37/37 effects completed; 37 subsequent configuration transitions completed; 21,530 frames |
| C layout, lifecycle, error and wrong-thread contract | Passed |
| Previous published C declaration compatibility | Passed |
| C++ header layout and declarations | Passed |

Every new lifecycle check requires a changing grid, visible text, valid glyphs,
valid cell flags, and a retained final frame. Each cycle has a 40,000-frame limit
and a 45-second host-time limit. The C harness uses the shipped real clock.
Matrix and Thunderstorm run with timed frame intervals because they read wall
time; this run completed them in 26.395 and 17.112 seconds respectively. Other
effects run as quickly as possible. These timings are completion evidence, not
rendering performance measurements.

The C harness changes the effect, artwork, and grid size after every catalog
cycle. The random test alternates the full catalog and a selected four-effect
pool, changes artwork, and alternates 48×16 and 80×24 grids. Existing tests also
compare packed cells to decoded ANSI output for every effect, both artwork
fixtures, and 80×24 / 160×48 canvases; check image conversion fixtures and input
limits; and verify failed configuration changes leave the previous state intact.

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
