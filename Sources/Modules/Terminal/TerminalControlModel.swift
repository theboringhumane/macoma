import AppKit
import Foundation
import SwiftUI

struct TerminalDependency: Identifiable {
    let id: String
    let name: String
    let detail: String
    let executable: URL?
    let installCommand: String
    var installed: Bool { executable != nil }
}

struct TerminalInstallation {
    var ghosttyApp: URL?
    var ghosttyBinary: URL?
    var ghosttyVersion: String?
    var tmuxBinary: URL?
    var tmuxVersion: String?
    var workRunning = false
    var tools: [TerminalDependency] = []

    static func discover() -> Self {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let apps = [URL(fileURLWithPath: "/Applications/Ghostty.app"), home.appendingPathComponent("Applications/Ghostty.app")]
        let app = apps.first { fm.isExecutableFile(atPath: $0.appendingPathComponent("Contents/MacOS/ghostty").path) }
        let binary = app?.appendingPathComponent("Contents/MacOS/ghostty")
        let tmux = executable("tmux")
        var result = Self(ghosttyApp: app, ghosttyBinary: binary, tmuxBinary: tmux)
        if let binary, let version = try? TerminalProcess.run(binary, ["--version"]), version.status == 0 {
            result.ghosttyVersion = version.output.components(separatedBy: .newlines).first
        }
        if let tmux {
            if let version = try? TerminalProcess.run(tmux, ["-V"]), version.status == 0 { result.tmuxVersion = version.output }
            result.workRunning = (try? TerminalProcess.run(tmux, ["-L", "macarchy", "has-session", "-t", "=Work"]).status) == 0
        }
        result.tools = [
            ("eza", "File listings", "Colorful files, folders and icons"),
            ("starship", "Prompt", "A compact prompt with Git status"),
            ("fzf", "Fuzzy search", "Search shell history and files"),
            ("zoxide", "Directory jumping", "Jump to frequently used folders"),
            ("mise", "Developer tools", "Use your existing tool versions")
        ].map { TerminalDependency(id: $0.0, name: $0.0, detail: $0.2, executable: executable($0.0), installCommand: "brew install \($0.0)") }
        return result
    }

