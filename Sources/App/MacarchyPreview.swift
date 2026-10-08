import AppKit
import SwiftUI

struct MacarchyPreview: NSViewRepresentable {
    var content: OmacyPinnedContent
    var revision = 0
    var onFailure: (() -> Void)?

    func makeNSView(context: Context) -> MacarchyRenderView {
        let view = MacarchyRenderView(frame: .zero)
        view.onFailure = onFailure
        view.setContent(content, revision: revision)
        return view
    }

    func updateNSView(_ nsView: MacarchyRenderView, context: Context) {
        nsView.onFailure = onFailure
        nsView.setContent(content, revision: revision)
    }

    static func dismantleNSView(_ nsView: MacarchyRenderView, coordinator: ()) { nsView.shutdown() }
}

@MainActor
final class MacarchyRenderView: NSView {
    private let renderer = OmacyRenderer()
    private var content: OmacyPinnedContent?
    private var revision = 0
    private var started = false
    private var failed = false
    var onFailure: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        renderer.appliesGeometryLive = true
        renderer.onEngineUnavailable = { [weak self] in self?.reportFailure() }
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Live screensaver preview")
    }

    required init?(coder: NSCoder) { fatalError("Use init(frame:)") }
    override var isOpaque: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self)
        guard let window else { shutdown(); return }
        NotificationCenter.default.addObserver(self, selector: #selector(screenChanged), name: NSWindow.didChangeScreenNotification, object: window)
        NotificationCenter.default.addObserver(self, selector: #selector(visibilityChanged), name: NSWindow.didChangeOcclusionStateNotification, object: window)
        NotificationCenter.default.addObserver(self, selector: #selector(windowWillClose), name: NSWindow.willCloseNotification, object: window)
        startIfReady()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        renderer.updateGeometry()
        renderer.retargetDisplayLink()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        startIfReady()
        if started { renderer.updateGeometry() }
    }

    override func layout() {
        super.layout()
        startIfReady()
        if started { renderer.updateGeometry() }
    }

    func setContent(_ value: OmacyPinnedContent, revision: Int) {
        let shouldRestart = self.revision != revision
        self.revision = revision
        if shouldRestart { shutdown(); failed = false }
        guard content != value || shouldRestart else { return }
        if failed { failed = false }
        content = value
        setAccessibilityLabel("Live \(value.effect) screensaver preview")
        if started { renderer.pin(value) }
        else { renderer.pinnedContent = value; startIfReady() }
    }

    private func startIfReady() {
        guard !started, !failed, content != nil, let window,
              window.occlusionState.contains(.visible), bounds.width >= 32, bounds.height >= 32 else { return }
        renderer.pinnedContent = content
        switch renderer.attach(to: self, isPreview: true) {
        case .engine:
            started = true
            renderer.start()
        case .canary:
            reportFailure()
        }
    }

    func shutdown() {
        renderer.stop()
        started = false
    }

    private func reportFailure() {
        shutdown()
        failed = true
        DispatchQueue.main.async { [weak self] in self?.onFailure?() }
    }

    @objc private func screenChanged() {
        renderer.updateGeometry()
        renderer.retargetDisplayLink()
    }

    @objc private func visibilityChanged() {
        if window?.occlusionState.contains(.visible) == true { startIfReady() }
        else { shutdown() }
    }

    @objc private func windowWillClose() { shutdown() }

    deinit { NotificationCenter.default.removeObserver(self) }
}
