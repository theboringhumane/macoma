import AppKit
import ApplicationServices

/// Public AX and Core Graphics only. No WindowServer/SkyLight symbols.
/// Initial AX/CG association requires unique geometry. That public CG number
/// stays bound to the live CFEqual AX handle, including when parked frames overlap.
/// It never uses the private _AXUIElementGetWindow API.
final class PublicWindowAccessibility {
    struct Window {
        let id: Int
        let element: AXUIElement
        let pid: pid_t
        let cgWindowNumber: UInt32
        let appName: String
        let title: String
        var frame: CGRect
        let isFocused: Bool
    }

    struct Discovery {
        let windows: [Window]
        let skipped: Int
        let limitReached: Bool
    }

    struct WriteResult {
        let actualFrame: CGRect?
        let error: AXError?
    }

    enum Change { case geometry, focus, structure }

    /// A short-lived proof from one public CG snapshot and one batched AX read.
    /// Use only for the current command/transition, never as a new identity.
    struct PreparedWindow {
        let window: Window
        let frame: CGRect
    }

    private struct WindowState {
        let frame: CGRect
        let standard: Bool
        let minimized: Bool
        let modal: Bool
    }

    private struct Identity {
        let id: Int
        let element: AXUIElement
        let binding: PublicWindowIdentityResolver.Binding
    }

    private var identities: [Identity] = []
    private var nextID = 1
    private var observers: [AXObserver] = []
    private var observedIDs: Set<Int> = []
    private var applicationScanOffset = 0
    var onChange: ((Change) -> Void)?

    var isTrusted: Bool { AXIsProcessTrusted() }

    /// Call only after the person presses Enable.
    func requestAccess() -> Bool {
        AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
    }

    func discover(screenFrame: CGRect) -> Discovery {
        guard isTrusted else { return Discovery(windows: [], skipped: 0, limitReached: false) }
        let visible = visibleWindows()
        let pids = Set(visible.map(\.pid))
        let allApps = NSWorkspace.shared.runningApplications.filter {
            $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
                && $0.activationPolicy == .regular && !$0.isTerminated && pids.contains($0.processIdentifier)
        }.sorted { $0.processIdentifier < $1.processIdentifier }
        let start = allApps.isEmpty ? 0 : applicationScanOffset % allApps.count
        let orderedApps = Array(allApps.dropFirst(start)) + Array(allApps.prefix(start))
        var attemptedApps = 0
        defer {
            // A slow app or a count limit must not starve later applications.
            applicationScanOffset = allApps.isEmpty ? 0 : (start + max(1, attemptedApps)) % allApps.count
        }
        var result: [Window] = []
        var skipped = 0
        var capped = allApps.count > 24
        // Yield back to the main run loop between scans even if an application
        // is not responding. Each individual AX call also has a short timeout.
        let deadline = Date().addingTimeInterval(1.2)
        for app in orderedApps.prefix(24) {
            if NSEvent.pressedMouseButtons != 0 || Date() >= deadline || result.count >= 48 { capped = true; break }
            attemptedApps += 1
            let element = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(element, 0.075)
            guard let windows = value(element, kAXWindowsAttribute) as? [AXUIElement] else { capped = true; continue }
            // Unmeasured AX windows can share the same frame on another Space.
            // Never infer uniqueness from a truncated app window list.
            guard windows.count <= 48 else { capped = true; skipped += windows.count; continue }
            let focused = axElement(value(element, kAXFocusedWindowAttribute))
            var measured: [(element: AXUIElement, frame: CGRect?)] = []
            for window in windows.prefix(48) {
                if NSEvent.pressedMouseButtons != 0 || Date() >= deadline { capped = true; break }
                AXUIElementSetMessagingTimeout(window, 0.075)
                measured.append((window, frame(of: window)))
            }
            guard measured.count == windows.count, measured.allSatisfy({ $0.frame != nil }) else {
                capped = true; skipped += windows.count; continue
            }
            for candidate in measured {
                if NSEvent.pressedMouseButtons != 0 || Date() >= deadline { capped = true; break }
                let window = candidate.element
                guard result.count < 48 else { capped = true; break }
                guard isManageable(window, screenFrame: screenFrame), let frame = frame(of: window) else {
                    skipped += 1; continue
                }
                let existing = identities.first { CFEqual($0.element, window) }
                if let existing, !hasLiveWindowRole(existing.element) {
                    // Do not recycle a dead cached handle. A subsequent scan
                    // may establish a new identity through the unique-match path.
                    if isDefinitelyInvalid(existing.element, pid: existing.binding.pid) {
                        identities.removeAll { $0.id == existing.id }
                    }
                    skipped += 1; continue
                }
                guard let binding = PublicWindowIdentityResolver.resolve(existing: existing?.binding,
                    pid: app.processIdentifier, frame: frame, handleIsLive: true,
                    completeAXFrames: measured.map(\.frame), visible: visible) else { skipped += 1; continue }
                let id: Int
                if let existing { id = existing.id }
                else {
                    // A public CG ID can belong to only one live AX identity.
                    if let owner = identities.first(where: { $0.binding == binding }) {
                        guard isDefinitelyInvalid(owner.element, pid: owner.binding.pid) else { skipped += 1; continue }
                        identities.removeAll { $0.id == owner.id }
                    }
                    id = nextID; nextID += 1
                    identities.append(Identity(id: id, element: window, binding: binding))
                }
                result.append(Window(id: id, element: window, pid: app.processIdentifier,
                    cgWindowNumber: binding.number,
                    appName: app.localizedName ?? "Application", title: value(window, kAXTitleAttribute) as? String ?? "",
                    frame: frame, isFocused: focused.map { CFEqual($0, window) } == true
                        && NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier))
            }
            if windows.count > 48 { capped = true }
        }
        // Bound retained AX handles without changing identities of live windows.
        if identities.count > 192 {
            let live = Set(result.map(\.id)).union(observedIDs)
            identities.removeAll { !live.contains($0.id) }
        }
        return Discovery(windows: result, skipped: skipped, limitReached: capped)
    }

