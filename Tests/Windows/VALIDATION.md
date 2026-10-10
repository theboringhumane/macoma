# Windows module qualification

Run `sh Tests/Windows/run-model-tests.sh` for the pure model suite. It does not request Accessibility or touch application windows.

`ReadOnlyDiscovery.swift` can be compiled with `PublicWindowAccessibility.swift`, `PublicWindowIdentityResolver.swift`, AppKit and ApplicationServices. It reports counts only. Without existing Accessibility permission it reports a skipped discovery, does not prompt, and does not grant permission. Compile/run it separately from the app; its permission identity is different from the signed application.

The isolated Swift 5 module typecheck passed. The combined suite passed 3,072 assertions, including 600 sequences of structural edits, 15 identity cases, motion interpolation, exact final positions, a stalled fake writer, cancellation barriers, rapid-command coalescing, and five focused-target preparation cases. The test log is `/tmp/macarchy-windows-performance-tests-20261011.log`. Identity coverage includes identical same-app parked frames, ambiguous first matches, incomplete geometry, changed process IDs, missing/reused CG IDs, dead AX handles, and frame disagreement. The discovery harness ran with one connected display and no existing Accessibility permission: discovery was skipped, permission was not requested, and no window was moved. These checks do not qualify native movement or restoration.

On installed build 5, the user confirmed that Enable arranged windows, horizontal focus navigation worked, and Pause restored their original positions. After the mouse-contention changes in installed Macoma build 6, the user allowed Accessibility for the renamed app and confirmed smooth mouse drag/resize. Bounded runtime diagnostics recorded two managed windows, deferred reads during native gestures, no failed geometry writes and some application-clamped frames. These observations do not qualify the full compatibility matrix or establish a general frame-rate benchmark. See [build qualification](../../docs/build-qualification.md).

The remaining native qualification uses disposable test-app windows and Accessibility granted to the actual signed Macoma build through its Enable flow:

1. Confirm that launching the app and visiting Windows changes no frames and registers no shortcuts. Enable with one display; compare original/actual frames.
2. Open four windows. Confirm new columns preserve existing widths, focus reveals distant columns, and overflow retains edge slivers.
3. Stack and unstack, reorder rows/columns, cycle widths, and test an application minimum size. Confirm actual frames and visible messages when an application clamps geometry.
4. Test new windows, closing windows, Cmd-Tab, manual resizing, dialogs, minimized windows and native fullscreen. Screen-filling windows are conservatively excluded because there is no public AX fullscreen-state attribute.
5. Switch control-plane pages and close its window. Management should continue. Pause/quit must restore managed frames; Space/display/sleep events must pause. A Space change restores visible windows and leaves other saved frames for explicit restoration.
6. Test shortcut conflicts. A partial shortcut registration must roll back and Enable must remain paused. Test permission revocation and the pending-restore explanation.

Mouse contention regression check on the signed application:

1. Enable, then drag a managed window continuously for at least three seconds; repeat while resizing. This crosses the two-second reconciliation timer. The focus border should hide while dragging, and the window should not snap back after release.
2. Drag the inner-gap slider and release. The pending explicit layout should apply once after release; it must not be lost because the mouse was held.
3. Navigate across four columns rapidly, then Pause during a transition. The newest target should replace earlier motion, and Pause must restore without a later animation write moving the windows again.

Programmatic horizontal scrolling uses a 180ms eased transition with position-only AX writes on a serial worker, one replaceable pending frame, a 450ms write deadline, and a cancellation barrier before restore. Reduce Motion bypasses interpolation. Native mouse drag/resize stays native; both timed scans and observer-driven reconciliation wait until the mouse is released and geometry settles. A currently executing AX call cannot be preempted; actual application latency is measured in `motion_finished` diagnostics (`first_write_delay_ms`, `max_write_duration_ms`). This is not a compositor-level smoothness guarantee.

This first implementation intentionally supports one connected display and the current native Space. Initial AX/CG association needs complete geometry and a unique match. A verified public CG window number stays bound to that live AX handle, allowing identical same-app parked frames. Every write checks that the exact CG number is visible, has the same process, and matches current AX geometry. Hidden, minimized or other-Space windows stay pending until visible again; they are not moved by restoration while invisible. It does not provide compositor clipping, native Space manipulation, arbitrary window corner rounding, raw trackpad gestures, launch-at-login or crash recovery. Native multi-display behavior is not qualified.
