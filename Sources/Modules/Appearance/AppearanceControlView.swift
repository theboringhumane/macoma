import AppKit
import SwiftUI
import UniformTypeIdentifiers

private struct ImportedWallpaper: Codable, Identifiable {
    let id: String
    let name: String
    let url: URL
}

@MainActor
private final class AppearanceControlModel: ObservableObject {
    let catalog = MacarchyWallpaperCatalog.load()
    let cache = MacarchyWallpaperCache()
    let transaction = MacarchyWallpaperTransaction()
    @Published var thumbnails: [String: NSImage] = [:]
    @Published var imported: [ImportedWallpaper] = []
    @Published var selectedID: String?
    @Published var selectedName = "Choose a wallpaper"
    @Published var selectedURL: URL?
    @Published var selectedSource: URL?
    @Published var isBusy = false
    @Published var message: String?
    @Published var error: String?
    @Published var canRestore = false
    private let importsURL = MacarchyAppearancePaths.support.appendingPathComponent("imported-wallpapers.json")

    init() {
        canRestore = transaction.canRestore
        if let data = try? Data(contentsOf: importsURL),
           let items = try? JSONDecoder().decode([ImportedWallpaper].self, from: data) {
            imported = items.filter { $0.url.isFileURL && FileManager.default.isReadableFile(atPath: $0.url.path) }
        }
    }

    func clearSelection() {
        selectedID = nil; selectedURL = nil; selectedSource = nil
        selectedName = "Choose a wallpaper"
    }

    func select(_ wallpaper: MacarchyWallpaper) async {
        guard !isBusy else { return }
        isBusy = true; error = nil; message = "Downloading \(wallpaper.name)…"
        defer { isBusy = false }
        do {
            let url = try await cache.image(for: wallpaper)
            let image = try await cache.preview(at: url)
            thumbnails[wallpaper.id] = NSImage(cgImage: image, size: .zero)
            selectedID = wallpaper.id; selectedURL = url
            selectedName = wallpaper.name; selectedSource = wallpaper.sourceURL
            message = "Ready to apply. Your desktop has not changed."
        } catch { self.error = error.localizedDescription; message = nil }
    }

    func loadPreviews(_ wallpapers: [MacarchyWallpaper]) async {
        guard !isBusy else { return }
        isBusy = true; error = nil
        defer { isBusy = false }
        do {
            for (index, wallpaper) in wallpapers.enumerated() where thumbnails[wallpaper.id] == nil {
                try Task.checkCancellation()
                message = "Loading preview \(index + 1) of \(wallpapers.count)…"
                let url = try await cache.image(for: wallpaper)
                let image = try await cache.preview(at: url)
                thumbnails[wallpaper.id] = NSImage(cgImage: image, size: .zero)
            }
            message = "Previews are ready. Select a wallpaper to apply."
        } catch { self.error = error.localizedDescription; message = nil }
    }

    func importImage() async {
        let panel = NSOpenPanel()
        panel.title = "Import Wallpaper"
        panel.allowedContentTypes = [.image]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let source = panel.url else { return }
        isBusy = true; error = nil; message = "Preparing imported wallpaper…"
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() }; isBusy = false }
        do {
            let url = try await cache.prepareForDesktop(source)
            let item = ImportedWallpaper(id: url.lastPathComponent, name: source.deletingPathExtension().lastPathComponent, url: url)
            let image = try await cache.preview(at: url)
            var items = imported.filter { $0.id != item.id }
            items.insert(item, at: 0)
            try JSONEncoder().encode(items).write(to: importsURL, options: .atomic)
            imported = items
            thumbnails[item.id] = NSImage(cgImage: image, size: .zero)
            selectedID = item.id; selectedName = item.name; selectedURL = url; selectedSource = nil
            message = "Imported. Your desktop has not changed."
        } catch { self.error = error.localizedDescription; message = nil }
    }

    func selectImported(_ item: ImportedWallpaper) async {
        guard !isBusy else { return }
        do {
            let image = try await cache.preview(at: item.url)
            thumbnails[item.id] = NSImage(cgImage: image, size: .zero)
            selectedID = item.id; selectedName = item.name; selectedURL = item.url; selectedSource = nil
            error = nil; message = "Ready to apply. Your desktop has not changed."
        } catch { self.error = error.localizedDescription }
    }

    func apply() async {
        guard let selectedURL, !isBusy else { return }
        isBusy = true; error = nil; message = "Preparing desktop image…"
        defer { isBusy = false; canRestore = transaction.canRestore }
        do {
            let prepared = try await cache.prepareForDesktop(selectedURL)
            let count = try transaction.apply(prepared)
            message = "Applied to \(count) connected \(count == 1 ? "display" : "displays")."
        } catch { self.error = error.localizedDescription; message = nil }
    }

    func restore() {
        guard !isBusy else { return }
        error = nil
        defer { canRestore = transaction.canRestore }
        do {
            let count = try transaction.restore()
            message = "Restored the previous wallpaper on \(count) \(count == 1 ? "display" : "displays")."
        } catch { self.error = error.localizedDescription; message = nil }
    }
}

struct AppearanceControlView: View {
    let themes: [MacarchyTheme]
    @Binding var selectedThemeID: String
    @StateObject private var model = AppearanceControlModel()

