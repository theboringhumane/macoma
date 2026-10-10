import SwiftUI

struct MacarchyWorkspaceView: View {
    @ObservedObject var model: MacarchyModel
    @State private var showingInspector = true

    var body: some View {
        NavigationSplitView {
            MacarchyEffectSidebar(model: model)
                .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 280)
        } detail: {
            MacarchyEffectDetail(model: model)
                .navigationTitle("Macarchy")
                .navigationSubtitle(model.currentEffect.name)
                .toolbar { workspaceToolbar }
        }
        .navigationSplitViewStyle(.balanced)
        .inspector(isPresented: $showingInspector) {
            MacarchyInspector(model: model)
                .inspectorColumnWidth(min: 250, ideal: 270, max: 320)
        }
        .sheet(isPresented: $model.showingArtwork) { MacarchyArtworkEditor(model: model) }
        .alert("Macarchy", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
        .onChange(of: model.selectedEffect) { _, _ in model.previewFailure = false }
    }

    @ToolbarContentBuilder
    private var workspaceToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button { model.showingArtwork = true } label: {
                Label("Edit Artwork", systemImage: "square.and.pencil")
            }
            .help("Edit artwork")
        }
        ToolbarItem(placement: .confirmationAction) {
            MacarchyApplyButton(model: model)
        }
        ToolbarItem {
            Button { showingInspector.toggle() } label: {
                Label("Inspector", systemImage: "sidebar.right")
            }
            .help(showingInspector ? "Hide inspector" : "Show inspector")
        }
    }
}

private struct MacarchyEffectSidebar: View {
    @ObservedObject var model: MacarchyModel

    private var selection: Binding<String?> {
        Binding(get: { model.selectedEffect }, set: { if let value = $0 { model.selectedEffect = value } })
    }

    var body: some View {
        List(selection: selection) {
            ForEach(MacarchyEffect.Origin.allCases) { origin in
                let effects = model.filteredEffects.filter { $0.origin == origin }
                if !effects.isEmpty {
                    Section(origin.rawValue) {
                        ForEach(effects) { effect in
                            effectRow(effect)
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .searchable(text: $model.search, placement: .sidebar, prompt: "Search effects")
        .overlay {
            if model.filteredEffects.isEmpty {
                ContentUnavailableView.search(text: model.search)
            }
        }
        .navigationTitle("Effects")
    }

    private func effectRow(_ effect: MacarchyEffect) -> some View {
        HStack {
            Label(effect.name, systemImage: effect.symbol)
            Spacer(minLength: 4)
            Toggle("Include \(effect.name) in rotation", isOn: Binding(
                get: { model.isIncluded(effect.id) },
                set: { model.setIncluded(effect.id, included: $0) }
            ))
            .labelsHidden()
            .toggleStyle(.checkbox)
            .controlSize(.small)
            .disabled(model.settings.effects.count == 1 && model.isIncluded(effect.id))
            .help("Include \(effect.name) in the rotation")
        }
        .tag(effect.id)
    }
}

private struct MacarchyEffectDetail: View {
    @ObservedObject var model: MacarchyModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ZStack {
                Color.black
                MacarchyPreview(content: model.previewContent, revision: model.previewRevision) { model.previewFailure = true }
                if model.previewFailure {
                    ContentUnavailableView {
                        Label("Preview Unavailable", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text("The animation could not start.")
                    } actions: {
                        Button("Try Again", action: model.restartPreview)
                    }
                    .background(.black)
                    .environment(\.colorScheme, .dark)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .bottom) {
                MacarchyPreviewTransport(model: model).padding(12)
            }
            .accessibilityLabel("\(model.currentEffect.name) preview")

            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(model.currentEffect.name).font(.headline)
                    Spacer()
                    Text(model.currentEffect.family).foregroundStyle(.secondary)
                }
                Text(model.currentEffect.detail).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(model.currentEffect.origin.attribution).font(.caption).foregroundStyle(.secondary)
                if model.artError != nil {
                    Label("Showing the last valid artwork", systemImage: "exclamationmark.circle")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.callout)
        }
        .padding(20)
        .frame(minWidth: 320, minHeight: 360)
    }
}

private struct MacarchyApplyButton: View {
    @ObservedObject var model: MacarchyModel

    var body: some View {
        Group {
            if #available(macOS 26.0, *) {
                Button("Apply Changes") { model.save() }.buttonStyle(.glassProminent)
            } else {
                Button("Apply Changes") { model.save() }
            }
        }
        .disabled(!model.hasChanges || model.artError != nil)
        .help("Save artwork and screensaver settings")
    }
}

private struct MacarchyPreviewTransport: View {
    @ObservedObject var model: MacarchyModel

    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    restartButton.buttonStyle(.glass).buttonBorderShape(.circle)
                    fullscreenButton.buttonStyle(.glass)
                }
            }
        } else {
            HStack(spacing: 8) {
                restartButton
                fullscreenButton
            }
            .padding(8)
            .background(.regularMaterial, in: Capsule())
        }
    }

    private var restartButton: some View {
        Button(action: model.restartPreview) {
            Label("Restart Preview", systemImage: "arrow.clockwise").labelStyle(.iconOnly)
        }
        .help("Restart preview")
    }

    private var fullscreenButton: some View {
        Button(action: model.showFullscreen) {
            Label("Full Screen", systemImage: "arrow.up.left.and.arrow.down.right")
        }
        .help("Full screen preview")
    }
}

