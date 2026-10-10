import AppKit
import Combine
import SwiftUI

enum MacarchyModule: String, CaseIterable, Identifiable {
    case overview, appearance, terminal, windows, screensavers
    var id: String { rawValue }
    var title: String {
        switch self {
        case .overview: return "Overview"
        case .appearance: return "Appearance"
        case .terminal: return "Terminal"
        case .windows: return "Windows"
        case .screensavers: return "Screensavers"
        }
    }
    var symbol: String {
        switch self {
        case .overview: return "macwindow"
        case .appearance: return "paintpalette"
        case .terminal: return "terminal"
        case .windows: return "rectangle.split.3x1"
        case .screensavers: return "sparkles.tv"
        }
    }
    var detail: String {
        switch self {
        case .overview: return "Your desktop, in one place."
        case .appearance: return "Omarchy palettes and wallpapers for your desktop."
        case .terminal: return "A native terminal with a coordinated theme and tmux workspace."
        case .windows: return "Scrolling columns, stacked windows and keyboard controls."
        case .screensavers: return "Forty terminal-art effects and your own artwork."
        }
    }
}

@MainActor
final class MacarchyControlPlaneModel: ObservableObject {
    let themes = MacarchyThemeCatalog.load()
    @Published var module = MacarchyModule.overview
    @Published var selectedThemeID: String {
        didSet { UserDefaults.standard.set(selectedThemeID, forKey: "MacarchySelectedTheme") }
    }

    init() {
        let saved = UserDefaults.standard.string(forKey: "MacarchySelectedTheme") ?? "tokyo-night"
        selectedThemeID = themes.contains { $0.id == saved } ? saved : themes[0].id
    }

    var theme: MacarchyTheme { themes.first { $0.id == selectedThemeID } ?? themes[0] }
}

struct MacarchyControlPlaneView: View {
    @ObservedObject var control: MacarchyControlPlaneModel
    @ObservedObject var saver: MacarchyModel
    @State private var showingSaverInspector = true

    private var navigation: Binding<String?> {
        Binding(get: {
            control.module == .screensavers ? saver.selectedEffect : "module:\(control.module.rawValue)"
        }, set: { value in
            guard let value else { return }
            if value.hasPrefix("module:"), let module = MacarchyModule(rawValue: String(value.dropFirst(7))) {
                control.module = module
            } else if saver.effects.contains(where: { $0.id == value }) {
                saver.selectedEffect = value
                control.module = .screensavers
            }
        })
    }

    private var inspectorVisible: Binding<Bool> {
        Binding(get: { control.module == .screensavers && showingSaverInspector },
                set: { showingSaverInspector = $0 })
    }

    var body: some View {
        NavigationSplitView {
            List(selection: navigation) {
                Section("Macoma") {
                    ForEach(MacarchyModule.allCases) { module in
                        Label(module.title, systemImage: module.symbol).tag("module:\(module.rawValue)")
                    }
                }
                if control.module == .screensavers {
                    MacarchyScreensaverEffectSections(model: saver)
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 300)
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(control.theme.name).font(.caption.weight(.medium))
                    Text("Desktop palette").font(.caption2).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
            }
        } detail: {
            moduleContent
                .navigationTitle("Macoma")
                .navigationSubtitle(control.module == .screensavers ? saver.currentEffect.name : control.module.title)
                .toolbar { controlToolbar }
        }
        .navigationSplitViewStyle(.balanced)
        .inspector(isPresented: inspectorVisible) {
            if control.module == .screensavers {
                MacarchyInspector(model: saver)
                    .inspectorColumnWidth(min: 250, ideal: 270, max: 320)
            }
        }
        .sheet(isPresented: $saver.showingArtwork) { MacarchyArtworkEditor(model: saver) }
        .alert("Macoma", isPresented: Binding(get: { saver.errorMessage != nil }, set: { if !$0 { saver.errorMessage = nil } })) {
            Button("OK", role: .cancel) { saver.errorMessage = nil }
        } message: { Text(saver.errorMessage ?? "") }
        .onChange(of: saver.selectedEffect) { _, _ in saver.previewFailure = false }
        .onChange(of: control.selectedThemeID) { _, _ in
            WindowManagementService.shared.updateAccent(control.theme.accent)
        }
    }

    @ViewBuilder
    private var moduleContent: some View {
        switch control.module {
        case .overview:
            MacarchyOverviewView(control: control, saver: saver)
        case .appearance:
            AppearanceControlView(themes: control.themes, selectedThemeID: $control.selectedThemeID)
        case .terminal:
            TerminalControlView(theme: control.theme)
        case .windows:
            WindowManagementControlView(accentHex: control.theme.accent)
        case .screensavers:
            MacarchyEffectDetail(model: saver)
                .padding(16)
                .searchable(text: $saver.search, placement: .toolbar, prompt: "Search effects")
        }
    }

    @ToolbarContentBuilder
    private var controlToolbar: some ToolbarContent {
        if control.module == .screensavers {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { saver.showingArtwork = true } label: {
                    Label("Edit Artwork", systemImage: "square.and.pencil")
                }
                .help("Edit artwork")
            }
            ToolbarItem(placement: .confirmationAction) { MacarchyApplyButton(model: saver) }
            ToolbarItem {
                Button { showingSaverInspector.toggle() } label: {
                    Label("Inspector", systemImage: "sidebar.right")
                }
                .help("Show screensaver settings")
            }
        }
    }
}

private struct MacarchyOverviewView: View {
    @ObservedObject var control: MacarchyControlPlaneModel
    @ObservedObject var saver: MacarchyModel

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("The Omarchy experience. On your Mac.").font(.title2.weight(.semibold))
                    Text("Choose your palette, set up your terminal, arrange your windows and make your desktop your own.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 8)
            }
            Section("Desktop") {
                ForEach(MacarchyModule.allCases.filter { $0 != .overview }) { module in
                    Button { control.module = module } label: {
                        HStack(spacing: 12) {
                            Image(systemName: module.symbol).font(.title3).frame(width: 28)
                                .foregroundStyle(.tint)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(module.title).font(.headline).foregroundStyle(.primary)
                                Text(module.detail).font(.callout).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            Section {
                LabeledContent("Palette", value: control.theme.name)
                LabeledContent("Screensavers", value: "\(saver.effects.count) effects")
                LabeledContent("System screensaver", value: saver.isInstalled ? "Installed" : "Not installed")
            } header: {
                Text("Your setup")
            } footer: {
                Text("Each module shows what it changes and provides its own controls. Window management stays off until you enable it.")
            }
            Section {
                Link("Macoma on GitHub", destination: URL(string: "https://github.com/theboringhumane/macoma")!)
                Link("Omarchy", destination: URL(string: "https://omarchy.org")!)
            }
        }
        .formStyle(.grouped)
    }
}
