import AppKit
import Foundation
import CryptoKit

@MainActor
private final class FakeDesktop: MacarchyWallpaperBackend {
    var values: [String: MacarchyDesktopImageState]
    var connected = ["a", "b"]
    var calls = 0
    var failures: Set<Int> = []
    var mutateOnFailure: Set<Int> = []

    init(_ original: [String: MacarchyDesktopImageState]) { values = original }
    func displays() -> [MacarchyWallpaperDisplay] { connected.map { .init(id: $0, name: $0.uppercased()) } }
    func state(for displayID: String) throws -> MacarchyDesktopImageState { values[displayID]! }
    func set(_ state: MacarchyDesktopImageState, on displayID: String) throws {
        calls += 1
        if failures.contains(calls) {
            if mutateOnFailure.contains(calls) { values[displayID] = state }
            throw MacarchyAppearanceError("Injected write failure \(calls)")
        }
        values[displayID] = state
    }
}

@main
struct AppearanceTests {
    @MainActor
    static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("MacarchyAppearanceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let target = scratch.appendingPathComponent("selected.jpg")
        try Data("fixture".utf8).write(to: target)
        let originals: [String: MacarchyDesktopImageState] = [
            "a": .init(url: URL(fileURLWithPath: "/fixture/a.jpg"), scaling: 0, clipping: false, fill: [0.2, 0.3, 0.4]),
            "b": .init(url: URL(fileURLWithPath: "/fixture/b.jpg"), scaling: 2, clipping: true, fill: [0.6, 0.5, 0.4])
        ]
        var passed = 0
        func check(_ condition: @autoclosure () -> Bool, _ label: String) throws {
            guard condition() else { throw MacarchyAppearanceError("FAIL: \(label)") }
            passed += 1
            print("PASS: \(label)")
        }
        func requireFailure(_ label: String, _ body: () throws -> Void) throws {
            do { try body() } catch { return }
            throw MacarchyAppearanceError("FAIL: expected error for \(label)")
        }

        let themes = try JSONDecoder().decode([MacarchyTheme].self, from: Data(contentsOf: root.appendingPathComponent("Resources/Desktop/themes.json")))
        let wallpapers = try JSONDecoder().decode([MacarchyWallpaper].self, from: Data(contentsOf: root.appendingPathComponent("Resources/Desktop/wallpapers.json")))
        try check(themes.count == 23 && themes.allSatisfy(\.isValid) && Set(themes.map(\.id)).count == 23, "23 unique palettes have 16 valid ANSI colors")
        try check(themes.allSatisfy { $0.selectionBackground != nil && $0.selectionForeground != nil && $0.cursor != nil }, "terminal selection and cursor colors are resolved")
        try check(wallpapers.count == 96 && wallpapers.allSatisfy(\.isValid), "96 wallpaper records use bounded pinned source URLs")
        try check(wallpapers.allSatisfy { Set(themes.map(\.id)).contains($0.themeID) }, "every wallpaper references a bundled theme")

        do {
            let desktop = FakeDesktop(originals)
            let journal = scratch.appendingPathComponent("receipt.json")
            let transaction = MacarchyWallpaperTransaction(backend: desktop, journalURL: journal)
            try check(desktop.calls == 0 && !transaction.canRestore, "initialization performs no desktop write")
            _ = try transaction.apply(target)
            try check(desktop.values.values.allSatisfy { $0.url == target }, "apply targets all connected displays")
            let count = desktop.calls
            _ = try transaction.apply(target)
            try check(desktop.calls == count, "reapplying the same wallpaper preserves the prior restore receipt")
            let reloaded = MacarchyWallpaperTransaction(backend: desktop, journalURL: journal)
            try check(reloaded.canRestore, "restore receipt survives controller recreation")
            _ = try reloaded.restore()
            try check(desktop.values == originals && !reloaded.canRestore, "restore preserves each original image and scaling options")
        }
        do {
            let desktop = FakeDesktop(originals)
            desktop.failures = [2]; desktop.mutateOnFailure = [2]
            let transaction = MacarchyWallpaperTransaction(backend: desktop, journalURL: nil)
            try requireFailure("partial apply") { _ = try transaction.apply(target) }
            try check(desktop.values == originals && desktop.calls == 4 && !transaction.canRestore, "partial failure rolls back successful and failing targets")
        }
        do {
            let desktop = FakeDesktop(originals)
            desktop.failures = [2, 3]; desktop.mutateOnFailure = [2]
            let transaction = MacarchyWallpaperTransaction(backend: desktop, journalURL: nil)
            try requireFailure("rollback failure") { _ = try transaction.apply(target) }
            try check(transaction.canRestore && desktop.values["a"] == originals["a"] && desktop.values["b"]?.url == target,
                      "failed rollback retains the unresolved display recovery record")
            desktop.failures = []
            _ = try transaction.restore()
            try check(desktop.values == originals, "unresolved rollback can be retried through Restore")
        }
        do {
            let desktop = FakeDesktop(originals)
            let transaction = MacarchyWallpaperTransaction(backend: desktop, journalURL: nil)
            _ = try transaction.apply(target)
            desktop.values["b"] = .init(url: URL(fileURLWithPath: "/fixture/external.jpg"))
            let count = desktop.calls
            try requireFailure("external wallpaper") { _ = try transaction.restore() }
            try check(desktop.calls == count && desktop.values["b"]?.url.lastPathComponent == "external.jpg", "restore preserves changes made outside Macarchy")
        }
        do {
            let desktop = FakeDesktop(originals)
            let transaction = MacarchyWallpaperTransaction(backend: desktop, journalURL: nil)
            _ = try transaction.apply(target)
            desktop.values["b"]?.clipping = false
            let count = desktop.calls
            try requireFailure("external crop options") { _ = try transaction.restore() }
            try check(desktop.calls == count, "restore preserves externally changed image options")
        }
        do {
            let desktop = FakeDesktop(originals)
            let transaction = MacarchyWallpaperTransaction(backend: desktop, journalURL: nil)
            _ = try transaction.apply(target)
            desktop.connected = ["a"]
            let count = desktop.calls
            try requireFailure("disconnected display") { _ = try transaction.restore() }
            try check(desktop.calls == count && transaction.canRestore, "disconnected display stops restore before any write")
        }
        do {
            let desktop = FakeDesktop(originals)
            let transaction = MacarchyWallpaperTransaction(backend: desktop, journalURL: nil)
            _ = try transaction.apply(target)
            let applied = desktop.values
            desktop.failures = [4]; desktop.mutateOnFailure = [4]
            try requireFailure("partial restore") { _ = try transaction.restore() }
            try check(desktop.values == applied && transaction.canRestore, "partial restore failure rolls back to the applied wallpapers")
        }
        try requireFailure("invalid image") { try MacarchyWallpaperCache.validateImage(Data("not an image".utf8)) }
        try check(!MacarchyWallpaperCache.matches(Data("wrong bytes".utf8), wallpapers[0]), "invalid images and mismatched pinned bytes are rejected")

        // Optional live source check. All files stay in the test scratch directory;
        // this does not instantiate NSWorkspace's wallpaper backend.
        if CommandLine.arguments.contains("--network") {
            let wallpaper = wallpapers.min { $0.bytes < $1.bytes }!
            let cache = MacarchyWallpaperCache(directory: scratch.appendingPathComponent("cache"),
                                               preparedDirectory: scratch.appendingPathComponent("prepared"))
            let url = try await cache.image(for: wallpaper)
            let downloaded = try Data(contentsOf: url)
            try check(MacarchyWallpaperCache.matches(downloaded, wallpaper), "live source download matches the pinned Git blob")
            let image = try await cache.preview(at: url)
            try check(image.width <= 720 && image.height <= 720, "WebP thumbnail decoding is bounded")
            let prepared = try await cache.prepareForDesktop(url)
            try check(prepared.pathExtension == "jpg" && prepared.path.hasPrefix(scratch.path), "desktop JPEG preparation stays in the test sandbox")
            let cached = try await cache.image(for: wallpaper)
            try check(cached == url, "verified image is reused from cache")
        }
        print("Appearance qualification passed: \(passed) checks. No live desktop writes.")
    }
}
