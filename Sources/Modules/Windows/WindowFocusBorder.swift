import AppKit

final class WindowFocusBorder {
    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    private var panel: Panel?

    func show(axFrame: CGRect, color: NSColor, primaryScreenHeight: CGFloat) {
        let panel: Panel
        if let existing = self.panel { panel = existing }
        else {
            panel = Panel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.ignoresMouseEvents = true
            panel.hidesOnDeactivate = false
            panel.level = .floating
            panel.collectionBehavior = [.transient, .ignoresCycle, .moveToActiveSpace]
            let view = NSView()
            view.wantsLayer = true
            view.layer?.borderWidth = 2
            view.layer?.cornerRadius = 9
            panel.contentView = view
            self.panel = panel
        }
        let frame = CGRect(x: axFrame.minX - 2, y: primaryScreenHeight - axFrame.maxY - 2,
                           width: axFrame.width + 4, height: axFrame.height + 4)
        panel.setFrame(frame, display: true)
        panel.contentView?.layer?.borderColor = color.cgColor
        panel.orderFrontRegardless()
    }

    func hide() { panel?.orderOut(nil) }
    deinit { panel?.orderOut(nil) }
}
