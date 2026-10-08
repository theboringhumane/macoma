import AppKit
import SwiftUI

@MainActor
final class MacarchyFullscreenController: NSObject, NSWindowDelegate {
    private var window: MacarchyPreviewWindow?
    private var renderView: MacarchyRenderView?

    func show(content: OmacyPinnedContent) {
        close()
        guard let screen = NSApp.keyWindow?.screen ?? NSScreen.main else { return }
        let window = MacarchyPreviewWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.title = "Macarchy Preview"
        window.backgroundColor = .black
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        window.delegate = self
        window.onExit = { [weak self] in self?.close() }

        let root = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        let render = MacarchyRenderView(frame: root.bounds)
        render.autoresizingMask = [.width, .height]
        render.setContent(content, revision: 0)
        root.addSubview(render)
        let hint = NSHostingView(rootView:
            Text("Press any key or click to exit preview")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.65))
                .padding(.horizontal, 16).padding(.vertical, 9)
                .background(.black.opacity(0.65), in: Capsule())
                .padding(24)
        )
        hint.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(hint)
        NSLayoutConstraint.activate([
            hint.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            hint.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])
        window.contentView = root
        self.window = window
        renderView = render
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        renderView?.shutdown()
        renderView = nil
        let previous = window
        window = nil
        previous?.orderOut(nil)
        previous?.close()
    }

    func windowWillClose(_ notification: Notification) {
        renderView?.shutdown()
        renderView = nil
        window = nil
    }
}

private final class MacarchyPreviewWindow: NSWindow {
    var onExit: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown || event.type == .leftMouseDown || event.type == .rightMouseDown {
            onExit?()
            return
        }
        super.sendEvent(event)
    }
}
