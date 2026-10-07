import AppKit
import QuartzCore
import ScreenSaver

/// The public ScreenSaver framework entry point for Macarchy.saver.
@MainActor
@objc(MacarchySaverView)
public final class MacarchySaverView: ScreenSaverView {
    private let renderer = OmacyRenderer()
    private var software: MacarchySoftwareRenderer?
    private var backend: Backend = .stopped
    private var animationRequested = false
    private var startRequestedAt: CFTimeInterval = 0
    private var observing = false
    private var systemSleeping = false
    private var displaysSleeping = false
    private var softwareUsesPreview = false
    private var settingsController: MacarchySaverConfiguration?

    public override init?(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview)
        prepareView()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        prepareView()
    }

    private func prepareView() {
        OmacyStore.resourceBundle = Bundle(for: MacarchySaverView.self)
        animationTimeInterval = 1.0 / 30.0
        autoresizingMask = [.width, .height]
        renderer.onEngineUnavailable = { [weak self] in self?.startSoftware() }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        // AppKit normally releases its views on the main thread. Preserve that
        // requirement for the Rust session even if a host releases us elsewhere.
        let renderer = renderer
        let software = software
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                renderer.stop()
                software?.stop()
            }
        } else {
            Task { @MainActor in
                renderer.stop()
                software?.stop()
            }
        }
    }

    public override var isOpaque: Bool { true }

    public override func startAnimation() {
        super.startAnimation()
        guard !animationRequested else { return }
        animationRequested = true
        systemSleeping = false
        displaysSleeping = false
        startRequestedAt = CACurrentMediaTime()
        observeHost()
        attemptStart()
    }

    public override func stopAnimation() {
        animationRequested = false
        systemSleeping = false
        displaysSleeping = false
        stopRendering()
        removeHostObservers()
        super.stopAnimation()
    }

    public override func animateOneFrame() {
        guard animationRequested, !systemSleeping, !displaysSleeping else { return }
        attemptStart()
        if backend == .software {
            software?.advance()
            needsDisplay = true
        }
    }

    public override func draw(_ dirtyRect: NSRect) {
        if backend == .software, let software {
            software.draw(in: bounds)
        } else if backend == .stopped {
            NSColor.black.setFill()
            dirtyRect.fill()
        }
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeHostObservers()
        // A display link must never survive removal from its window.
        stopRendering()
        if window != nil, animationRequested {
            systemSleeping = false
            displaysSleeping = false
            startRequestedAt = CACurrentMediaTime()
            observeHost()
            attemptStart()
        }
    }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateGeometry(retarget: true)
    }

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateGeometry(retarget: false)
    }

    public override func layout() {
        super.layout()
        updateGeometry(retarget: false)
    }

    public override var hasConfigureSheet: Bool { true }

    public override var configureSheet: NSWindow? {
        if settingsController == nil { settingsController = MacarchySaverConfiguration() }
        return settingsController?.window
    }

    /// Public diagnostics for a host-level smoke test; no configuration writes.
    @objc public var diagnostics: NSDictionary {
        [
            "animationRequested": animationRequested,
            "backend": backend.rawValue,
            "engineActive": backend == .metal ? renderer.usesEngine : (software?.isRunning ?? false),
            "currentEffect": backend == .metal ? renderer.currentEffect : (software?.currentEffect ?? ""),
            "softwareFrameCount": software?.frameCount ?? 0,
            "softwareFrameSignature": software?.frameSignature ?? 0,
            "metalFrameCount": renderer.renderedFrameCount,
            "diagnostic": software?.diagnostic ?? "",
            "sharedDisplaySynchronization": renderer.displayCoordinator != nil,
            "isPreview": isPreview,
            "width": bounds.width,
            "height": bounds.height
        ]
    }

    private var usesSoftwarePreview: Bool {
        if isPreview { return true }
        // Some Settings versions mark a hosted thumbnail as non-preview.
        // Treat a view smaller than half of its own display as embedded.
        guard let screen = window?.screen else { return false }
        return bounds.width < screen.frame.width * 0.5
            && bounds.height < screen.frame.height * 0.5
    }

    private func attemptStart() {
        guard animationRequested, backend == .stopped, window != nil,
              !systemSleeping, !displaysSleeping,
              bounds.width > 1, bounds.height > 1 else { return }
        if usesSoftwarePreview {
            startSoftware()
            return
        }
        // ScreenSaverEngine can place all saver windows on the main screen
        // before moving them to their intended display. Allow that to settle,
        // but keep a bounded fallback for hosts that do not fill their display.
        let settled: Bool
        if let screen = window?.screen {
            settled = abs(bounds.width - screen.frame.width) < 8
                && abs(bounds.height - screen.frame.height) < 8
        } else {
            settled = false
        }
        guard settled || CACurrentMediaTime() - startRequestedAt >= 0.25 else { return }
        // The legacy host can keep several independent full-screen and preview
        // contexts in one process. They do not form a reliable display barrier:
        // a paused host context must never delay another display's next effect.
        // V1 therefore gives each saver view its own continuous effect loop.
        renderer.displayCoordinator = nil
        switch renderer.attach(to: self, isPreview: false) {
        case .engine:
            backend = .metal
            renderer.start()
        case .canary:
            startSoftware()
        }
    }

    private func startSoftware() {
        guard animationRequested, window != nil, !systemSleeping, !displaysSleeping else { return }
        renderer.stop()
        renderer.displayCoordinator = nil
        // Discard a CAMetalLayer before using AppKit's snapshot drawing path.
        wantsLayer = false
        layer = nil
        let next = MacarchySoftwareRenderer()
        softwareUsesPreview = usesSoftwarePreview
        _ = next.start(in: bounds, fitsArt: softwareUsesPreview)
        software?.stop()
        software = next
        backend = .software
        needsDisplay = true
    }

    private func stopRendering() {
        renderer.stop()
        renderer.displayCoordinator = nil
        software?.stop()
        software = nil
        backend = .stopped
    }

    private func updateGeometry(retarget: Bool) {
        guard animationRequested else { return }
        switch backend {
        case .stopped: attemptStart()
        case .software:
            if softwareUsesPreview != usesSoftwarePreview {
                stopRendering()
                attemptStart()
            } else {
                software?.resize(to: bounds)
                needsDisplay = true
            }
        case .metal:
            if usesSoftwarePreview {
                startSoftware()
                return
            }
            renderer.updateGeometry()
            if retarget { renderer.retargetDisplayLink() }
        }
    }

    private func observeHost() {
        guard !observing else { return }
        observing = true
        if let window {
            NotificationCenter.default.addObserver(self, selector: #selector(screenChanged), name: NSWindow.didChangeScreenNotification, object: window)
            NotificationCenter.default.addObserver(self, selector: #selector(hostWindowClosed), name: NSWindow.willCloseNotification, object: window)
        }
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(systemWillSleep), name: NSWorkspace.willSleepNotification, object: nil)
        workspace.addObserver(self, selector: #selector(systemDidWake), name: NSWorkspace.didWakeNotification, object: nil)
        workspace.addObserver(self, selector: #selector(displaysWillSleep), name: NSWorkspace.screensDidSleepNotification, object: nil)
        workspace.addObserver(self, selector: #selector(displaysDidWake), name: NSWorkspace.screensDidWakeNotification, object: nil)
    }

    private func removeHostObservers() {
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        observing = false
    }

    @objc private func screenChanged() { updateGeometry(retarget: true) }
    @objc private func hostWindowClosed() { stopAnimation() }
    @objc private func systemWillSleep() { systemSleeping = true; stopRendering() }
    @objc private func displaysWillSleep() { displaysSleeping = true; stopRendering() }
    @objc private func systemDidWake() { systemSleeping = false; startRequestedAt = CACurrentMediaTime(); attemptStart() }
    @objc private func displaysDidWake() { displaysSleeping = false; startRequestedAt = CACurrentMediaTime(); attemptStart() }

    private enum Backend: String { case stopped, metal, software }
}
