import SwiftUI

/// Rounded colour tile with an SF Symbol, as used in macOS System Settings.
struct IconTile: View {
    let symbol: String
    let color: Color
    var size: CGFloat = 26
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.55, weight: .semibold)).foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(LinearGradient(colors: [color.opacity(0.85), color], startPoint: .top, endPoint: .bottom),
                        in: RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
    }
}

/// Slider with a visible value: label left, slider and value right (System Settings layout).
struct SliderRow: View {
    let title: LocalizedStringKey
    var detail: LocalizedStringKey? = nil
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 1
    var unit = ""
    var format = "%.0f"
    @State private var text = ""
    @FocusState private var editing: Bool
    private func clamp(_ v: Double) -> Double { min(max(((v - range.lowerBound) / step).rounded() * step + range.lowerBound, range.lowerBound), range.upperBound) }
    private func commit() {
        if let v = Double(text.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)) { value = clamp(v) }
        text = String(format: format, value)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 12) {
                Text(title).frame(width: 200, alignment: .leading).lineLimit(2)
                // Quantise in the binding instead of Slider(step:), which draws a tick mark per step.
                Slider(value: Binding(get: { value }, set: { value = clamp($0) }), in: range)
                    .frame(minWidth: 260, maxWidth: .infinity)
                TextField("", text: $text)
                    .textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing).monospacedDigit().frame(width: 64)
                    .focused($editing).onSubmit(commit)
                    .onChange(of: editing) { if !$0 { commit() } }
                if !unit.isEmpty { Text(unit).foregroundStyle(.secondary).frame(width: 30, alignment: .leading) }
            }
            .onAppear { text = String(format: format, value) }
            .onChange(of: value) { text = String(format: format, $0) }
            if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
        }.padding(.vertical, 2)
    }
}

/// Same, for Int-backed settings.
struct IntSliderRow: View {
    let title: LocalizedStringKey
    var detail: LocalizedStringKey? = nil
    @Binding var value: Int
    let range: ClosedRange<Int>
    var step = 1
    var unit = ""
    var body: some View {
        SliderRow(title: title, detail: detail,
                  value: Binding(get: { Double(value) }, set: { value = Int($0.rounded()) }),
                  range: Double(range.lowerBound)...Double(range.upperBound), step: Double(step), unit: unit)
    }
}

/// A toggle with an explanatory line underneath.
struct ToggleRow: View {
    let title: LocalizedStringKey
    var detail: LocalizedStringKey? = nil
    @Binding var isOn: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Toggle(title, isOn: $isOn)
            if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
        }.padding(.vertical, 1)
    }
}

struct StatusDot: View {
    let color: Color
    var body: some View { Circle().fill(color).frame(width: 9, height: 9).shadow(color: color.opacity(0.6), radius: 3) }
}

/// Page scaffold: large title, optional subtitle, scrollable grouped content.
struct Page<Content: View>: View {
    let title: LocalizedStringKey
    var subtitle: LocalizedStringKey? = nil
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.largeTitle.weight(.bold))
                if let subtitle { Text(subtitle).foregroundStyle(.secondary) }
            }.padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 4)
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// Permission row with a state badge and a button that opens the right Privacy pane.
struct PermissionRow: View {
    let title: LocalizedStringKey, detail: LocalizedStringKey
    let granted: Bool
    let action: () -> Void
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.title3).foregroundStyle(granted ? .green : .orange)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).fontWeight(.medium)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !granted { Button("Open Settings", action: action).controlSize(.small) }
        }.padding(.vertical, 2)
    }
}


/// Large tile button used for the quick tools.
struct ToolTile: View {
    let symbol: String, title: LocalizedStringKey
    let color: Color
    var iconSize: CGFloat = 40
    var minHeight: CGFloat = 86
    var font: Font = .callout
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                IconTile(symbol: symbol, color: color, size: iconSize)
                Text(title).font(font).lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: minHeight)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(hover ? Color.primary.opacity(0.14) : Color.primary.opacity(0.08)))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain).onHover { hover = $0 }
    }
}

// MARK: touch-friendly menus
// NSMenu tracking does not cope with a touch screen (it closes as soon as the pointer jumps), so menus are popovers
// made of ordinary buttons.
private struct PopDismissKey: EnvironmentKey { static let defaultValue: () -> Void = {} }
extension EnvironmentValues { fileprivate var popDismiss: () -> Void { get { self[PopDismissKey.self] } set { self[PopDismissKey.self] = newValue } } }

struct PopMenu<Label: View, Content: View>: View {
    @ViewBuilder var content: () -> Content
    @ViewBuilder var label: () -> Label
    @State private var shown = false
    var body: some View {
        Button { shown.toggle() } label: { HStack(spacing: 4) { label(); Image(systemName: "chevron.down").font(.caption2.weight(.bold)) } }
            .popover(isPresented: $shown, arrowEdge: .bottom) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) { content() }
                        .environment(\.popDismiss, { shown = false })
                        .padding(8)
                }.frame(minWidth: 280, maxHeight: 460)
            }
    }
}

struct PopItem: View {
    let title: String
    var enabled = true
    var checked = false
    let action: () -> Void
    @Environment(\.popDismiss) private var dismiss
    @State private var hover = false
    var body: some View {
        Button { dismiss(); action() } label: {
            HStack { Text(title); Spacer(minLength: 8); if checked { Image(systemName: "checkmark") } }
                .padding(.horizontal, 10).frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6).fill(hover && enabled ? Color.accentColor.opacity(0.25) : .clear))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(!enabled).opacity(enabled ? 1 : 0.45).onHover { hover = $0 }
    }
}

struct PopHeader: View {
    let title: String
    var body: some View { Text(LocalizedStringKey(title)).font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal, 10).padding(.top, 8) }
}
