import AppKit
import Foundation
import ScreenSaver

extension Notification.Name {
    static let omacyConfigDidChange = Notification.Name("omacy.configDidChange")
}

enum OmacyStore {
    static let forceCanaryKey = "macarchy.forceCanary"
    static var resourceBundle: Bundle {
        get { MacarchyResources.bundle }
        set { MacarchyResources.bundle = newValue }
    }
    private static let repository = OmacyConfigRepository(paths: .live(), bundledArt: { bundledArt })
    static private(set) var lastLoadError: String?

    static var settingsURL: URL? { repository.paths.settingsURL }
    static var artURL: URL? { repository.paths.artURL }

    static var bundledArt: String {
        if let url = resourceBundle.url(forResource: "screensaver", withExtension: "txt"),
           let text = try? String(contentsOf: url, encoding: .utf8) {
            return text
        }
        return "MACARCHY"
    }

    static var bundledFontURL: URL? {
        resourceBundle.url(forResource: "FairfaxHD", withExtension: "ttf")
            ?? resourceBundle.url(forResource: "Fairfax", withExtension: "ttf")
    }

    static func loadConfiguration() -> OmacyConfigSnapshot {
        let snapshot = repository.load()
        // Recent macOS releases isolate legacy savers. ScreenSaverDefaults is
        // the public configuration channel when the host cannot read our files.
        let hasReadablePublicFile = [settingsURL, artURL].compactMap { $0 }.contains {
            FileManager.default.isReadableFile(atPath: $0.path)
        }
        if !hasReadablePublicFile, snapshot.origin != .publicConfiguration,
           let defaults = ScreenSaverDefaults(forModuleWithName: "dev.theboring.macarchy.screensaver") {
            defaults.synchronize()
            if let data = defaults.data(forKey: "configuration"),
               let settings = OmacySettingsCodec.decodeValidated(data),
               let art = defaults.string(forKey: "art"), OmacyArtSchema.isValid(art) {
                lastLoadError = nil
                return OmacyConfigSnapshot(settings: settings, art: art, diagnostic: nil)
            }
        }
        lastLoadError = snapshot.diagnostic
        return snapshot
    }

    static func decodeSettings(
        _ data: Data,
        lastGood: OmacySettings
    ) -> (settings: OmacySettings, error: String?) {
        OmacySettingsCodec.decode(data, lastGood: lastGood)
    }

    static func save(settings: OmacySettings, art: String) throws {
        do {
            try repository.save(settings: settings, art: art)
            if let defaults = ScreenSaverDefaults(forModuleWithName: "dev.theboring.macarchy.screensaver") {
                var normalized = settings
                normalized.syncEngineEffect()
                defaults.set(try OmacySettingsCodec.encode(normalized), forKey: "configuration")
                defaults.set(art, forKey: "art")
                defaults.synchronize()
            }
            lastLoadError = nil
            NotificationCenter.default.post(name: .omacyConfigDidChange, object: nil)
        } catch {
            lastLoadError = error.localizedDescription
            throw error
        }
    }

    @discardableResult
    static func performHostMigrationIfNeeded(
        defaults: () throws -> OmacyLegacyConfiguration?,
        files: () throws -> OmacyLegacyConfiguration?
    ) throws -> OmacyMigrationResult {
        try repository.migrateIfNeeded(defaults: defaults, files: files)
    }

    static func retryHostMigration() { repository.retryMigration() }

    static func restoreDefaultArt() throws {
        let current = loadConfiguration()
        try save(settings: current.settings, art: bundledArt)
    }

    static func resetToDefaults() throws {
        try save(settings: OmacySettings(), art: bundledArt)
    }

    static var forceCanary: Bool { UserDefaults.standard.bool(forKey: forceCanaryKey) }
}