    func frame(of window: AXUIElement) -> CGRect? {
        guard let values = values(window, [kAXPositionAttribute, kAXSizeAttribute]), values.count == 2 else { return nil }
        return decodeFrame(position: values[0], size: values[1])
    }

    private func decodeFrame(position rawPosition: CFTypeRef, size rawSize: CFTypeRef) -> CGRect? {
        guard CFGetTypeID(rawPosition) == AXValueGetTypeID(), CFGetTypeID(rawSize) == AXValueGetTypeID() else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(unsafeBitCast(rawPosition, to: AXValue.self), .cgPoint, &position),
              AXValueGetValue(unsafeBitCast(rawSize, to: AXValue.self), .cgSize, &size),
              position.x.isFinite, position.y.isFinite, size.width.isFinite, size.height.isFinite else { return nil }
        return CGRect(origin: position, size: size)
    }

    private func state(of window: AXUIElement) -> WindowState? {
        guard let values = values(window, [kAXRoleAttribute, kAXSubroleAttribute, kAXMinimizedAttribute,
            kAXModalAttribute, kAXPositionAttribute, kAXSizeAttribute]), values.count == 6,
              let frame = decodeFrame(position: values[4], size: values[5]) else { return nil }
        return WindowState(frame: frame,
            standard: values[0] as? String == kAXWindowRole && values[1] as? String == kAXStandardWindowSubrole,
            minimized: values[2] as? Bool != false, modal: values[3] as? Bool == true)
    }

    func prepare(_ known: [Window], screenFrame: CGRect) -> [Int: PreparedWindow] {
        guard isTrusted else { return [:] }
        let visible = visibleWindows() // One CG snapshot for the entire command.
        var prepared: [Int: PreparedWindow] = [:]
        let deadline = ProcessInfo.processInfo.systemUptime + 0.18
        for window in known {
            if NSEvent.pressedMouseButtons != 0 || ProcessInfo.processInfo.systemUptime >= deadline { break }
            guard let identity = identities.first(where: { $0.id == window.id }),
                  CFEqual(identity.element, window.element), identity.binding.pid == window.pid,
                  identity.binding.number == window.cgWindowNumber else { continue }
            var ownerPID: pid_t = 0
            guard AXUIElementGetPid(window.element, &ownerPID) == .success, ownerPID == window.pid else { continue }
            AXUIElementSetMessagingTimeout(window.element, 0.025)
            guard let state = state(of: window.element), state.standard, !state.minimized, !state.modal,
                  !framesClose(state.frame, screenFrame, tolerance: 3),
                  PublicWindowIdentityResolver.isVisible(identity.binding, pid: window.pid, frame: state.frame, visible: visible) else { continue }
            prepared[window.id] = PreparedWindow(window: window, frame: state.frame)
        }
        return prepared
    }

