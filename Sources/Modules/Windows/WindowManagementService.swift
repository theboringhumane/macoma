import AppKit
import Combine
import OSLog

struct WindowManagementPreferences: Codable, Equatable {
    var innerGap: Double = 5
    var outerGap: Double = 10
    var newColumnWidth: Double = 0.49
    var showFocusBorder = true
    var keyboardShortcuts = true

    var sanitized: Self {
        var result = self
        result.innerGap = innerGap.isFinite ? min(40, max(0, innerGap)) : 5
        result.outerGap = outerGap.isFinite ? min(60, max(0, outerGap)) : 10
        result.newColumnWidth = newColumnWidth.isFinite ? min(0.97, max(0.25, newColumnWidth)) : 0.49
        return result
    }
}

@MainActor
final class WindowManagementService: ObservableObject {
    /// App lifetime, not pane lifetime. Constructing it does not enumerate or move windows.
    static let shared = WindowManagementService()

    struct WindowSummary: Identifiable {
        let id: Int
        let app: String
        let title: String
        let isFocused: Bool
    }

    struct ColumnSummary: Identifiable {
        let id: Int
        let width: Int
        let windows: [WindowSummary]
    }

    private struct ReconciliationDiagnostic: Equatable {
        let eligible: Int
        let managed: Int
        let columns: Int
        let skipped: Int
        let partial: Bool
    }

    @Published private(set) var isEnabled = false
    @Published private(set) var hasAccessibility = false
    @Published private(set) var status = "Ready when you are."
    @Published private(set) var warning: String?
    @Published private(set) var columns: [ColumnSummary] = []
    @Published private(set) var pendingRestoreCount = 0
    @Published private(set) var skippedWindowCount = 0
    @Published var preferences: WindowManagementPreferences {
        didSet { preferencesChanged(from: oldValue) }
    }

    private let preferencesKey = "Macarchy.Windows.Preferences.v1"
    // Diagnostics contain only fixed event labels, booleans and aggregate counts.
    // Never include window titles, application names, identifiers or file paths.
    private let diagnostics = Logger(subsystem: "dev.theboring.macarchy.windows", category: "WindowManagement")
    private var lastReconciliationDiagnostic: ReconciliationDiagnostic?
    private let accessibility = PublicWindowAccessibility()
    private let hotkeys = WindowManagementHotkeys()
    private let border = WindowFocusBorder()
    private var layout = ScrollingWindowLayout()
    private var windows: [Int: PublicWindowAccessibility.Window] = [:]
    private var originals: [Int: (window: PublicWindowAccessibility.Window, frame: CGRect)] = [:]
    private var appliedFrames: [Int: CGRect] = [:]
    private var mutationEligibleIDs: Set<Int> = []
    private var timer: Timer?
    private var reconciliation: DispatchWorkItem?
    private var notifications: [NSObjectProtocol] = []
    private var screenID: NSNumber?
    private var originalDisplayID: NSNumber?
    private var lastMutation = Date.distantPast
    private var lastExternalGeometryTime = -Double.infinity
    private var lastMouseDownTime = -Double.infinity
    private var ownGeometryFeedbackUntil = -Double.infinity
    private var isApplyingLayout = false
    private var manualInteractionPending = false
    private var pendingExplicitLayout = false
    private var pendingExplicitFocusID: Int?
    private var gestureGateWasActive = false
    private var deferredGestureReads = 0
    private var deferredGestureWrites = 0
    private var motionWriter: CoalescingWindowMotionWriter?
    private var motionTimer: Timer?
    private var motionPlan: WindowMotionPlan?
    private var motionGeneration: UInt64 = 0
    private var pendingMotionFocusID: Int?
    private var accentHex = "89B4FA"

    var managedWindowCount: Int { columns.reduce(0) { $0 + $1.windows.count } }
    var hasSupportedDisplay: Bool { NSScreen.screens.count == 1 }

