import AppKit

struct MacarchyWallpaperDisplay: Equatable, Sendable {
    let id: String
    let name: String
}

struct MacarchyDesktopImageState: Codable, Equatable, Sendable {
    let url: URL
    var scaling: UInt = NSImageScaling.scaleProportionallyUpOrDown.rawValue
    var clipping: Bool = true
    var fill: [Double] = [0, 0, 0]
}

@MainActor
protocol MacarchyWallpaperBackend {
    func displays() -> [MacarchyWallpaperDisplay]
    func state(for displayID: String) throws -> MacarchyDesktopImageState
    func set(_ state: MacarchyDesktopImageState, on displayID: String) throws
}

@MainActor
struct MacarchySystemWallpaperBackend: MacarchyWallpaperBackend {
    private func identity(_ screen: NSScreen) -> String {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return screen.localizedName
        }
        if let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue() {
            return CFUUIDCreateString(nil, uuid) as String
        }
        return "display-\(number.uint32Value)"
    }

    func displays() -> [MacarchyWallpaperDisplay] {
        NSScreen.screens.map { MacarchyWallpaperDisplay(id: identity($0), name: $0.localizedName) }
    }

    private func screen(_ id: String) throws -> NSScreen {
        guard let screen = NSScreen.screens.first(where: { identity($0) == id }) else {
            throw MacarchyAppearanceError("A display disconnected. Reconnect it before restoring its wallpaper.")
        }
        return screen
    }

    func state(for displayID: String) throws -> MacarchyDesktopImageState {
        let screen = try screen(displayID)
        guard let url = NSWorkspace.shared.desktopImageURL(for: screen), url.isFileURL else {
            throw MacarchyAppearanceError("The current wallpaper for \(screen.localizedName) could not be saved. Nothing was changed.")
        }
        let options = NSWorkspace.shared.desktopImageOptions(for: screen) ?? [:]
        let color = (options[.fillColor] as? NSColor)?.usingColorSpace(.deviceRGB)
            ?? NSColor(deviceRed: 0, green: 0, blue: 0, alpha: 1)
        return MacarchyDesktopImageState(url: url,
            scaling: (options[.imageScaling] as? NSNumber)?.uintValue ?? NSImageScaling.scaleProportionallyUpOrDown.rawValue,
            clipping: (options[.allowClipping] as? NSNumber)?.boolValue ?? false,
            fill: [Double(color.redComponent), Double(color.greenComponent), Double(color.blueComponent)])
    }

    func set(_ state: MacarchyDesktopImageState, on displayID: String) throws {
        let screen = try screen(displayID)
        let fill = state.fill.count == 3 ? state.fill : [0, 0, 0]
        try NSWorkspace.shared.setDesktopImageURL(state.url, for: screen, options: [
            .imageScaling: NSNumber(value: state.scaling), .allowClipping: NSNumber(value: state.clipping),
            .fillColor: NSColor(deviceRed: fill[0], green: fill[1], blue: fill[2], alpha: 1)
        ])
    }
}

struct MacarchyWallpaperChange: Codable, Sendable {
    let displayID: String
    let displayName: String
    let before: MacarchyDesktopImageState
    let after: MacarchyDesktopImageState
}

/// The OS has no wallpaper transaction API. Snapshot every target before the
/// first write and roll back all attempted writes if any target rejects one.
@MainActor
final class MacarchyWallpaperTransaction: ObservableObject {
    @Published private(set) var canRestore = false
    private let backend: any MacarchyWallpaperBackend
    private let journalURL: URL?
    private var lastChange: [MacarchyWallpaperChange] = []

    init(backend: (any MacarchyWallpaperBackend)? = nil,
         journalURL: URL? = MacarchyAppearancePaths.support.appendingPathComponent("last-wallpaper-change.json")) {
        self.backend = backend ?? MacarchySystemWallpaperBackend()
        self.journalURL = journalURL
        if let journalURL, let data = try? Data(contentsOf: journalURL),
           let saved = try? JSONDecoder().decode([MacarchyWallpaperChange].self, from: data),
           saved.allSatisfy({ $0.before.url.isFileURL && $0.after.url.isFileURL }) {
            lastChange = saved
            canRestore = !saved.isEmpty
        }
    }

