# Native saver host smoke test

Build the app and saver first, then run:

```sh
Tests/SaverHost/run.sh --bundle build/Macarchy.saver --output build/evidence/saver-host
```

The harness loads the packaged bundle through `NSPrincipalClass`. Hidden AppKit windows exercise the actual `ScreenSaverView`: changing engine frames, snapshot drawing, configuration-sheet construction, start/stop, resize after stop, detach/reattach, display sleep/wake notifications, and release. The output contains two preview PNGs and a JSON report.

For a visible three-second Metal host run:

```sh
Tests/SaverHost/run.sh --bundle build/Macarchy.saver --output build/evidence/saver-host-visible --visible
```

This additional run opens a borderless window on the main display, checks that Metal presents frames, then verifies that frame callbacks stop. It closes its window when complete.

These tests do not install the saver or change system settings. The harness is not Apple's sandboxed saver host. Actual idle activation, lock/unlock, Settings thumbnail capture, and multiple physical displays need separate runtime verification after installation.
