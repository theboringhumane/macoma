import SwiftUI

@MainActor
struct WindowManagementControlView: View {
    let accentHex: String
    @StateObject private var service = WindowManagementService.shared
    @State private var showsShortcuts = false

    private var accent: Color {
        let hex = accentHex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        let value = UInt64(hex, radix: 16) ?? 0x89B4FA
        return Color(red: Double((value >> 16) & 255) / 255, green: Double((value >> 8) & 255) / 255,
                     blue: Double(value & 255) / 255)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Windows").font(.largeTitle.weight(.semibold))
                    Text("A desktop that moves sideways.").font(.title3).foregroundStyle(.secondary)
                    Text("New windows keep their own column width. Stack related windows vertically, then move between columns with the keyboard.")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Label(service.isEnabled ? "Scrolling columns enabled" : "Window management paused",
                                  systemImage: service.isEnabled ? "rectangle.3.group.fill" : "pause.circle")
                                .font(.headline)
                            Spacer()
                            if service.isEnabled {
                                Button("Pause & restore") { service.pause() }.buttonStyle(.borderedProminent)
                            } else {
                                Button("Enable") { service.enable() }.buttonStyle(.borderedProminent)
                            }
                        }
                        Text(service.status).font(.callout).foregroundStyle(.secondary)
                        if let warning = service.warning {
                            Label(warning, systemImage: "exclamationmark.triangle")
                                .font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                        }
                        if service.pendingRestoreCount > 0 {
                            Button("Restore saved windows (\(service.pendingRestoreCount))") { service.restoreSavedWindows() }
                        }
                        Divider()
                        HStack {
                            Label(service.hasAccessibility ? "Accessibility allowed" : "Accessibility needed",
                                  systemImage: service.hasAccessibility ? "checkmark.circle" : "hand.raised")
                                .font(.callout)
                            Spacer()
                            Button("Check access") { service.refreshAccess() }
                            Button("Open Accessibility Settings") { service.openAccessibilitySettings() }
                        }
                        Text("Enable manages windows on every Space you visit. Closing this window keeps management active in the menu bar. Pause or quit to stop and restore saved positions.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(8)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Current scope · Experimental").font(.headline)
                    Text("One connected display. Management follows you between macOS Spaces and handles the active Space. Changing displays or sleeping pauses management.")
                    Text("macOS keeps overflow windows partly visible, so extra columns leave a thin strip at the screen edge. Dialogs, fixed-size, minimized and screen-filling windows are left alone.")
                    if !service.hasSupportedDisplay {
                        Label("Multiple displays are not supported in this version.", systemImage: "display.2")
                            .foregroundStyle(.orange)
                    }
                }.font(.callout).foregroundStyle(.secondary)

                if !service.columns.isEmpty { columnsSection }

                GroupBox("Layout") {
                    VStack(alignment: .leading, spacing: 16) {
                        sliderRow("Inner gap", value: $service.preferences.innerGap, range: 0...40, suffix: "pt")
                        sliderRow("Outer gap", value: $service.preferences.outerGap, range: 0...60, suffix: "pt")
                        HStack {
                            Text("New column width").frame(width: 132, alignment: .leading)
                            Slider(value: $service.preferences.newColumnWidth, in: 0.25...0.97, step: 0.01)
                            Text("\(Int((service.preferences.newColumnWidth * 100).rounded()))%")
                                .monospacedDigit().frame(width: 48, alignment: .trailing)
                        }
                        Text("The width setting applies to new columns. Existing columns keep their width.")
                            .font(.caption).foregroundStyle(.secondary)
                        Toggle("Thin border around the focused window", isOn: $service.preferences.showFocusBorder)
                        Toggle("Keyboard shortcuts", isOn: $service.preferences.keyboardShortcuts)
                        DisclosureGroup("Shortcut reference", isExpanded: $showsShortcuts) {
                            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 8) {
                                shortcutRow("⌃⌥⌘ + arrows", "Focus column or window in a stack")
                                shortcutRow("⌃⌥⌘⇧ + arrows", "Move column or reorder a stack")
                                shortcutRow("⌃⌥⌘ + [ / ]", "Previous / next column width")
                                shortcutRow("⌃⌥⌘ + F", "Fill the display width")
                                shortcutRow("⌃⌥⌘ + S / U", "Stack left / unstack")
                                shortcutRow("⌃⌥⌘ + P", "Pause and restore positions")
                            }.padding(.top, 8).font(.callout)
                            Text("Uses registered shortcuts, without global key monitoring. A conflict prevents Enable until the shortcut is freed or shortcuts are turned off. Letter keys use physical US key positions.")
                                .font(.caption).foregroundStyle(.secondary).padding(.top, 8)
                        }
                    }.padding(8)
                }
            }
            .padding(28)
            .frame(maxWidth: 920, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .tint(accent)
        .onAppear { service.updateAccent(accentHex) }
        .onChange(of: accentHex) { _, value in service.updateAccent(value) }
    }

    private var columnsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Your columns").font(.headline)
                Spacer()
                Text("\(service.managedWindowCount) windows").font(.caption).foregroundStyle(.secondary)
            }
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 10) {
                    ForEach(service.columns) { column in
                        VStack(alignment: .leading, spacing: 8) {
                            Text("\(column.width) pt").font(.caption).foregroundStyle(.secondary)
                            ForEach(column.windows) { window in
                                Button { service.focusWindow(window.id) } label: {
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(window.app).font(.callout.weight(.medium))
                                        Text(window.title.isEmpty ? "Untitled window" : window.title)
                                            .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                    }
                                    .frame(width: 150, height: 58, alignment: .topLeading)
                                    .padding(12)
                                    .background(window.isFocused ? accent.opacity(0.12) : Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
                                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(window.isFocused ? accent : Color.primary.opacity(0.12), lineWidth: 1))
                                }.buttonStyle(.plain)
                            }
                        }
                    }
                }.padding(.bottom, 6)
            }
            HStack {
                Button("Previous column") { service.perform(.focusLeft) }
                Button("Next column") { service.perform(.focusRight) }
                Spacer()
                Button("Stack left") { service.perform(.stack) }
                Button("Unstack") { service.perform(.unstack) }
                Button("Cycle width") { service.perform(.wider) }
            }.controlSize(.small)
        }
    }

    private func sliderRow(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, suffix: String) -> some View {
        HStack {
            Text(title).frame(width: 132, alignment: .leading)
            Slider(value: value, in: range, step: 1)
            Text("\(Int(value.wrappedValue)) \(suffix)").monospacedDigit().frame(width: 48, alignment: .trailing)
        }
    }

    private func shortcutRow(_ keys: String, _ action: String) -> some View {
        GridRow { Text(keys).monospaced(); Text(action).foregroundStyle(.secondary) }
    }
}