private struct MacarchyInspector: View {
    @ObservedObject var model: MacarchyModel

    var body: some View {
        Form {
            Section {
                LabeledContent("Effects", value: "\(model.settings.effects.count) of \(model.effects.count)")
                Button("Include All Effects", action: model.useAllEffects)
                    .disabled(model.settings.effects.count == model.effects.count)
                Button("Use Only \(model.currentEffect.name)", action: model.useOnlySelected)
                    .disabled(model.settings.effects == [model.selectedEffect])
            } header: {
                Text("Rotation")
            } footer: {
                Text("Checked effects play in random order. Keep one checked to repeat it.")
            }

            Section("Artwork") {
                LabeledContent("Size", value: model.artDimensions)
                Button("Edit Artwork…") { model.showingArtwork = true }
            }

            Section {
                LabeledContent("Text Size") {
                    Text("\(Int(model.settings.fontSize)) pt").monospacedDigit()
                }
                Slider(value: $model.settings.fontSize, in: 8...64, step: 1) {
                    Text("Text size")
                }
                ColorPicker("Background", selection: Binding(get: { model.backgroundColor }, set: { model.backgroundColor = $0 }), supportsOpacity: false)
            } header: {
                Text("Appearance")
            } footer: {
                Text("The preview scales artwork to fit.")
            }

            Section("Screen Saver") {
                LabeledContent("Status", value: model.isInstalled ? "Installed" : "Not installed")
                Button(model.isInstalled ? "Reinstall Screensaver" : "Install Screensaver", action: model.installScreensaver)
                    .disabled(model.artError != nil)
                Button("Open System Settings…", action: model.openSettings)
            }

            Section {
                Button("Restore Defaults", action: model.reset)
            } footer: {
                if model.hasChanges {
                    Text("You have unsaved changes.")
                } else if let message = model.message {
                    Text(message)
                }
            }
        }
        .formStyle(.grouped)
        .controlSize(.small)
    }
}

private struct MacarchyArtworkEditor: View {
    @ObservedObject var model: MacarchyModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Artwork").font(.headline)
            Text("Type a message, paste ASCII art, or import an image.")
                .foregroundStyle(.secondary)

            MacarchyArtworkTextEditor(text: $model.art)
                .frame(minHeight: 240)
                .border(Color(nsColor: .separatorColor))
                .accessibilityLabel("Custom ASCII artwork")

            HStack {
                if let error = model.artError {
                    Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.secondary)
                } else {
                    Text(model.artDimensions).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Restore Wordmark", action: model.restoreArtwork)
            }
            .font(.callout)

            GroupBox("Image Conversion") {
                Form {
                    Picker("Style", selection: $model.settings.asciiMode) {
                        Text("Block").tag("block")
                        Text("Braille").tag("braille")
                    }
                    .pickerStyle(.segmented)
                    HStack {
                        Slider(value: Binding(get: { Double(model.settings.threshold) }, set: { model.settings.threshold = Int($0) }), in: 0...100, step: 1) {
                            Text("Threshold")
                        }
                        Text("\(model.settings.threshold)%").monospacedDigit().frame(width: 38, alignment: .trailing)
                        Toggle("Invert", isOn: $model.settings.invert).toggleStyle(.checkbox)
                    }
                    LabeledContent("Source") {
                        Text(model.importedImageName ?? "PNG, SVG, or text file").foregroundStyle(.secondary).lineLimit(1)
                    }
                    HStack {
                        Button("Import…", action: model.importArtwork)
                        Button("Convert Again", action: model.reconvertArtwork).disabled(!model.canReconvert)
                    }
                }
                .padding(8)
            }

            HStack {
                Text("Apply changes in the main window to save.").font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 680, height: 610)
    }
}
