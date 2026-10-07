import AppKit

@MainActor
enum MacarchyInstallation {
    static let saverBundleIdentifier = "dev.theboring.macarchy.screensaver"

    static var installedURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Screen Savers/Macarchy.saver", isDirectory: true)
    }

    static var isInstalled: Bool {
        guard let bundle = Bundle(url: installedURL),
              bundle.bundleIdentifier == saverBundleIdentifier,
              let executable = bundle.executableURL else { return false }
        return FileManager.default.isExecutableFile(atPath: executable.path)
    }

    static func install() throws {
        guard let resourceURL = Bundle.main.resourceURL else { throw InstallError.missingBundle }
        let source = resourceURL.appendingPathComponent("Macarchy.saver", isDirectory: true)
        guard let bundle = Bundle(url: source), bundle.bundleIdentifier == saverBundleIdentifier,
              let executable = bundle.executableURL,
              FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw InstallError.missingBundle
        }
        let manager = FileManager.default
        let parent = installedURL.deletingLastPathComponent()
        try manager.createDirectory(at: parent, withIntermediateDirectories: true)
        let staging = parent.appendingPathComponent(".Macarchy-\(UUID().uuidString).saver")
        defer { try? manager.removeItem(at: staging) }
        try manager.copyItem(at: source, to: staging)
        if manager.fileExists(atPath: installedURL.path) {
            guard Bundle(url: installedURL)?.bundleIdentifier == saverBundleIdentifier else {
                throw InstallError.nameConflict
            }
            let backups = manager.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/Macarchy/Backups", isDirectory: true)
            try manager.createDirectory(at: backups, withIntermediateDirectories: true)
            let backup = backups.appendingPathComponent("Macarchy-\(UUID().uuidString).saver")
            try manager.moveItem(at: installedURL, to: backup)
            do {
                try manager.moveItem(at: staging, to: installedURL)
            } catch {
                do {
                    try manager.moveItem(at: backup, to: installedURL)
                } catch let rollbackError {
                    throw InstallError.rollback(backup, rollbackError.localizedDescription)
                }
                throw error
            }
        } else {
            try manager.moveItem(at: staging, to: installedURL)
        }
    }

    static func openSettings() {
        // Tahoe moved the screensaver selector into Wallpaper settings.
        let pane: String
        if #available(macOS 26.0, *) {
            pane = "com.apple.Wallpaper-Settings.extension"
        } else {
            pane = "com.apple.ScreenSaver-Settings.extension"
        }
        guard let url = URL(string: "x-apple.systempreferences:\(pane)") else { return }
        NSWorkspace.shared.open(url)
    }

    private enum InstallError: LocalizedError {
        case missingBundle, nameConflict, rollback(URL, String)
        var errorDescription: String? {
            switch self {
            case .missingBundle:
                return "The screensaver is missing from this app. Rebuild or reinstall Macarchy."
            case .nameConflict:
                return "Another screensaver is already named Macarchy.saver. Move it before installing."
            case .rollback(let backup, let detail):
                return "Installation stopped and the previous screensaver could not be restored. Your backup is at \(backup.path). \(detail)"
            }
        }
    }
}