    func setPreparedFrame(_ target: CGRect, prepared: PreparedWindow) -> WriteResult {
        guard NSEvent.pressedMouseButtons == 0 else { return WriteResult(actualFrame: prepared.frame, error: .cannotComplete) }
        let window = prepared.window.element
        var firstError: AXError?
        if abs(target.width - prepared.frame.width) > 0.5 || abs(target.height - prepared.frame.height) > 0.5 {
            var size = target.size
            if let value = AXValueCreate(.cgSize, &size) {
                let error = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value)
                if error != .success { firstError = error }
            }
        }
        if abs(target.minX - prepared.frame.minX) > 0.5 || abs(target.minY - prepared.frame.minY) > 0.5 {
            guard NSEvent.pressedMouseButtons == 0 else { return WriteResult(actualFrame: nil, error: .cannotComplete) }
            var point = target.origin
            if let value = AXValueCreate(.cgPoint, &point) {
                let error = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value)
                if error != .success && firstError == nil { firstError = error }
            }
        }
        return WriteResult(actualFrame: frame(of: window), error: firstError)
    }

    /// Called only by a transition's serial writer with an already verified
    /// handle. Epoch, gesture and deadline checks belong to the writer closure.
    static func writePreparedPosition(_ point: CGPoint, prepared: PreparedWindow) -> Bool {
        var point = point
        guard let value = AXValueCreate(.cgPoint, &point) else { return false }
        return AXUIElementSetAttributeValue(prepared.window.element, kAXPositionAttribute as CFString, value) == .success
    }

    /// One read-only final snapshot; no AX round trips on animation ticks.
    func currentVisibleFrames(_ known: [Window]) -> [Int: CGRect] {
        let visible = visibleWindows()
        var frames: [Int: CGRect] = [:]
        for window in known {
            guard let identity = identities.first(where: { $0.id == window.id }),
                  CFEqual(identity.element, window.element), identity.binding.pid == window.pid,
                  identity.binding.number == window.cgWindowNumber else { continue }
            let matches = visible.filter { $0.number == identity.binding.number && $0.pid == window.pid }
            if matches.count == 1 { frames[window.id] = matches[0].frame }
        }
        return frames
    }

    /// Missing geometry can be an AX timeout, so it is not proof of closure.
    func isDefinitelyClosed(_ window: Window) -> Bool {
        isDefinitelyInvalid(window.element, pid: window.pid)
    }

    private func isDefinitelyInvalid(_ element: AXUIElement, pid: pid_t) -> Bool {
        guard let application = NSRunningApplication(processIdentifier: pid), !application.isTerminated else { return true }
        var role: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role) == .invalidUIElement
    }

    func setFrame(_ frame: CGRect, of window: Window) -> WriteResult {
        guard isTrusted else { return WriteResult(actualFrame: self.frame(of: window.element), error: .apiDisabled) }
        // Verify the bound public CG ID immediately before a write. Hidden or
        // other-Space windows stay pending for restoration rather than moving.
        guard isVisible(window) else { return WriteResult(actualFrame: self.frame(of: window.element), error: .cannotComplete) }
        guard let current = self.frame(of: window.element) else { return WriteResult(actualFrame: nil, error: .cannotComplete) }
        return setPreparedFrame(frame, prepared: PreparedWindow(window: window, frame: current))
    }

    func focus(_ window: Window) -> Bool {
        guard isTrusted, isVisible(window) else { return false }
        NSRunningApplication(processIdentifier: window.pid)?.activate(options: [])
        let raised = AXUIElementPerformAction(window.element, kAXRaiseAction as CFString)
        if isSettable(window.element, kAXFocusedAttribute) {
            _ = AXUIElementSetAttributeValue(window.element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        }
        return raised == .success
    }

    func isManageable(_ element: AXUIElement, screenFrame: CGRect) -> Bool {
        guard let state = state(of: element), state.standard, !state.minimized, !state.modal,
              isSettable(element, kAXPositionAttribute), isSettable(element, kAXSizeAttribute),
              state.frame.width >= 80, state.frame.height >= 60 else { return false }
        // There is no public AX fullscreen-state attribute. Conservatively
        // exclude screen-filling windows, including borderless presentations.
        return !framesClose(state.frame, screenFrame, tolerance: 3)
    }

    func isVisible(_ window: Window) -> Bool {
        var ownerPID: pid_t = 0
        guard AXUIElementGetPid(window.element, &ownerPID) == .success, ownerPID == window.pid,
              let identity = identities.first(where: { $0.id == window.id }),
              CFEqual(identity.element, window.element), identity.binding.pid == window.pid,
              identity.binding.number == window.cgWindowNumber,
              hasLiveWindowRole(identity.element), let bounds = frame(of: window.element) else { return false }
        return PublicWindowIdentityResolver.isVisible(identity.binding, pid: window.pid, frame: bounds, visible: visibleWindows())
    }

    private func hasLiveWindowRole(_ element: AXUIElement) -> Bool {
        value(element, kAXRoleAttribute) as? String == kAXWindowRole
    }

    func observe(_ windows: [Window]) {
        let ids = Set(windows.map(\.id))
        guard ids != observedIDs else { return }
        stopObserving()
        observedIDs = ids
        for (pid, appWindows) in Dictionary(grouping: windows, by: \.pid) {
            var observer: AXObserver?
            let status = AXObserverCreate(pid, { _, _, notification, context in
                guard let context else { return }
                let owner = Unmanaged<PublicWindowAccessibility>.fromOpaque(context).takeUnretainedValue()
                let name = notification as String
                let change: Change = (name == kAXMovedNotification || name == kAXResizedNotification) ? .geometry
                    : name == kAXFocusedWindowChangedNotification ? .focus : .structure
                owner.onChange?(change)
            }, &observer)
            guard status == .success, let observer else { continue }
            let context = Unmanaged.passUnretained(self).toOpaque()
            let app = AXUIElementCreateApplication(pid)
            for name in [kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification] {
                _ = AXObserverAddNotification(observer, app, name as CFString, context)
            }
            for window in appWindows {
                for name in [kAXUIElementDestroyedNotification, kAXMovedNotification, kAXResizedNotification,
                             kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification] {
                    _ = AXObserverAddNotification(observer, window.element, name as CFString, context)
                }
            }
            CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
            observers.append(observer)
        }
    }

    func stopObserving() {
        for observer in observers { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes) }
        observers.removeAll()
        observedIDs.removeAll()
    }

    private func visibleWindows() -> [PublicWindowIdentityResolver.VisibleWindow] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let rows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            guard (row[kCGWindowLayer as String] as? Int) == 0,
                  let pid = row[kCGWindowOwnerPID as String] as? Int32,
                  let number = row[kCGWindowNumber as String] as? UInt32,
                  let dictionary = row[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: dictionary as CFDictionary),
                  bounds.width > 0, bounds.height > 0 else { return nil }
            return PublicWindowIdentityResolver.VisibleWindow(number: number, pid: pid, frame: bounds)
        }
    }

    private func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success else { return nil }
        return result
    }

    private func values(_ element: AXUIElement, _ attributes: [String]) -> [CFTypeRef]? {
        var result: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(element, attributes as CFArray,
            AXCopyMultipleAttributeOptions(rawValue: 0), &result) == .success else { return nil }
        return result as? [CFTypeRef]
    }

    private func axElement(_ value: CFTypeRef?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    private func isSettable(_ element: AXUIElement, _ attribute: String) -> Bool {
        var result = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, attribute as CFString, &result) == .success && result.boolValue
    }

    private func framesClose(_ a: CGRect, _ b: CGRect, tolerance: CGFloat) -> Bool {
        abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance
            && abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
    }

    deinit { stopObserving() }
}