    private var currentTheme: MacarchyTheme {
        themes.first { $0.id == selectedThemeID } ?? themes.first ?? MacarchyThemeCatalog.fallback
    }
    private var wallpapers: [MacarchyWallpaper] { model.catalog.filter { $0.themeID == currentTheme.id } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Appearance").font(.largeTitle.bold())
                    Text("Choose a palette for Macoma. Apply wallpapers separately.").foregroundStyle(.secondary)
                }
                themeGallery
                Divider()
                wallpaperGallery
                if let error = model.error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red).textSelection(.enabled)
                } else if let message = model.message {
                    HStack(spacing: 8) {
                        if model.isBusy { ProgressView().controlSize(.small) }
                        Text(message).foregroundStyle(.secondary)
                    }
                }
                Text("Upstream wallpapers come from Omarchy. Check each image’s source before reusing or redistributing artwork.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(24)
        }
        .onChange(of: selectedThemeID) { _, _ in model.clearSelection() }
    }

    private var themeGallery: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Themes · \(themes.count)").font(.title2.bold())
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 12)], spacing: 12) {
                ForEach(themes) { theme in
                    Button {
                        selectedThemeID = theme.id
                    } label: {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text("Aa").font(.system(size: 28, weight: .medium, design: .monospaced))
                                Spacer()
                                if theme.id == currentTheme.id { Image(systemName: "checkmark.circle.fill").foregroundStyle(Color(macarchyHex: theme.accent)) }
                            }
                            HStack(spacing: 3) {
                                ForEach(Array(theme.palette.enumerated()), id: \.offset) { _, color in
                                    RoundedRectangle(cornerRadius: 2).fill(Color(macarchyHex: color)).frame(height: 9)
                                }
                            }
                            Text(theme.name).font(.headline).lineLimit(1)
                        }
                        .padding(14).foregroundStyle(Color(macarchyHex: theme.foreground))
                        .background(Color(macarchyHex: theme.background), in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(theme.id == currentTheme.id ? Color.accentColor : .secondary.opacity(0.2), lineWidth: theme.id == currentTheme.id ? 2 : 1))
                    }.buttonStyle(.plain).disabled(model.isBusy)
                    .accessibilityLabel("\(theme.name) theme\(theme.id == currentTheme.id ? ", selected" : "")")
                }
            }
        }
    }

    private var wallpaperGallery: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("\(currentTheme.name) wallpapers").font(.title2.bold())
                Spacer()
                Button("Load Previews") { Task { await model.loadPreviews(wallpapers) } }
                    .disabled(model.isBusy || wallpapers.isEmpty)
                Button("Import Image…", systemImage: "plus") { Task { await model.importImage() } }
                    .disabled(model.isBusy)
            }
            Text("Select an image to download and preview it. Apply targets every connected display. Other Spaces may keep their own wallpaper.")
                .font(.callout).foregroundStyle(.secondary)
            if wallpapers.isEmpty {
                Text("The upstream wallpaper catalog is unavailable. You can still import an image.").foregroundStyle(.secondary)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12)], spacing: 12) {
                ForEach(wallpapers) { wallpaper in
                    wallpaperTile(id: wallpaper.id, name: wallpaper.name,
                                  detail: "\(wallpaper.width) × \(wallpaper.height)") {
                        Task { await model.select(wallpaper) }
                    }
                }
            }
            if !model.imported.isEmpty {
                Text("Your images").font(.headline)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12)], spacing: 12) {
                    ForEach(model.imported) { item in
                        wallpaperTile(id: item.id, name: item.name, detail: "Imported") {
                            Task { await model.selectImported(item) }
                        }
                    }
                }
            }
            if let id = model.selectedID, let image = model.thumbnails[id] {
                Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: 260)
                    .background(.black.opacity(0.2), in: RoundedRectangle(cornerRadius: 12))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .accessibilityLabel("Preview: \(model.selectedName)")
            }
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.selectedName).font(.headline)
                    if let source = model.selectedSource { Link("View image source", destination: source).font(.caption) }
                }
                Spacer()
                Button("Restore Last Wallpaper") { model.restore() }.disabled(!model.canRestore || model.isBusy)
                Button("Apply to All Connected Displays") { Task { await model.apply() } }
                    .buttonStyle(.borderedProminent).disabled(model.selectedURL == nil || model.isBusy)
            }
        }
    }

    private func wallpaperTile(id: String, name: String, detail: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8).fill(Color(macarchyHex: currentTheme.background))
                    if let image = model.thumbnails[id] {
                        Image(nsImage: image).resizable().scaledToFill()
                    } else {
                        Image(systemName: "photo").font(.title).foregroundStyle(Color(macarchyHex: currentTheme.accent))
                    }
                }.frame(height: 96).clipped().clipShape(RoundedRectangle(cornerRadius: 8))
                Text(name).font(.headline).lineLimit(1)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }.padding(8)
                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(model.selectedID == id ? Color.accentColor : .clear, lineWidth: 2))
        }.buttonStyle(.plain).disabled(model.isBusy)
        .accessibilityLabel("\(name), \(detail)\(model.selectedID == id ? ", selected" : "")")
    }
}

private extension Color {
    init(macarchyHex: String) {
        let value = UInt32(macarchyHex.dropFirst(), radix: 16) ?? 0
        self.init(red: Double((value >> 16) & 255) / 255, green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255)
    }
}
