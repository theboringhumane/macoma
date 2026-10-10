import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class MacarchyModel: ObservableObject {
    let effects = MacarchyEffect.all
    @Published var settings: OmacySettings
    @Published var art: String {
        didSet { if OmacyArtSchema.isValid(art) { previewArt = art } }
    }
    @Published private(set) var previewArt: String
    @Published var selectedEffect: String
    @Published var search = ""
    @Published var showingArtwork = false
    @Published var message: String?
    @Published var errorMessage: String?
    @Published var isInstalled = false
    @Published var previewFailure = false
    @Published var previewRevision = 0
    @Published private(set) var importedImageName: String?

    private var importedImage: Data?
    private var savedSettings: OmacySettings
    private var savedArt: String
    let fullscreen = MacarchyFullscreenController()

    init() {
        let snapshot = OmacyStore.loadConfiguration()
        settings = snapshot.settings
        art = snapshot.art
        previewArt = snapshot.art
        savedSettings = snapshot.settings
        savedArt = snapshot.art
        selectedEffect = snapshot.settings.effects.count == 1 ? snapshot.settings.effects[0] : "matrix"
        errorMessage = snapshot.diagnostic
        refreshInstallation()
    }

    var filteredEffects: [MacarchyEffect] {
        guard !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return effects }
        return effects.filter {
            $0.name.localizedCaseInsensitiveContains(search)
                || $0.family.localizedCaseInsensitiveContains(search)
                || $0.origin.rawValue.localizedCaseInsensitiveContains(search)
        }
    }

    var currentEffect: MacarchyEffect { effects.first { $0.id == selectedEffect } ?? effects[0] }
    var hasChanges: Bool { normalizedSettings != savedSettings || art != savedArt }
    var artError: String? { OmacyArtSchema.validationError(for: art) }
    var artDimensions: String {
        let grid = OmacyLayout.artGrid(art)
        return "\(grid.cols) columns · \(grid.rows) lines"
    }
    var canReconvert: Bool { importedImage != nil }
    var rotationDescription: String {
        settings.effects.count == 1 ? "Repeating one effect" : "Shuffling \(settings.effects.count) effects"
    }
    var previewContent: OmacyPinnedContent {
        OmacyPinnedContent(art: previewArt, effect: selectedEffect, background: settings.background, fontSize: settings.fontSize)
    }
    var backgroundColor: Color {
        get {
            let rgba = settings.backgroundRGBA
            return Color(red: Double(rgba.0) / 255, green: Double(rgba.1) / 255, blue: Double(rgba.2) / 255)
        }
        set {
            guard let color = NSColor(newValue).usingColorSpace(.deviceRGB) else { return }
            settings.background = String(format: "#%02X%02X%02X", Int((color.redComponent * 255).rounded()),
                                         Int((color.greenComponent * 255).rounded()), Int((color.blueComponent * 255).rounded()))
        }
    }

    private var normalizedSettings: OmacySettings {
        var result = settings
        result.syncEngineEffect()
        return result
    }

    func isIncluded(_ name: String) -> Bool { settings.effects.contains(name) }

    func setIncluded(_ name: String, included: Bool) {
        if included {
            if !isIncluded(name) { settings.effects.append(name) }
        } else if settings.effects.count > 1 {
            settings.effects.removeAll { $0 == name }
        }
        settings.syncEngineEffect()
        message = nil
    }

    func useAllEffects() { settings.effects = OmacyEffects.names; settings.syncEngineEffect(); message = nil }
    func useOnlySelected() { settings.effects = [selectedEffect]; settings.syncEngineEffect(); message = nil }
    func refreshInstallation() { isInstalled = MacarchyInstallation.isInstalled }

    @discardableResult
    func save() -> Bool {
        if let artError { errorMessage = artError; return false }
        do {
            let value = normalizedSettings
            try OmacyStore.save(settings: value, art: art)
            settings = value
            savedSettings = value
            savedArt = art
            message = "Saved. Your screensaver will use these settings."
            errorMessage = nil
            return true
        } catch {
            errorMessage = "Could not save settings: \(error.localizedDescription)"
            return false
        }
    }

    func reset() {
        settings = OmacySettings()
        art = OmacyStore.bundledArt
        selectedEffect = "matrix"
        importedImage = nil
        importedImageName = nil
        message = "Defaults restored in the editor. Apply to save."
        errorMessage = nil
    }

    func restoreArtwork() {
        art = OmacyStore.bundledArt
        importedImage = nil
        importedImageName = nil
    }

    func installScreensaver() {
        guard save() else { return }
        do {
            try MacarchyInstallation.install()
            refreshInstallation()
            message = "Installed. Select Macoma in System Settings → Screen Saver."
        } catch {
            errorMessage = "Could not install the screensaver: \(error.localizedDescription)"
        }
    }

    func openSettings() { MacarchyInstallation.openSettings() }

    func showFullscreen() {
        fullscreen.show(content: previewContent)
    }

    func restartPreview() {
        previewFailure = false
        previewRevision += 1
    }

    func importArtwork() {
        let panel = NSOpenPanel()
        panel.title = "Import artwork"
        panel.message = "Choose a PNG, SVG, or text file. Images become an 80 × 26 character canvas."
        panel.allowedContentTypes = [.png, .svg, .plainText]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let attributes = try url.resourceValues(forKeys: [.fileSizeKey])
            guard (attributes.fileSize ?? 0) <= 8 * 1024 * 1024 else {
                errorMessage = "Choose an image or text file smaller than 8 MB."
                return
            }
            let data = try Data(contentsOf: url)
            if ["txt", "text", "asc"].contains(url.pathExtension.lowercased()) {
                guard let text = String(data: data, encoding: .utf8) else {
                    errorMessage = "The text file must use UTF-8 encoding."
                    return
                }
                guard let error = OmacyArtSchema.validationError(for: text) else {
                    art = text
                    importedImage = nil
                    importedImageName = nil
                    return
                }
                errorMessage = error
            } else {
                let converted = try OmacyAsciiConverter.convert(data, settings: settings)
                if let error = OmacyArtSchema.validationError(for: converted) { errorMessage = error; return }
                art = converted
                importedImage = data
                importedImageName = url.lastPathComponent
            }
        } catch { errorMessage = "Could not import artwork: \(error.localizedDescription)" }
    }

    func reconvertArtwork() {
        guard let importedImage else { return }
        do { art = try OmacyAsciiConverter.convert(importedImage, settings: settings) }
        catch { errorMessage = error.localizedDescription }
    }
}
