import AppKit
import SwiftUI

@main
struct MacarchyApp: App {
    @StateObject private var model = MacarchyModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        Window("Macarchy", id: "main") {
            MacarchyWorkspaceView(model: model)
                .frame(minWidth: 850, minHeight: 600)
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { model.refreshInstallation() }
                }
        }
        .defaultSize(width: 1000, height: 680)
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandMenu("Screensaver") {
                Button("Apply Changes") { model.save() }
                    .keyboardShortcut("s")
                    .disabled(model.artError != nil)
                Button("Edit Artwork…") { model.showingArtwork = true }
                    .keyboardShortcut("e")
                Button("Full Screen Preview") { model.showFullscreen() }
                    .keyboardShortcut("f", modifiers: [.command, .control])
                Divider()
                Button("Install Screensaver…") { model.installScreensaver() }
                Button("Open Screen Saver Settings") { model.openSettings() }
            }
        }
    }
}
