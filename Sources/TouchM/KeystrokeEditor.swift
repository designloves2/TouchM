import SwiftUI
import AppKit
import TouchMCore

/// Edits a shortcut stored as "ctrl+shift+left". Pick the key from a list (arrows, navigation, function keys…)
/// or press "Record" and type it.
struct KeystrokeEditor: View {
    @Binding var combo: String
    @State private var recording = false
    @State private var monitor: Any?

    private static let mods: [(id: String, label: String)] = [("ctrl", "⌃"), ("alt", "⌥"), ("shift", "⇧"), ("cmd", "⌘"), ("fn", "fn")]
    private static let arrows = [("left", "←  Left Arrow"), ("right", "→  Right Arrow"), ("up", "↑  Up Arrow"), ("down", "↓  Down Arrow")]
    private static let nav = [("home", "Home"), ("end", "End"), ("pageup", "Page Up"), ("pagedown", "Page Down")]
    private static let editing = [("return", "Return"), ("tab", "Tab"), ("space", "Space"), ("delete", "Delete"), ("forwarddelete", "Forward Delete"), ("escape", "Esc")]
    private static let function = (1...12).map { ("f\($0)", "F\($0)") }
    private static let letters = "abcdefghijklmnopqrstuvwxyz".map { (String($0), String($0).uppercased()) }
    private static let digits = "0123456789".map { (String($0), String($0)) }
    private static let symbols = [("=", "="), ("-", "−"), ("[", "["), ("]", "]"), (";", ";"), ("'", "'"), (",", ","), (".", "."), ("/", "/"), ("\\", "\\"), ("`", "`")]

    private var parts: [String] { combo.lowercased().split(separator: "+", omittingEmptySubsequences: true).map(String.init) }
    private var key: String { parts.last.flatMap { Self.mods.map(\.id).contains($0) ? nil : $0 } ?? "" }
    private var activeMods: Set<String> { Set(parts.filter { Self.mods.map(\.id).contains($0) && $0 != key }) }

    private func set(mods: Set<String>, key: String) {
        let ordered = Self.mods.map(\.id).filter { mods.contains($0) }
        combo = (ordered + (key.isEmpty ? [] : [key])).joined(separator: "+")
    }

    private func pretty(_ k: String) -> String {
        (Self.arrows + Self.nav + Self.editing + Self.function + Self.letters + Self.digits + Self.symbols).first { $0.0 == k }?.1 ?? k
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                ForEach(Self.mods, id: \.id) { m in
                    Toggle(m.label, isOn: Binding(get: { activeMods.contains(m.id) },
                                                  set: { on in var a = activeMods; if on { a.insert(m.id) } else { a.remove(m.id) }; set(mods: a, key: key) }))
                        .toggleStyle(.button)
                }
                PopMenu {
                    PopHeader(title: "Arrows"); ForEach(Self.arrows, id: \.0) { item in PopItem(title: item.1, checked: key == item.0) { set(mods: activeMods, key: item.0) } }
                    PopHeader(title: "Navigation"); ForEach(Self.nav, id: \.0) { item in PopItem(title: item.1, checked: key == item.0) { set(mods: activeMods, key: item.0) } }
                    PopHeader(title: "Editing"); ForEach(Self.editing, id: \.0) { item in PopItem(title: item.1, checked: key == item.0) { set(mods: activeMods, key: item.0) } }
                    PopHeader(title: "Function keys"); ForEach(Self.function, id: \.0) { item in PopItem(title: item.1, checked: key == item.0) { set(mods: activeMods, key: item.0) } }
                    PopHeader(title: "Letters"); ForEach(Self.letters, id: \.0) { item in PopItem(title: item.1, checked: key == item.0) { set(mods: activeMods, key: item.0) } }
                    PopHeader(title: "Numbers"); ForEach(Self.digits, id: \.0) { item in PopItem(title: item.1, checked: key == item.0) { set(mods: activeMods, key: item.0) } }
                    PopHeader(title: "Symbols"); ForEach(Self.symbols, id: \.0) { item in PopItem(title: item.1, checked: key == item.0) { set(mods: activeMods, key: item.0) } }
                } label: { Text(key.isEmpty ? "Choose key" : pretty(key)).frame(minWidth: 96) }.fixedSize()
                Button(recording ? "Press a key…" : "Record") { recording ? stopRecording() : startRecording() }
                    .buttonStyle(.bordered).tint(recording ? .red : nil)
            }
            Text(summary).font(.caption).foregroundStyle(.secondary)
        }
        .onDisappear(perform: stopRecording)
    }

    private var summary: String {
        if key.isEmpty { return "No key chosen yet. Pick one above, or press Record and type the shortcut (arrow keys work)." }
        let sym = Self.mods.filter { activeMods.contains($0.id) }.map(\.label).joined()
        return "Sends \(sym)\(pretty(key))  ·  stored as “\(combo)”"
    }

    // MARK: recording
    private func startRecording() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            // Esc cancels (pick it from the list if you really want to send Esc).
            if e.keyCode == 53 && e.modifierFlags.intersection([.command, .shift, .option, .control]).isEmpty { stopRecording(); return nil }
            guard let name = Injector.name(forKeyCode: CGKeyCode(e.keyCode)) else { NSSound.beep(); return nil }
            var m = Set<String>()
            let f = e.modifierFlags
            if f.contains(.control) { m.insert("ctrl") }; if f.contains(.option) { m.insert("alt") }
            if f.contains(.shift) { m.insert("shift") }; if f.contains(.command) { m.insert("cmd") }
            set(mods: m, key: name)
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        recording = false
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
    }
}
