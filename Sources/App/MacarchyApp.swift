import AppKit
import SwiftUI

@main
struct MacarchyApp: App {
    @NSApplicationDelegateAdaptor(MacomaAppDelegate.self) private var appDelegate
    @StateObject private var model = MacarchyModel()
    @StateObject private var control = MacarchyControlPlaneModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        Window("Macoma", id: "main") {
            MacarchyControlPlaneView(control: control, saver: model)
                .frame(minWidth: 980, minHeight: 680)
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { model.refreshInstallation() }
                }
        }
        .defaultSize(width: 1120, height: 780)
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandMenu("Desktop") {
                ForEach(Array(MacarchyModule.allCases.enumerated()), id: \.element.id) { index, module in
                    Button(module.title) { control.module = module }
                        .keyboardShortcut(KeyEquivalent(Character(String(index + 1))))
                }
            }
            CommandMenu("Screensaver") {
                Button("Apply Changes") { model.save() }
                    .keyboardShortcut("s")
                    .disabled(control.module != .screensavers || model.artError != nil)
                Button("Edit Artwork…") { model.showingArtwork = true }
                    .keyboardShortcut("e")
                    .disabled(control.module != .screensavers)
                Button("Full Screen Preview") { model.showFullscreen() }
                    .keyboardShortcut("f", modifiers: [.command, .control])
                    .disabled(control.module != .screensavers)
                Divider()
                Button("Install Screensaver…") { model.installScreensaver() }
                Button("Open Screen Saver Settings") { model.openSettings() }
            }
        }
        MenuBarExtra("Macoma", systemImage: "macwindow") {
            MacarchyDesktopMenu(control: control)
        }
    }
}

private final class MacomaAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

private struct MacarchyDesktopMenu: View {
    @ObservedObject var control: MacarchyControlPlaneModel
    @ObservedObject private var windows = WindowManagementService.shared
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text("Macoma · \(control.theme.name)")
        ForEach(MacarchyModule.allCases) { module in
            Button(module.title) {
                control.module = module
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }
        }
        Divider()
        Button("Pause Windows & Restore Positions") { windows.pause() }
            .disabled(!windows.isEnabled)
        if windows.pendingRestoreCount > 0 {
            Button("Restore Saved Window Positions") { windows.restoreSavedWindows() }
        }
        Divider()
        Button("Quit Macoma") { NSApp.terminate(nil) }
    }
}