    static func executable(_ name: String) -> URL? {
        let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin").split(separator: ":").map(String.init) + ["/opt/homebrew/bin", "/usr/local/bin"]
        return paths.filter { $0.hasPrefix("/") }.map { URL(fileURLWithPath: $0, isDirectory: true).appendingPathComponent(name) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
}

@MainActor
final class TerminalControlModel: ObservableObject {
    @Published var installation = TerminalInstallation()
    @Published var receipt: TerminalProfileReceipt?
    @Published var canRestore = false
    @Published var fontFamily = "Menlo"
    @Published var fontSize = 13.0
    @Published var fonts: [String] = []
    @Published var busy = false
    @Published var message: String?
    @Published var error: String?
    private var loadedFont = false
    let store = TerminalProfileStore.standard

    var font: TerminalFontSettings { TerminalFontSettings(family: fontFamily, size: fontSize) }
    var needsProfileUpdate: Bool { receipt?.profileRevision != 2 }

    func refresh() async {
        guard !busy else { return }
        let installation = await Task.detached(priority: .userInitiated) { TerminalInstallation.discover() }.value
        self.installation = installation
        do {
            receipt = try store.currentReceipt()
            canRestore = try store.state()?.previous != nil
            if !loadedFont {
                let available = NSFontManager.shared.availableFontFamilies
                fonts = available.filter { name in
                    guard let font = NSFont(name: name, size: 13) else { return false }
                    return font.isFixedPitch || name.localizedCaseInsensitiveContains("mono") || name.localizedCaseInsensitiveContains("nerd")
                }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
                if !fonts.contains("Menlo") { fonts.append("Menlo") }
                fontFamily = receipt?.font.family ?? ["JetBrainsMono Nerd Font", "JetBrains Mono", "SF Mono", "Menlo"].first(where: fonts.contains) ?? "Menlo"
                fontSize = receipt?.font.size ?? 13
                if !fonts.contains(fontFamily) { fonts.append(fontFamily) }
                loadedFont = true
            }
        } catch { self.error = error.localizedDescription }
    }

    func apply(_ theme: TerminalPalette) {
        guard let ghostty = installation.ghosttyBinary else { error = "Install Ghostty to validate and apply this profile."; return }
        guard let resources = Bundle.main.resourceURL?.appendingPathComponent("Terminal", isDirectory: true) else {
            error = "The app has no Terminal resources."; return
        }
        let font = font
        let store = store
        let tmux = installation.tmuxBinary
        let originalZDOTDIR = ProcessInfo.processInfo.environment["ZDOTDIR"]
        begin()
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    let receipt = try store.apply(theme: theme, font: font, ghostty: ghostty, resources: resources, originalZDOTDIR: originalZDOTDIR)
                    return (receipt, Self.refreshTmux(tmux, profile: try store.profileURL(receipt.generation)))
                }.value
                receipt = result.0
                message = "\(result.0.theme.name) profile validated and applied. New Ghostty windows use this profile." + (result.1.map { " \($0)" } ?? "")
            } catch { self.error = error.localizedDescription }
            busy = false
            await refresh()
        }
    }

    func restore() {
        guard let ghostty = installation.ghosttyBinary else { error = "Install Ghostty to validate the restored profile."; return }
        let store = store
        let tmux = installation.tmuxBinary
        begin()
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    let receipt = try store.restore(ghostty: ghostty)
                    return (receipt, Self.refreshTmux(tmux, profile: try store.profileURL(receipt.generation)))
                }.value
                receipt = result.0
                fontFamily = result.0.font.family
                fontSize = result.0.font.size
                message = "Restored the previous \(result.0.theme.name) profile. New Ghostty windows use it." + (result.1.map { " \($0)" } ?? "")
            } catch { self.error = error.localizedDescription }
            busy = false
            await refresh()
        }
    }

    func launch(work: Bool) {
        guard let app = installation.ghosttyApp, let ghostty = installation.ghosttyBinary, let receipt else {
            error = "Apply a valid Ghostty profile first."; return
        }
        guard !needsProfileUpdate else { error = "Apply Profile once to enable the current pane shortcuts."; return }
        if work && installation.tmuxBinary == nil { error = "Install tmux to open the Work session."; return }
        let store = store
        let tmux = work ? installation.tmuxBinary : nil
        begin()
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    let profile = try store.profileURL(receipt.generation)
                    try store.validate(directory: profile, ghostty: ghostty)
                    let result = try TerminalProcess.run(URL(fileURLWithPath: "/usr/bin/open"), TerminalLaunch.openArguments(app: app, profile: profile, tmux: tmux))
                    guard result.status == 0 else { throw TerminalFailure("Ghostty could not open: \(result.output)") }
                }.value
                message = work ? "Opening Work in Ghostty. Existing panes and running commands are preserved." : "Opening Ghostty with the applied Macoma profile."
            } catch { self.error = error.localizedDescription }
            busy = false
            // open returns before Ghostty creates its terminal and tmux client.
            try? await Task.sleep(for: .seconds(1))
            await refresh()
        }
    }

    func revealProfile() {
        guard let receipt, let url = try? store.profileURL(receipt.generation) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url.appendingPathComponent("ghostty.conf")])
    }

    func copyInstallCommand(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        message = "Copied \(value). Run it in a terminal, then refresh tool status."
    }

    private func begin() { busy = true; message = nil; error = nil }

    nonisolated private static func refreshTmux(_ binary: URL?, profile: URL) -> String? {
        guard let binary else { return nil }
        do {
            guard try TerminalTmuxProfile.apply(binary: binary, profile: profile) else { return nil }
            return "Updated tmux colors and the profile for future panes."
        } catch { return "The existing tmux server could not reload: \(error.localizedDescription)" }
    }
}