    func apply(_ imageURL: URL) throws -> Int {
        guard imageURL.isFileURL, FileManager.default.isReadableFile(atPath: imageURL.path) else {
            throw MacarchyAppearanceError("The selected wallpaper file is unavailable.")
        }
        let displays = backend.displays()
        guard !displays.isEmpty else { throw MacarchyAppearanceError("No connected displays were found.") }
        guard Set(displays.map(\.id)).count == displays.count else {
            throw MacarchyAppearanceError("The connected displays could not be identified uniquely. Nothing was changed.")
        }
        let changes = try displays.map { display in
            MacarchyWallpaperChange(displayID: display.id, displayName: display.name,
                before: try backend.state(for: display.id), after: MacarchyDesktopImageState(url: imageURL))
        }
        if changes.allSatisfy({ $0.before == $0.after }) { return changes.count }
        let previous = lastChange
        try save(changes) // Persist the recovery record before the first system write.
        do {
            try commit(changes)
        } catch let failure as TransactionFailure {
            let recovery = failure.rollbackFailures.isEmpty ? previous : failure.recovery
            do { try save(recovery) }
            catch {
                lastChange = recovery; canRestore = !recovery.isEmpty
                throw MacarchyAppearanceError("\(failure.localizedDescription) The recovery record could not be updated on disk: \(error.localizedDescription)")
            }
            throw MacarchyAppearanceError(failure.localizedDescription)
        }
        return changes.count
    }

    func restore() throws -> Int {
        guard !lastChange.isEmpty else { throw MacarchyAppearanceError("There is no Macoma wallpaper change to restore.") }
        let saved = lastChange
        let currentIDs = Set(backend.displays().map(\.id))
        for change in saved {
            guard currentIDs.contains(change.displayID) else {
                throw MacarchyAppearanceError("Reconnect \(change.displayName) before restoring. Nothing was changed.")
            }
            let current = try backend.state(for: change.displayID)
            guard current.url.resolvingSymlinksInPath() == change.after.url.resolvingSymlinksInPath(),
                  current.scaling == change.after.scaling, current.clipping == change.after.clipping,
                  current.fill.count == change.after.fill.count,
                  zip(current.fill, change.after.fill).allSatisfy({ abs($0.0 - $0.1) < 0.000001 }) else {
                throw MacarchyAppearanceError("The wallpaper on \(change.displayName) changed outside Macoma. Restore was stopped to preserve that change.")
            }
        }
        let inverse = saved.map {
            MacarchyWallpaperChange(displayID: $0.displayID, displayName: $0.displayName, before: $0.after, after: $0.before)
        }
        do { try commit(inverse) }
        catch let failure as TransactionFailure {
            if !failure.rollbackFailures.isEmpty {
                // Some targets may already have reached their original image.
                // Keep only targets that still need the user's requested restore.
                let remaining = saved.compactMap { change -> MacarchyWallpaperChange? in
                    guard let current = try? backend.state(for: change.displayID) else { return change }
                    if current == change.before { return nil }
                    return MacarchyWallpaperChange(displayID: change.displayID, displayName: change.displayName,
                                                   before: change.before, after: current)
                }
                do { try save(remaining) }
                catch {
                    lastChange = remaining; canRestore = !remaining.isEmpty
                    throw MacarchyAppearanceError("\(failure.localizedDescription) The recovery record could not be updated on disk: \(error.localizedDescription)")
                }
            }
            throw MacarchyAppearanceError(failure.localizedDescription)
        }
        do { try save([]) }
        catch {
            lastChange = []; canRestore = false
            throw MacarchyAppearanceError("The previous wallpapers were restored, but the recovery record could not be cleared: \(error.localizedDescription)")
        }
        return saved.count
    }

    private struct TransactionFailure: LocalizedError {
        let cause: String
        let rollbackFailures: [String]
        let recovery: [MacarchyWallpaperChange]
        var errorDescription: String? {
            rollbackFailures.isEmpty
                ? "Wallpaper change failed: \(cause) All attempted displays were restored."
                : "Wallpaper change failed: \(cause) Rollback also failed for \(rollbackFailures.joined(separator: ", ")). The recovery record was kept."
        }
    }

    private func commit(_ changes: [MacarchyWallpaperChange]) throws {
        var attempted: [MacarchyWallpaperChange] = []
        do {
            for change in changes {
                attempted.append(change) // Include a failing API call that may have changed its target.
                try backend.set(change.after, on: change.displayID)
            }
        } catch {
            let cause = error.localizedDescription
            var failures: [String] = []
            var recovery: [MacarchyWallpaperChange] = []
            for change in attempted.reversed() {
                do { try backend.set(change.before, on: change.displayID) }
                catch {
                    failures.append(change.displayName)
                    recovery.append(MacarchyWallpaperChange(displayID: change.displayID, displayName: change.displayName,
                        before: change.before, after: (try? backend.state(for: change.displayID)) ?? change.after))
                }
            }
            throw TransactionFailure(cause: cause, rollbackFailures: failures, recovery: recovery)
        }
    }

    private func save(_ changes: [MacarchyWallpaperChange]) throws {
        if let journalURL {
            try FileManager.default.createDirectory(at: journalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(changes).write(to: journalURL, options: .atomic)
        }
        lastChange = changes
        canRestore = !changes.isEmpty
    }
}
