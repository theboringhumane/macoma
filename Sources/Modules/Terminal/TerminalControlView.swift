import SwiftUI

struct TerminalControlView: View {
    let theme: MacarchyTheme
    @StateObject private var model = TerminalControlModel()

    private var palette: TerminalPalette {
        TerminalPalette(id: theme.id, name: theme.name, background: theme.background, foreground: theme.foreground,
            accent: theme.accent, colors: theme.palette, selectionBackground: theme.selectionBackground,
            selectionForeground: theme.selectionForeground, cursor: theme.cursor)
    }
    private var changed: Bool { model.needsProfileUpdate || model.receipt?.theme != palette || model.receipt?.font != model.font }

    var body: some View {
        Form {
            Section {
                LabeledContent("Terminal") {
                    Text(model.installation.ghosttyVersion ?? "Ghostty is not installed")
                        .foregroundStyle(model.installation.ghosttyApp == nil ? .secondary : .primary)
                }
                LabeledContent("Profile", value: model.receipt.map { "\($0.theme.name) · \($0.font.family), \($0.font.size.formatted()) pt" } ?? "Not applied")
                LabeledContent("Multiplexer", value: model.installation.tmuxVersion ?? "tmux is not installed")
                LabeledContent("Work session", value: model.installation.workRunning ? "Running · reconnect available" : "Ready to create")
                if model.installation.ghosttyApp == nil {
                    HStack {
                        Link("Get Ghostty", destination: URL(string: "https://ghostty.org/download")!)
                        Spacer()
                        Button("Copy install command") { model.copyInstallCommand("brew install --cask ghostty") }
                    }
                }
            } header: { Text("Native terminal") } footer: {
                Text("Macoma opens the native Ghostty app with a separate profile. Your regular Ghostty settings and shell files stay in place.")
            }

            Section("Profile") {
                LabeledContent("Theme", value: theme.name)
                Picker("Font", selection: $model.fontFamily) {
                    ForEach(model.fonts, id: \.self) { font in Text(font).tag(font) }
                }
                HStack {
                    Text("Font size")
                    Spacer()
                    Stepper(value: $model.fontSize, in: 9...28, step: 0.5) {
                        Text("\(model.fontSize.formatted()) pt").monospacedDigit().frame(minWidth: 52, alignment: .trailing)
                    }.fixedSize()
                }
                HStack {
                    Button("Apply Profile", systemImage: "checkmark.circle") { model.apply(palette) }
                        .disabled(model.installation.ghosttyBinary == nil || model.busy)
                    Spacer()
                    if model.busy { ProgressView().controlSize(.small) }
                    if changed { Text("Unapplied changes").font(.caption).foregroundStyle(.secondary) }
                }
                HStack {
                    Button("Show Profile in Finder") { model.revealProfile() }.disabled(model.receipt == nil)
                    Spacer()
                    Button("Restore Previous Profile") { model.restore() }
                        .disabled(!model.canRestore || model.busy || model.installation.ghosttyBinary == nil)
                }
            }

            Section {
                HStack {
                    Button("Launch Terminal", systemImage: "terminal") { model.launch(work: false) }
                    Button("Work Session", systemImage: "rectangle.split.2x2") { model.launch(work: true) }
                        .disabled(model.installation.tmuxBinary == nil)
                }.disabled(model.receipt == nil || model.installation.ghosttyBinary == nil || model.busy)
                Text("Work starts with one full-width upper pane and two lower panes. Its status bar sits at the top, with blue and purple pane borders from your theme.")
                    .foregroundStyle(.secondary)
                LabeledContent("Pane shortcuts", value: "Control-Space, then H or V to split")
                LabeledContent("New pane", value: "Command-T · direction follows the pane’s shape")
                LabeledContent("New tab", value: "Command-Shift-T")
                LabeledContent("Detach", value: "Control-Space, then D")
                LabeledContent("Alternate prefix", value: "Control-B")
                if model.installation.tmuxBinary == nil {
                    Button("Copy tmux install command") { model.copyInstallCommand("brew install tmux") }
                }
            } header: { Text("Launch") } footer: {
                Text("Launch uses the last applied profile. Work reconnects to the dedicated Macoma tmux server without resetting existing panes. Left Option acts as Alt; right Option keeps special characters.")
            }

            Section {
                ForEach(model.installation.tools) { tool in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(tool.name).font(.body.monospaced())
                            Text(tool.detail).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if tool.installed {
                            Label("Installed", systemImage: "checkmark.circle.fill").foregroundStyle(.secondary)
                        } else {
                            Text("Not installed").foregroundStyle(.secondary)
                            Button("Copy command") { model.copyInstallCommand(tool.installCommand) }
                                .help(tool.installCommand)
                        }
                    }
                }
                Button("Refresh Tool Status", systemImage: "arrow.clockwise") { Task { await model.refresh() } }
                    .disabled(model.busy)
            } header: { Text("Shell tools") } footer: {
                Text("Installed tools are enabled only inside managed sessions. Without eza or Starship, Macoma uses macOS color listings and a simple zsh prompt. Install commands are copied for you to run; Macoma does not install packages.")
            }

            if let message = model.message {
                Section { Label(message, systemImage: "checkmark.circle").foregroundStyle(.secondary).textSelection(.enabled) }
            }
            if let error = model.error {
                Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).textSelection(.enabled) }
            }
        }
        .formStyle(.grouped)
        .task { await model.refresh() }
    }
}
