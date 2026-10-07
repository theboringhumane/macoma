import AppKit

/// Uses the documented configureSheet API. Opening settings is an explicit
/// button action; merely opening the sheet does not launch another app.
@MainActor
final class MacarchySaverConfiguration: NSWindowController {
    private let statusLabel = NSTextField(wrappingLabelWithString: "Choose animations, artwork, and colors in the Macarchy app.")

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 180), styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Macarchy Screen Saver"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 180))
        window.contentView = container
        let title = NSTextField(labelWithString: "Make it yours.")
        title.font = .systemFont(ofSize: 21, weight: .semibold)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: 13)
        statusLabel.maximumNumberOfLines = 3
        let open = NSButton(title: "Open Macarchy", target: self, action: #selector(openCompanion))
        open.bezelStyle = .rounded
        let done = NSButton(title: "Done", target: self, action: #selector(closeSheet))
        done.bezelStyle = .rounded
        done.keyEquivalent = "\r"
        for view in [title, statusLabel, open, done] {
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
        }
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: container.topAnchor, constant: 24),
            title.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 24),
            statusLabel.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 12),
            statusLabel.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -24),
            open.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            open.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -20),
            done.trailingAnchor.constraint(equalTo: statusLabel.trailingAnchor),
            done.bottomAnchor.constraint(equalTo: open.bottomAnchor),
            done.widthAnchor.constraint(greaterThanOrEqualToConstant: 70)
        ])
    }

    required init?(coder: NSCoder) { nil }

    @objc private func openCompanion() {
        let bundle = Bundle(for: MacarchySaverView.self)
        let identifier = bundle.object(forInfoDictionaryKey: "MacarchyCompanionBundleIdentifier") as? String ?? "dev.theboring.macarchy"
        let candidates = [
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier),
            URL(fileURLWithPath: "/Applications/Macarchy.app"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Macarchy.app"),
            bundle.bundleURL.deletingLastPathComponent().appendingPathComponent("Macarchy.app")
        ]
        guard let app = candidates.compactMap({ $0 }).first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            statusLabel.stringValue = "Open Macarchy.app from your download, or move it into Applications first."
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        statusLabel.stringValue = "Opening Macarchy…"
        NSWorkspace.shared.openApplication(at: app, configuration: configuration) { [weak self] application, error in
            Task { @MainActor in
                self?.statusLabel.stringValue = application != nil
                    ? "Macarchy is open. Save your changes there, then close this sheet."
                    : "Could not open Macarchy: \(error?.localizedDescription ?? "launch failed")."
            }
        }
    }

    @objc private func closeSheet() {
        guard let window else { return }
        if let parent = window.sheetParent { parent.endSheet(window) }
        else { window.orderOut(nil) }
    }
}