    private init() {
        if let data = UserDefaults.standard.data(forKey: preferencesKey),
           let decoded = try? JSONDecoder().decode(WindowManagementPreferences.self, from: data) {
            preferences = decoded.sanitized
        } else { preferences = WindowManagementPreferences() }
        hasAccessibility = accessibility.isTrusted
        accessibility.onChange = { [weak self] change in
            MainActor.assumeIsolated { self?.accessibilityChanged(change) }
        }
        hotkeys.onCommand = { [weak self] command in
            MainActor.assumeIsolated { self?.perform(command) }
        }
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.didActivateApplicationNotification, NSWorkspace.didHideApplicationNotification,
                     NSWorkspace.didUnhideApplicationNotification] {
            notifications.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    if self?.motionWriter != nil { self?.cancelMotion() }
                    self?.scheduleReconciliation()
                }
            })
        }
        notifications.append(workspace.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isEnabled else { return }
                self.pause(reason: "Paused after a Space change. Return to the managed Space to restore any remaining windows.", visibleOnly: true)
            }
        })
        notifications.append(workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if self?.isEnabled == true { self?.pause(reason: "Paused for sleep. Enable when you are ready.") } }
        })
        notifications.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if self.isEnabled { self.pause(reason: "Paused because the display configuration changed.") }
                    else { self.objectWillChange.send() }
                }
            })
        notifications.append(NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
            object: nil, queue: .main) { [weak self] _ in
                // Synchronous: a Task could run after the application has exited.
                MainActor.assumeIsolated { self?.pause(reason: "Stopped.") }
            })
    }

    func updateAccent(_ hex: String) { accentHex = hex; updateBorder() }

    func refreshAccess() {
        hasAccessibility = accessibility.isTrusted
        if isEnabled && !hasAccessibility { pause(reason: "Accessibility access was removed. Re-enable access to restore saved windows.") }
    }

    func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }

    /// The only entry point that can start controlling windows. Bound to Enable.
    func enable() {
        guard !isEnabled else { return }
        diagnostics.notice("event=enable_requested display_count=\(NSScreen.screens.count, privacy: .public) accessibility_granted=\(self.accessibility.isTrusted, privacy: .public)")
        warning = nil
        guard NSScreen.screens.count == 1, let screen = NSScreen.screens.first else {
            diagnostics.notice("event=enable_blocked gate=display_count display_count=\(NSScreen.screens.count, privacy: .public)")
            status = "Connect one display to enable this first version. Multiple displays are not supported yet."
            return
        }
        hasAccessibility = accessibility.requestAccess()
        diagnostics.notice("event=enable_access_check accessibility_granted=\(self.hasAccessibility, privacy: .public)")
        guard hasAccessibility else {
            diagnostics.notice("event=enable_blocked gate=accessibility")
            status = "Allow Macoma in Accessibility, then press Enable again."
            return
        }
        if !originals.isEmpty {
            restoreSavedWindows(visibleOnly: true)
            guard originals.isEmpty else {
                diagnostics.notice("event=enable_blocked gate=pending_restoration pending_count=\(self.originals.count, privacy: .public)")
                status = "Restore the previous session before enabling again. Return to its Space and make its windows visible."
                return
            }
        }
        if preferences.keyboardShortcuts, let error = hotkeys.register() {
            diagnostics.notice("event=enable_blocked gate=shortcut_registration")
            status = error
            return
        }
        layout = ScrollingWindowLayout()
        configureLayout()
        screenID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        originalDisplayID = screenID
        isEnabled = true
        lastReconciliationDiagnostic = nil
        diagnostics.notice("event=enabled keyboard_shortcuts=\(self.preferences.keyboardShortcuts, privacy: .public)")
        status = "Looking for resizable windows on this Space…"
        reconcile()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reconcile() }
        }
    }

    func pause(reason: String = "Paused. Original window positions restored.", visibleOnly: Bool = false) {
        diagnostics.notice("event=pause_requested was_enabled=\(self.isEnabled, privacy: .public) saved_count=\(self.originals.count, privacy: .public) visible_only=\(visibleOnly, privacy: .public)")
        isEnabled = false
        cancelMotion() // Barrier: no stale writer can race frame restoration.
        timer?.invalidate(); timer = nil
        reconciliation?.cancel(); reconciliation = nil
        accessibility.stopObserving()
        hotkeys.unregister()
        border.hide()
        restoreSavedWindows(visibleOnly: visibleOnly)
        windows.removeAll()
        appliedFrames.removeAll()
        mutationEligibleIDs.removeAll()
        pendingExplicitLayout = false
        pendingExplicitFocusID = nil
        manualInteractionPending = false
        layout = ScrollingWindowLayout()
        columns = []
        screenID = nil
        status = originals.isEmpty ? reason : "Paused with \(originals.count) saved window position(s) waiting to restore."
        diagnostics.notice("event=paused pending_restore_count=\(self.originals.count, privacy: .public)")
    }

    func restoreSavedWindows(visibleOnly: Bool = false) {
        hasAccessibility = accessibility.isTrusted
        guard hasAccessibility else {
            pendingRestoreCount = originals.count
            diagnostics.notice("event=restore_blocked accessibility_granted=false pending_count=\(self.originals.count, privacy: .public)")
            return
        }
        let restoreCandidateCount = originals.count
        var restoredCount = 0
        var closedCount = 0
        var remaining: [Int: (window: PublicWindowAccessibility.Window, frame: CGRect)] = [:]
        for (id, original) in originals {
            guard let current = accessibility.frame(of: original.window.element) else {
                if !accessibility.isDefinitelyClosed(original.window) { remaining[id] = original }
                else { closedCount += 1 }
                continue
            }
            if visibleOnly && !accessibility.isVisible(original.window) { remaining[id] = original; continue }
            // Do not disturb native fullscreen. It can be restored after leaving fullscreen.
            if NSScreen.screens.contains(where: { framesClose(current, axFrame(of: $0.frame), tolerance: 3) }) {
                remaining[id] = original; continue
            }
            let target = restorableFrame(original.frame)
            let result = accessibility.setFrame(target, of: original.window)
            let restored = result.actualFrame.map { framesClose($0, target, tolerance: 4) } ?? false
            if result.error != nil || !restored {
                remaining[id] = original
            } else { restoredCount += 1 }
        }
        originals = remaining
        pendingRestoreCount = originals.count
        if remaining.isEmpty {
            originalDisplayID = nil
            warning = nil
            if !isEnabled { status = "Original window positions restored." }
        }
        if !remaining.isEmpty {
            warning = "Some windows could not be restored. Keep Accessibility enabled, return to their Space, leave fullscreen, then choose Restore saved windows."
        }
        diagnostics.notice("event=restore_result candidate_count=\(restoreCandidateCount, privacy: .public) restored_count=\(restoredCount, privacy: .public) closed_count=\(closedCount, privacy: .public) pending_count=\(remaining.count, privacy: .public)")
    }

    func focusWindow(_ id: Int) {
        guard isEnabled, let window = windows[id] else { return }
        layout.focus(id)
        applyLayout(requiresFocusedWindow: true)
        if mutationEligibleIDs.contains(id) {
            if motionWriter != nil { pendingMotionFocusID = id }
            else if !accessibility.focus(window) { warning = "This application did not accept the focus request." }
        } else { warning = "This window is not currently verified as visible on this Space." }
        publishColumns()
        updateBorder()
    }

    func perform(_ command: WindowManagementCommand) {
        guard isEnabled else { return }
        if command == .pause { pause(); return }
        guard let screen = NSScreen.screens.first, layout.focusedWindow != nil else { return }
        var focusAfter = false
        switch command {
        case .focusLeft: layout.focus(.left); focusAfter = true
        case .focusRight: layout.focus(.right); focusAfter = true
        case .focusUp: layout.focus(.up); focusAfter = true
        case .focusDown: layout.focus(.down); focusAfter = true
        case .moveLeft: layout.moveFocused(.left)
        case .moveRight: layout.moveFocused(.right)
        case .moveUp: layout.moveFocused(.up)
        case .moveDown: layout.moveFocused(.down)
        case .narrower: layout.cycleFocusedWidth(viewportWidth: screen.visibleFrame.width, backwards: true)
        case .wider: layout.cycleFocusedWidth(viewportWidth: screen.visibleFrame.width)
        case .fullWidth: layout.fillFocusedWidth(viewportWidth: screen.visibleFrame.width)
        case .stack:
            if !layout.stackFocusedLeft() { warning = "Move to a column with a neighbour on its left to stack a window." }
        case .unstack:
            if let id = layout.focusedWindow, !layout.unstack(id) { warning = "This window already has its own column." }
        case .pause: break
        }
        applyLayout(requiresFocusedWindow: focusAfter)
        if focusAfter, let id = layout.focusedWindow, mutationEligibleIDs.contains(id), let window = windows[id] {
            if motionWriter != nil { pendingMotionFocusID = id }
            else { _ = accessibility.focus(window) }
        }
        publishColumns()
        updateBorder()
    }

    private func accessibilityChanged(_ change: PublicWindowAccessibility.Change) {
        guard isEnabled else { return }
        if change == .geometry {
            let now = ProcessInfo.processInfo.systemUptime
            let mouseHeld = NSEvent.pressedMouseButtons != 0
            if !mouseHeld && (isApplyingLayout || motionWriter != nil || now < ownGeometryFeedbackUntil) { return }
            cancelMotion()
            lastExternalGeometryTime = now
            manualInteractionPending = true
            border.hide()
        } else if motionWriter != nil { cancelMotion() }
        scheduleReconciliation()
    }

    private var nativeGestureIsActive: Bool {
        let now = ProcessInfo.processInfo.systemUptime
        if NSEvent.pressedMouseButtons != 0 { lastMouseDownTime = now; border.hide() }
        return NSEvent.pressedMouseButtons != 0 || now - lastMouseDownTime < 0.12 || now - lastExternalGeometryTime < 0.35
    }

    private func recordGestureDeferral(write: Bool) {
        if write { deferredGestureWrites += 1 } else { deferredGestureReads += 1 }
        if !gestureGateWasActive {
            gestureGateWasActive = true
            diagnostics.notice("event=native_gesture_gate active=true")
        }
    }

    private func finishGestureDeferral() {
        guard gestureGateWasActive else { return }
        diagnostics.notice("event=native_gesture_gate active=false deferred_reads=\(self.deferredGestureReads, privacy: .public) deferred_writes=\(self.deferredGestureWrites, privacy: .public)")
        gestureGateWasActive = false
        deferredGestureReads = 0
        deferredGestureWrites = 0
    }

    private func scheduleReconciliation(delay: TimeInterval = 0.35) {
        guard isEnabled else { return }
        reconciliation?.cancel()
        let item = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.reconcile() } }
        reconciliation = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func reconcile() {
        guard isEnabled else { return }
        // The polling timer obeys the same gate as AX notifications. A native
        // drag/resize must not start a scan or a layout write under the pointer.
        if nativeGestureIsActive {
            cancelMotion()
            recordGestureDeferral(write: false)
            scheduleReconciliation(delay: 0.15)
            return
        }
        if motionWriter != nil || ProcessInfo.processInfo.systemUptime < ownGeometryFeedbackUntil {
            scheduleReconciliation(delay: 0.15)
            return
        }
        finishGestureDeferral()
        hasAccessibility = accessibility.isTrusted
        guard hasAccessibility else { pause(reason: "Accessibility access was removed. Restore it before continuing."); return }
        guard NSScreen.screens.count == 1, let screen = NSScreen.screens.first,
              screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber == screenID else {
            pause(reason: "Paused because the display configuration changed."); return
        }
        let discovery = accessibility.discover(screenFrame: axFrame(of: screen.frame))
        let settledManualInteraction = manualInteractionPending
        let initialDiscovery = layout.windowIDs.isEmpty
        skippedWindowCount = discovery.skipped
        let live = Set(discovery.windows.map(\.id))
        var changed = false
        var structuralChange = false
        // A deadline or count limit produces a partial scan. Missing rows in
        // that scan are not evidence that a previously managed window closed.
        for id in layout.windowIDs where !live.contains(id) && !discovery.limitReached {
            layout.remove(id); windows.removeValue(forKey: id); appliedFrames.removeValue(forKey: id)
            changed = true
            structuralChange = true
        }
        let sorted = discovery.windows.sorted { lhs, rhs in
            if abs(lhs.frame.minX - rhs.frame.minX) > 4 { return lhs.frame.minX < rhs.frame.minX }
            return lhs.frame.minY < rhs.frame.minY
        }
        for window in sorted {
            if windows[window.id] == nil {
                layout.add(window.id, viewportWidth: screen.visibleFrame.width, afterFocused: !initialDiscovery)
                changed = true
                structuralChange = true
            } else if (settledManualInteraction || Date().timeIntervalSince(lastMutation) > 0.7),
                      let previous = appliedFrames[window.id], abs(previous.width - window.frame.width) > 4 {
                // Keep intentional manual width changes instead of fighting the application.
                layout.setWidth(window.frame.width, for: window.id)
                changed = true
            }
            windows[window.id] = window
            if settledManualInteraction { appliedFrames[window.id] = window.frame }
            if window.isFocused && layout.focusedWindow != window.id {
                layout.focus(window.id); changed = true
            }
        }
        accessibility.observe(Array(windows.values))
        // Adopt a finished native drag/resize without immediately snapping it
        // back. The next explicit layout action uses the resulting column width.
        let requestedLayout = pendingExplicitLayout
        let requestedFocusID = pendingExplicitFocusID
        pendingExplicitLayout = false
        pendingExplicitFocusID = nil
        manualInteractionPending = false
        let requestedFocusAvailable = requestedFocusID.map { windows[$0] != nil } ?? true
        if let id = requestedFocusID, requestedFocusAvailable { layout.focus(id) }
        if requestedFocusAvailable && (structuralChange || requestedLayout || (changed && !settledManualInteraction)) {
            applyLayout(verifiedIDs: live, explicit: false, requiresFocusedWindow: requestedFocusID != nil)
            if let id = requestedFocusID, mutationEligibleIDs.contains(id), let window = windows[id] {
                if motionWriter != nil { pendingMotionFocusID = id }
                else { _ = accessibility.focus(window) }
            }
        } else if !requestedFocusAvailable {
            warning = "The requested window is no longer available. No other columns were moved."
        }
        publishColumns()
        updateBorder()
        status = windows.isEmpty ? "Enabled. Open a resizable window on this Space."
            : "Managing \(windows.count) window\(windows.count == 1 ? "" : "s") in \(layout.columns.count) column\(layout.columns.count == 1 ? "" : "s")."
        if discovery.limitReached { warning = "Window discovery reached its time or size limit. Known windows are retained; additional windows may be left alone." }
        let diagnostic = ReconciliationDiagnostic(eligible: discovery.windows.count, managed: windows.count,
            columns: layout.columns.count, skipped: discovery.skipped, partial: discovery.limitReached)
        if diagnostic != lastReconciliationDiagnostic {
            diagnostics.notice("event=reconciliation eligible_count=\(diagnostic.eligible, privacy: .public) managed_count=\(diagnostic.managed, privacy: .public) column_count=\(diagnostic.columns, privacy: .public) skipped_count=\(diagnostic.skipped, privacy: .public) partial_scan=\(diagnostic.partial, privacy: .public)")
            lastReconciliationDiagnostic = diagnostic
        }
    }

    private func applyLayout(allowCorrection: Bool = true, verifiedIDs: Set<Int>? = nil, explicit: Bool = true,
                             requiresFocusedWindow: Bool = false) {
        guard isEnabled, let screen = NSScreen.screens.first else { return }
        mutationEligibleIDs.removeAll()
        if nativeGestureIsActive {
            cancelMotion()
            pendingExplicitLayout = pendingExplicitLayout || explicit
            if requiresFocusedWindow { pendingExplicitFocusID = layout.focusedWindow }
            recordGestureDeferral(write: true)
            scheduleReconciliation(delay: 0.15)
            return
        }
        cancelMotion() // Retarget from the actual in-flight position, never queue transitions.
        let operationStart = ProcessInfo.processInfo.systemUptime
        configureLayout()
        layout.revealFocused(viewportWidth: screen.visibleFrame.width)
        let viewport = axFrame(of: screen.visibleFrame)
        let placements = layout.placements(in: viewport)
        let candidates = windows.filter { verifiedIDs?.contains($0.key) ?? true }
        let preparationPlan = WindowPreparationPlan(focusedID: layout.focusedWindow, requiresFocus: requiresFocusedWindow,
            frames: candidates.mapValues(\.frame), targets: Dictionary(uniqueKeysWithValues: placements.map { ($0.windowID, $0.frame) }),
            viewport: viewport)
        let prepared = accessibility.prepare(preparationPlan.orderedIDs.compactMap { candidates[$0] }, screenFrame: axFrame(of: screen.frame))
        let preparationMS = (ProcessInfo.processInfo.systemUptime - operationStart) * 1000
        guard preparationPlan.canApply(verifiedIDs: Set(prepared.keys)) else {
            warning = "The requested window could not be verified on this Space. No other columns were moved."
            diagnostics.notice("event=layout_blocked gate=unverified_focus_target preparation_ms=\(preparationMS, privacy: .public)")
            return
        }
        isApplyingLayout = true
        defer {
            isApplyingLayout = false
            ownGeometryFeedbackUntil = ProcessInfo.processInfo.systemUptime + 0.3
        }
        let eligible = placements.filter { prepared[$0.windowID] != nil }
        let horizontalOnly = !eligible.isEmpty && eligible.allSatisfy { placement in
            let current = prepared[placement.windowID]!.frame
            return abs(current.width - placement.frame.width) < 1 && abs(current.height - placement.frame.height) < 1
                && abs(current.minY - placement.frame.minY) < 1
        }
        let horizontalMovement = eligible.contains { abs(prepared[$0.windowID]!.frame.minX - $0.frame.minX) > 1 }
        if explicit && horizontalOnly && horizontalMovement && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            for placement in eligible {
                let permit = prepared[placement.windowID]!
                if originals[placement.windowID] == nil { originals[placement.windowID] = (permit.window, permit.frame) }
                mutationEligibleIDs.insert(placement.windowID)
            }
            startMotion(placements: eligible, prepared: prepared, preparationMS: preparationMS)
            return
        }
        var correction = false
        var refused = 0
        var eligibleCount = 0
        var unchangedCount = 0
        var successfulWrites = 0
        var clampedWrites = 0
        var failedWrites = 0
        lastMutation = Date()
        for placement in placements {
            if NSEvent.pressedMouseButtons != 0 {
                recordGestureDeferral(write: true)
                manualInteractionPending = true
                scheduleReconciliation(delay: 0.15)
                break
            }
            guard var window = windows[placement.windowID],
                  let permit = prepared[window.id] else { continue }
            let current = permit.frame
            mutationEligibleIDs.insert(window.id)
            eligibleCount += 1
            if originals[window.id] == nil { originals[window.id] = (window, current) }
            if framesClose(current, placement.frame, tolerance: 1) {
                unchangedCount += 1
                appliedFrames[window.id] = current; continue
            }
            let result = accessibility.setPreparedFrame(placement.frame, prepared: permit)
            if result.error != nil { failedWrites += 1 }
            else if let actual = result.actualFrame {
                if framesClose(actual, placement.frame, tolerance: 4) { successfulWrites += 1 }
                else { clampedWrites += 1 }
            } else { failedWrites += 1 }
            if result.error != nil { refused += 1 }
            if let actual = result.actualFrame {
                window.frame = actual
                windows[window.id] = window
                appliedFrames[window.id] = actual
                if allowCorrection && actual.width > placement.frame.width + 4 {
                    layout.setWidth(actual.width, for: window.id); correction = true
                }
                if allowCorrection && actual.height > placement.frame.height + 4,
                   layout.unstack(window.id) {
                    correction = true
                    warning = "An application's minimum height did not fit the stack, so it was returned to its own column."
                }
                if !framesClose(actual, placement.frame, tolerance: 4) && !correction { refused += 1 }
            } else { refused += 1 }
        }
        if refused > 0 { warning = "Some applications limited their size or position. Their actual frames are kept; macOS may leave wider edge slivers." }
        diagnostics.notice("event=frame_application candidate_count=\(placements.count, privacy: .public) eligible_count=\(eligibleCount, privacy: .public) unchanged_count=\(unchangedCount, privacy: .public) successful_writes=\(successfulWrites, privacy: .public) clamped_writes=\(clampedWrites, privacy: .public) failed_writes=\(failedWrites, privacy: .public) correction_requested=\(correction, privacy: .public) correction_pass=\(!allowCorrection, privacy: .public)")
        let operationMS = (ProcessInfo.processInfo.systemUptime - operationStart) * 1000
        diagnostics.notice("event=layout_timing preparation_ms=\(preparationMS, privacy: .public) total_ms=\(operationMS, privacy: .public) cg_snapshot_count=1")
        if correction { applyLayout(allowCorrection: false, verifiedIDs: Set(prepared.keys), explicit: explicit,
                                   requiresFocusedWindow: requiresFocusedWindow) }
        updateBorder()
    }

    private func startMotion(placements: [ScrollingWindowLayout.Placement],
                             prepared: [Int: PublicWindowAccessibility.PreparedWindow], preparationMS: Double) {
        let now = ProcessInfo.processInfo.systemUptime
        let from = Dictionary(uniqueKeysWithValues: placements.map { ($0.windowID, prepared[$0.windowID]!.frame.origin) })
        let targets = Dictionary(uniqueKeysWithValues: placements.map { ($0.windowID, $0.frame) })
        let plan = WindowMotionPlan(from: from, to: targets.mapValues(\.origin), startTime: now, duration: 0.18)
        motionGeneration &+= 1
        let generation = motionGeneration
        let deadline = now + 0.45
        let writer = CoalescingWindowMotionWriter(initialPositions: from, write: { id, point in
            // Public button-state polling requires no event tap. Check on the
            // worker too, so mouse-down cannot leave a queued burst of writes.
            guard ProcessInfo.processInfo.systemUptime <= deadline,
                  !CGEventSource.buttonState(.combinedSessionState, button: .left),
                  let permit = prepared[id] else { return false }
            return PublicWindowAccessibility.writePreparedPosition(point, prepared: permit)
        }, completion: { [weak self] stats in
            DispatchQueue.main.async {
                guard let self, self.motionGeneration == generation else { return }
                self.finishMotion(generation: generation, targets: targets, stats: stats)
            }
        })
        motionWriter = writer
        motionPlan = plan
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tickMotion() }
        }
        motionTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        diagnostics.notice("event=motion_started target_count=\(targets.count, privacy: .public) preparation_ms=\(preparationMS, privacy: .public) duration_ms=180 cg_snapshot_count=1")
        tickMotion()
    }

    private func tickMotion() {
        guard isEnabled, let writer = motionWriter, let plan = motionPlan else { return }
        if nativeGestureIsActive {
            cancelMotion()
            manualInteractionPending = true
            recordGestureDeferral(write: true)
            scheduleReconciliation(delay: 0.15)
            return
        }
        guard accessibility.isTrusted else { pause(reason: "Accessibility access was removed."); return }
        guard NSScreen.screens.count == 1,
              NSScreen.screens.first?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber == screenID else {
            pause(reason: "Paused because the display configuration changed."); return
        }
        let now = ProcessInfo.processInfo.systemUptime
        let final = plan.isFinished(at: now)
        let positions = plan.sample(at: now).mapValues { CGPoint(x: $0.x.rounded(), y: $0.y.rounded()) }
        writer.submit(positions: positions, isFinal: final)
        for (id, point) in writer.snapshot().positions {
            if var frame = appliedFrames[id] ?? windows[id]?.frame { frame.origin = point; appliedFrames[id] = frame }
        }
        updateBorder()
        if final { motionTimer?.invalidate(); motionTimer = nil }
    }

    private func cancelMotion() {
        motionGeneration &+= 1
        motionTimer?.invalidate(); motionTimer = nil
        motionPlan = nil
        pendingMotionFocusID = nil
        guard let writer = motionWriter else { return }
        let stats = writer.cancelAndWait()
        motionWriter = nil
        for (id, point) in stats.positions {
            if var frame = appliedFrames[id] ?? windows[id]?.frame { frame.origin = point; appliedFrames[id] = frame }
        }
        ownGeometryFeedbackUntil = ProcessInfo.processInfo.systemUptime + 0.3
        diagnostics.notice("event=motion_cancelled elapsed_ms=\(stats.elapsed * 1000, privacy: .public) successful_writes=\(stats.successfulWrites, privacy: .public) failed_writes=\(stats.failedWrites, privacy: .public)")
    }

    private func finishMotion(generation: UInt64, targets: [Int: CGRect], stats: CoalescingWindowMotionWriter.Stats) {
        guard motionGeneration == generation, isEnabled else { return }
        motionTimer?.invalidate(); motionTimer = nil
        motionWriter = nil
        motionPlan = nil
        let focusID = pendingMotionFocusID
        pendingMotionFocusID = nil
        ownGeometryFeedbackUntil = ProcessInfo.processInfo.systemUptime + 0.3
        lastMutation = Date()
        if nativeGestureIsActive {
            manualInteractionPending = true
            recordGestureDeferral(write: false)
            scheduleReconciliation(delay: 0.15)
            return
        }
        // One final CG readback, outside the animation writer. No AX discovery.
        let actual = accessibility.currentVisibleFrames(targets.keys.compactMap { windows[$0] })
        var clamped = 0
        for (id, frame) in actual {
            appliedFrames[id] = frame
            windows[id]?.frame = frame
            if let target = targets[id], !framesClose(frame, target, tolerance: 4) { clamped += 1 }
        }
        if stats.failedWrites > 0 || clamped > 0 { warning = "Some applications limited the transition. Their actual positions have been kept." }
        if !nativeGestureIsActive, let id = focusID, let window = windows[id], let frame = actual[id], let screen = NSScreen.screens.first,
           frame.intersection(axFrame(of: screen.visibleFrame)).width >= min(frame.width, screen.visibleFrame.width) * 0.9 {
            _ = accessibility.focus(window)
        }
        diagnostics.notice("event=motion_finished elapsed_ms=\(stats.elapsed * 1000, privacy: .public) first_write_delay_ms=\(stats.firstWriteDelay * 1000, privacy: .public) max_write_duration_ms=\(stats.maxWriteDuration * 1000, privacy: .public) successful_writes=\(stats.successfulWrites, privacy: .public) failed_writes=\(stats.failedWrites, privacy: .public) skipped_writes=\(stats.skippedWrites, privacy: .public) clamped_count=\(clamped, privacy: .public) final_cg_snapshot_count=1")
        updateBorder()
        scheduleReconciliation()
    }

    private func configureLayout() {
        let values = preferences.sanitized
        layout.innerGap = values.innerGap
        layout.outerGap = values.outerGap
        layout.defaultWidthRatio = values.newColumnWidth
    }

    private func preferencesChanged(from oldValue: WindowManagementPreferences) {
        if let data = try? JSONEncoder().encode(preferences.sanitized) { UserDefaults.standard.set(data, forKey: preferencesKey) }
        guard isEnabled else { return }
        if oldValue.keyboardShortcuts != preferences.keyboardShortcuts {
            if preferences.keyboardShortcuts, let error = hotkeys.register() { pause(reason: error); status = error; return }
            if !preferences.keyboardShortcuts { hotkeys.unregister() }
        }
        if oldValue.innerGap != preferences.innerGap || oldValue.outerGap != preferences.outerGap { applyLayout(); publishColumns() }
        updateBorder()
    }

    private func publishColumns() {
        columns = layout.columns.map { column in
            ColumnSummary(id: column.id, width: Int(column.width.rounded()), windows: column.windows.compactMap { id in
                windows[id].map { WindowSummary(id: id, app: $0.appName, title: $0.title, isFocused: id == layout.focusedWindow) }
            })
        }
    }

    private func updateBorder() {
        guard !nativeGestureIsActive else { border.hide(); return }
        guard isEnabled, preferences.showFocusBorder, let id = layout.focusedWindow, let window = windows[id],
              NSWorkspace.shared.frontmostApplication?.processIdentifier == window.pid,
              let screen = NSScreen.screens.first else { border.hide(); return }
        let frame = appliedFrames[id] ?? window.frame
        guard
              frame.intersection(axFrame(of: screen.visibleFrame)).width > 12 else { border.hide(); return }
        let hex = accentHex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        let value = UInt64(hex, radix: 16) ?? 0x89B4FA
        let color = NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255, green: CGFloat((value >> 8) & 255) / 255,
                            blue: CGFloat(value & 255) / 255, alpha: 1)
        border.show(axFrame: frame, color: color, primaryScreenHeight: screen.frame.height)
    }

    private func axFrame(of appKitFrame: CGRect) -> CGRect {
        let height = NSScreen.screens.first?.frame.height ?? appKitFrame.height
        return CGRect(x: appKitFrame.minX, y: height - appKitFrame.maxY, width: appKitFrame.width, height: appKitFrame.height)
    }

    private func restorableFrame(_ original: CGRect) -> CGRect {
        if NSScreen.screens.count == 1,
           NSScreen.screens.first?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber == originalDisplayID {
            return original // Preserve even intentional partial offscreen placement.
        }
        let screens = NSScreen.screens.map { axFrame(of: $0.visibleFrame) }
        guard let target = screens.max(by: { $0.intersection(original).area < $1.intersection(original).area }) else { return original }
        if target.contains(original) { return original }
        // Preserve size but make the title bar reachable after unplugging a display.
        return CGRect(x: min(max(original.minX, target.minX), max(target.minX, target.maxX - original.width)),
                      y: min(max(original.minY, target.minY), max(target.minY, target.maxY - 80)),
                      width: original.width, height: original.height)
    }

    private func framesClose(_ a: CGRect, _ b: CGRect, tolerance: CGFloat) -> Bool {
        abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance
            && abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
    }
}

private extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }
}
