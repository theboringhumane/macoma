import Foundation

struct MacarchyTheme: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let name: String
    let background: String
    let foreground: String
    let accent: String
    /// ANSI colors 0...15, using Omarchy's semantic palette mapping.
    let palette: [String]
    var selectionBackground: String? = nil
    var selectionForeground: String? = nil
    var cursor: String? = nil

    var isValid: Bool {
        !id.isEmpty && !name.isEmpty && palette.count == 16 &&
        ([background, foreground, accent] + palette + [selectionBackground, selectionForeground, cursor].compactMap { $0 }).allSatisfy(Self.isHexColor)
    }

    static func isHexColor(_ value: String) -> Bool {
        value.count == 7 && value.first == "#" &&
        value.dropFirst().allSatisfy { $0.isASCII && $0.isHexDigit }
    }
}

enum MacarchyThemeCatalog {
    static let upstreamRevision = "77bfaca408d2993018d928e72cf84561480e5188"

    static func load() -> [MacarchyTheme] {
        guard let url = resource("themes"),
              let data = try? Data(contentsOf: url),
              let themes = try? JSONDecoder().decode([MacarchyTheme].self, from: data),
              !themes.isEmpty, themes.allSatisfy(\.isValid),
              Set(themes.map(\.id)).count == themes.count else { return [fallback] }
        return themes
    }

    static let fallback = MacarchyTheme(
        id: "tokyo-night", name: "Tokyo Night", background: "#1a1b26",
        foreground: "#a9b1d6", accent: "#7aa2f7",
        palette: ["#1a1b26", "#f7768e", "#9ece6a", "#e0af68", "#7aa2f7", "#ad8ee6",
                  "#449dab", "#a9b1d6", "#414868", "#ff7a93", "#b9f27c", "#ff9e64",
                  "#7da6ff", "#bb9af7", "#0db9d7", "#c0caf5"],
        selectionBackground: "#292e42", selectionForeground: "#c0caf5", cursor: "#c0caf5")

    static func resource(_ name: String) -> URL? {
        Bundle.main.url(forResource: name, withExtension: "json", subdirectory: "Desktop")
    }
}

struct MacarchyWallpaper: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let themeID: String
    let name: String
    let path: String
    let url: URL
    let bytes: Int
    let gitBlobSHA: String
    let width: Int
    let height: Int

    var sourceURL: URL {
        URL(string: "https://github.com/omacom/omarchy/blob/\(MacarchyThemeCatalog.upstreamRevision)/\(path)")!
    }

    var isValid: Bool {
        let expected = "https://raw.githubusercontent.com/omacom/omarchy/\(MacarchyThemeCatalog.upstreamRevision)/\(path)"
        return !id.isEmpty && path.hasPrefix("themes/\(themeID)/backgrounds/") &&
            !path.split(separator: "/").contains("..") && url.absoluteString == expected &&
            bytes > 0 && bytes <= MacarchyWallpaperCache.maximumDownloadBytes &&
            gitBlobSHA.count == 40 && gitBlobSHA.allSatisfy { $0.isASCII && $0.isHexDigit } &&
            width > 0 && height > 0 && Int64(width) * Int64(height) <= 80_000_000
    }
}

enum MacarchyWallpaperCatalog {
    static func load() -> [MacarchyWallpaper] {
        guard let url = MacarchyThemeCatalog.resource("wallpapers"),
              let data = try? Data(contentsOf: url),
              let entries = try? JSONDecoder().decode([MacarchyWallpaper].self, from: data),
              entries.allSatisfy(\.isValid), Set(entries.map(\.id)).count == entries.count else { return [] }
        return entries
    }
}

enum MacarchyAppearancePaths {
    static var support: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Macarchy/Appearance", isDirectory: true)
    }
    static var cache: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Macarchy/Wallpapers", isDirectory: true)
    }
}

struct MacarchyAppearanceError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}
