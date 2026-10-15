import SwiftUI
import TouchMCore

/// Menu-bar popover: status at a glance plus the everyday actions.
struct MenuPanel: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                IconTile(symbol: "hand.point.up.left.fill", color: .blue, size: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text("TouchM").font(.headline)
                    HStack(spacing: 5) {
                        StatusDot(color: model.statusLine.color)
                        Text(LocalizedStringKey(model.statusLine.text)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Toggle("", isOn: $model.settings.enabled).toggleStyle(.switch).labelsHidden()
            }

            if !model.permissionsOK {
                VStack(alignment: .leading, spacing: 6) {
                    if !model.accessibilityOK { warn("Accessibility", "Privacy_Accessibility") }
                    if !model.inputMonitoringOK { warn("Input Monitoring", "Privacy_ListenEvent") }
                }
            }

            HStack(spacing: 6) {
                ToolTile(symbol: "scope", title: "Calibrate", color: .indigo, iconSize: 30, minHeight: 74, font: .caption) { Calibration.shared.begin() }
                ToolTile(symbol: "hand.draw.fill", title: Overlay.shared.testMode ? "Stop test" : "Touch test", color: .green, iconSize: 30, minHeight: 74, font: .caption) { Overlay.shared.testMode.toggle() }
                ToolTile(symbol: "pencil.tip.crop.circle.fill", title: "Annotate", color: .pink, iconSize: 30, minHeight: 74, font: .caption) { Annotate.shared.toggle() }
                ToolTile(symbol: "plus.magnifyingglass", title: "Magnifier", color: .teal, iconSize: 30, minHeight: 74, font: .caption) { Magnifier.shared.toggle() }
                ToolTile(symbol: "command", title: "Commander", color: .orange, iconSize: 30, minHeight: 74, font: .caption) { SettingsWindow.shared.show(page: .commander) }
            }

            DisplayLevels()
            DisplayControls()

            Divider()
            HStack {
                Button { SettingsWindow.shared.show() } label: { Label("Settings…", systemImage: "gearshape") }
                    .buttonStyle(.plain)
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }.buttonStyle(.plain).foregroundStyle(.secondary)
            }
        }
        .padding(14).frame(width: 380)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    func warn(_ name: String, _ pane: String) -> some View {
        Button { model.openPrivacy(pane) } label: {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text("Allow \(name)").font(.callout)
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
            }
            .padding(8).background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain)
    }
}

/// Brightness and contrast of every display, right in the menu.
struct DisplayLevels: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var b = Brightness.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(b.screens) { s in
                if b.screens.count > 1 { Text(s.name).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                row("sun.max.fill", Binding(get: { b.values[s.id] ?? 1 }, set: { b.set($0, for: s.id, method: model.settings.brightnessMethod) }))
                row("circle.lefthalf.filled", Binding(get: { b.contrast[s.id] ?? 0.5 }, set: { b.setContrast($0, for: s.id, method: model.settings.brightnessMethod) }))
            }
        }.onAppear { b.refresh(); b.readHardware(method: model.settings.brightnessMethod) }
    }
    private func row(_ icon: String, _ v: Binding<Double>) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).frame(width: 20).foregroundStyle(.secondary)
            Slider(value: v, in: 0...1)
            Text("\(Int((v.wrappedValue * 100).rounded()))%").monospacedDigit().foregroundStyle(.secondary).frame(width: 40, alignment: .trailing)
        }
    }
}

/// Resolution (including HiDPI) and rotation of every display.
struct DisplayControls: View {
    @ObservedObject private var b = Brightness.shared
    @ObservedObject private var d = DisplayModes.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(b.screens) { s in
                let _ = d.tick
                VStack(alignment: .leading, spacing: 4) {
                    if b.screens.count > 1 { Text(s.name).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                    HStack(spacing: 8) {
                        PopMenu {
                            let cur = d.current(for: s.id)
                            ForEach(d.modes(for: s.id)) { m in
                                PopItem(title: m.label, checked: m == cur) { d.set(m, for: s.id) }
                            }
                        } label: { Image(systemName: "rectangle.dashed"); Text(d.current(for: s.id)?.label ?? "—").lineLimit(1) }
                        Spacer()
                        if d.canRotate {
                            ForEach([0, 90, 180, 270], id: \.self) { deg in
                                Button { d.rotate(deg, for: s.id) } label: {
                                    Text("\(deg)°").font(.caption).frame(minWidth: 30, minHeight: 24)
                                        .background(RoundedRectangle(cornerRadius: 6).fill(d.rotation(for: s.id) == deg ? Color.accentColor.opacity(0.35) : Color.primary.opacity(0.08)))
                                }.buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
        }.onAppear { b.refresh() }
    }
}
