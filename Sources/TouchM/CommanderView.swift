import SwiftUI
import TouchMCore
import UniformTypeIdentifiers

/// Rule editor: Applications | Contexts | Gestures, with an action editor underneath.
struct CommanderView: View {
    @EnvironmentObject var model: AppModel
    @State private var app: String                 // "" = any application
    @State private var context = ""             // "" = anywhere
    @State private var selected: UUID?
    init(startApp: String = "", select: UUID? = nil) { _app = State(initialValue: startApp); _selected = State(initialValue: select) }
    @State private var extraApps: [String] = []
    @State private var extraContexts: [String] = []
    @State private var notice: String?

    static let contextPresets: [(String, String)] = [
        ("Scrollable areas", "AXScrollArea"), ("Web content", "AXWebArea"), ("Menu bar", "AXMenuBar"),
        ("Menu items", "AXMenuItem"), ("Window title bars", "titlebar"), ("File dialogs", "file dialog"),
        ("Buttons", "AXButton"), ("Text fields", "AXTextField"), ("Lists / tables", "AXList"), ("Toolbars", "AXToolbar"),
    ]
    static func contextLabel(_ role: String) -> String { role.isEmpty ? "Anywhere" : (contextPresets.first { $0.1 == role }?.0 ?? role) }

    /// ["cmd", "shift"] -> "⇧⌘"
    static func symbols(_ mods: [String]) -> String {
        let order = ["ctrl": "⌃", "alt": "⌥", "shift": "⇧", "cmd": "⌘", "fn": "fn"]
        return ["ctrl", "alt", "shift", "cmd", "fn"].filter { mods.contains($0) }.compactMap { order[$0] }.joined()
    }

    func sectionTitle(_ t: String) -> some View {
        Text(LocalizedStringKey(t)).font(.caption.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
    }

    var reserved: String { model.settings.magnifierGesture }

    /// A rule in the open scope (app + context) that already covers this gesture with these held keys.
    func existing(_ gesture: String, mods: [String]?, excluding: UUID? = nil) -> CommanderRule? {
        model.settings.commands.first {
            $0.id != excluding && ($0.appId ?? "") == app && ($0.role ?? "") == context && $0.gesture == gesture && Set($0.modifiers ?? []) == Set(mods ?? [])
        }
    }

    func say(_ text: String) {
        notice = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { if notice == text { notice = nil } }
    }

    /// Rules that never run because a later, enabled rule covers the same situation.
    var shadowed: Set<UUID> {
        let rules = model.settings.commands
        var out = Set<UUID>()
        for (i, r) in rules.enumerated() where r.enabled && r.gesture != reserved {
            if rules[(i + 1)...].contains(where: { $0.enabled && $0.competes(with: r) }) { out.insert(r.id) }
        }
        return out
    }

    // MARK: derived
    var apps: [String] {
        let used = Set(model.settings.commands.compactMap { $0.appId }.filter { !$0.isEmpty })
        return Array(used.union(extraApps)).sorted()
    }
    var contexts: [String] {
        let used = Set(model.settings.commands.filter { ($0.appId ?? "") == app }.compactMap { $0.role }.filter { !$0.isEmpty })
        return [""] + Array(used.union(extraContexts)).sorted()
    }
    func inScope(_ r: CommanderRule) -> Bool { (r.appId ?? "") == app && (r.role ?? "") == context }
    var scoped: [Binding<CommanderRule>] {
        $model.settings.commands.filter { inScope($0.wrappedValue) }.map { $0 }
    }

    var body: some View {
        VStack(spacing: 12) {
            toolbar.padding(.top, 10)
            HStack(alignment: .top, spacing: 16) {
                appList.frame(width: 140).frame(maxHeight: .infinity)
                contextList.frame(width: 140).frame(maxHeight: .infinity, alignment: .top)
                VStack(spacing: 12) { gestureTable.frame(maxHeight: .infinity); editor }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }.frame(maxHeight: .infinity)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: toolbar
    var toolbar: some View {
        HStack {
            Button("Import rules…") { model.importPreset() }
            Button("Export rules…") { exportRules() }
            PopMenu {
                PopItem(title: String(localized: "Remove overlapping rules (\(shadowed.count))"), enabled: !shadowed.isEmpty) {
                    let gone = shadowed
                    model.settings.commands.removeAll { gone.contains($0.id) }
                    say("Removed \(gone.count) rule(s) that were hidden by a later rule.")
                }
                PopItem(title: String(localized: "Reset to TouchM defaults")) { model.settings.commands = CommanderRule.defaults }
                PopItem(title: String(localized: "Remove all rules")) { model.settings.commands = [] }
            } label: { Text("Presets") }.fixedSize()
            Spacer()
            Text(model.importNote).font(.caption).foregroundStyle(.secondary)
        }
    }
    func exportRules() {
        let p = NSSavePanel(); p.nameFieldStringValue = "TouchM-commander.json"
        if p.runModal() == .OK, let u = p.url { let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]; try? e.encode(model.settings.commands).write(to: u) }
    }

    // MARK: applications
    var appList: some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionTitle("Applications")
            List(selection: Binding(get: { app }, set: { app = $0 ?? ""; context = ""; selected = nil })) {
                Text("Any application").tag("")
                ForEach(apps, id: \.self) { Text(appName($0)).tag($0) }
            }.listStyle(.inset).frame(minHeight: 160, maxHeight: .infinity).clipShape(RoundedRectangle(cornerRadius: 8))
            HStack {
                PopMenu {
                    ForEach(NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil }, id: \.bundleIdentifier) { a in
                        PopItem(title: a.localizedName ?? a.bundleIdentifier!) { addApp(a.bundleIdentifier!) }
                    }
                    Divider(); PopItem(title: String(localized: "Choose application…")) { chooseApp() }
                } label: { Image(systemName: "plus") }.fixedSize()
                Button { removeApp() } label: { Image(systemName: "minus") }.disabled(app.isEmpty)
            }
        }
    }
    func appName(_ id: String) -> String {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: id).map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? id
    }
    func addApp(_ id: String) { if !extraApps.contains(id) { extraApps.append(id) }; app = id; context = "" }
    func chooseApp() {
        let p = NSOpenPanel(); p.allowedContentTypes = [.application]; p.directoryURL = URL(fileURLWithPath: "/Applications")
        if p.runModal() == .OK, let u = p.url, let id = Bundle(url: u)?.bundleIdentifier { addApp(id) }
    }
    func removeApp() {
        model.settings.commands.removeAll { ($0.appId ?? "") == app }; extraApps.removeAll { $0 == app }; app = ""; context = ""
    }

    // MARK: contexts
    var contextList: some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionTitle("Contexts")
            List(selection: Binding(get: { context }, set: { context = $0 ?? ""; selected = nil })) {
                ForEach(contexts, id: \.self) { Text(Names.context(Self.contextLabel($0))).tag($0) }
            }.listStyle(.inset).frame(minHeight: 160, maxHeight: .infinity).clipShape(RoundedRectangle(cornerRadius: 8))
            HStack {
                PopMenu {
                    ForEach(Self.contextPresets, id: \.1) { p in PopItem(title: Names.context(p.0)) { addContext(p.1) } }
                    Divider(); PopItem(title: String(localized: "Other AX role…")) { promptRole() }
                } label: { Image(systemName: "plus") }.fixedSize()
                Button { model.settings.commands.removeAll { inScope($0) }; extraContexts.removeAll { $0 == context }; context = "" } label: { Image(systemName: "minus") }
                    .disabled(context.isEmpty)
            }
            Text("Limits rules to a kind of UI element under the touch.").font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
    func addContext(_ r: String) { if !extraContexts.contains(r) { extraContexts.append(r) }; context = r }
    func promptRole() {
        let a = NSAlert(); a.messageText = "AX role"; a.informativeText = "e.g. AXOutline, AXImage, AXSlider"
        let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24)); a.accessoryView = f; a.addButton(withTitle: "Add"); a.addButton(withTitle: "Cancel")
        if a.runModal() == .alertFirstButtonReturn, !f.stringValue.isEmpty { addContext(f.stringValue) }
    }

    // MARK: gestures
    var gestureTable: some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionTitle("Gestures")
            List(selection: $selected) {
                ForEach(scoped) { $r in
                    HStack(spacing: 8) {
                        if r.gesture == reserved {
                            Image(systemName: "lock.fill").foregroundStyle(.secondary).help("Used by the magnifier. Change it in Settings → Magnifier.")
                        } else {
                            Toggle("", isOn: $r.enabled).labelsHidden().toggleStyle(.checkbox)
                        }
                        Text(Names.gesture(r.gesture)).lineLimit(1).truncationMode(.tail).opacity(r.gesture == reserved ? 0.45 : 1)
                        if let m = r.modifiers, !m.isEmpty { Text("only while " + Self.symbols(m) + " held").font(.caption2).padding(.horizontal, 6).padding(.vertical, 1).background(.orange.opacity(0.25), in: Capsule()) }
                        Spacer(minLength: 8)
                        if shadowed.contains(r.id) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                                .help("Another rule below uses this same gesture here, so this one never runs. Delete or change one of them.")
                        }
                        Text(summary(r)).lineLimit(1).foregroundStyle(.secondary).frame(width: 135, alignment: .trailing).font(.callout)
                    }.tag(r.id)
                }
            }.listStyle(.inset).frame(minHeight: 160, maxHeight: .infinity).clipShape(RoundedRectangle(cornerRadius: 8))
            HStack {
                PopMenu {
                    ForEach(Self.categories, id: \.0) { cat in
                        PopHeader(title: cat.0)
                        ForEach(cat.1, id: \.self) { g in
                            PopItem(title: g == reserved ? "\(Names.gesture(g)) — " + String(localized: "used by magnifier") : (existing(g, mods: nil) != nil ? "\(Names.gesture(g)) — " + String(localized: "already used") : Names.gesture(g)),
                                    enabled: g != reserved && existing(g, mods: nil) == nil) { addGesture(g) }
                        }
                    }
                } label: { Text("Add gesture") }.fixedSize()
                Button("Duplicate") { duplicate() }.disabled(selected == nil)
                Button("Delete") { if let s = selected { model.settings.commands.removeAll { $0.id == s }; selected = nil } }.disabled(selected == nil)
            }
            if let notice { Label(notice, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.orange).transition(.opacity) }
        }
    }
    static let categories: [(String, [String])] = {
        let all = CommanderRule.gestureNames
        return [("Tap & press", all.filter { $0.contains("tap") || $0.contains("press") }),
                ("Drag", all.filter { $0.hasSuffix("drag") }),
                ("Swipe", all.filter { $0.contains("swipe") && !$0.contains("edge") }),
                ("Edge swipe", all.filter { $0.contains("edge") }),
                ("Pinch & rotate", all.filter { $0.contains("pinch") || $0.contains("rotate") })]
    }()
    func summary(_ r: CommanderRule) -> String {
        let p = r.params ?? [:]
        switch r.action {
        case "click": return Names.action("click") + (p["click button"] == "2" ? (Names.korean ? " (오른쪽)" : " (right)") : "") + (p["click nearest"] == "true" ? (Names.korean ? ", 가장 가까운" : ", nearest") : "")
        case "keystroke": return (Names.korean ? "키 " : "key ") + (p["key"] ?? "?")
        case "open app": return (Names.korean ? "열기 " : "open ") + (p["app"] ?? "?")
        case "open url": return p["url"] ?? "url"
        case "run shell command": return Names.korean ? "셸" : "shell"
        case "run applescript": return "AppleScript"
        default: return Names.action(r.action)
        }
    }
    func addGesture(_ g: String) {
        if let e = existing(g, mods: nil) {
            selected = e.id
            say("“\(Names.gesture(g))” already has a rule here. Edit that one, or give it a modifier key.")
            return
        }
        let r = CommanderRule(gesture: g, action: "none", appId: app.isEmpty ? nil : app, role: context.isEmpty ? nil : context)
        model.settings.commands.append(r); selected = r.id
    }
    func duplicate() {
        guard let sel = selected, var r = model.settings.commands.first(where: { $0.id == sel }) else { return }
        // An identical copy would clash with the original, so the copy gets the first free modifier key.
        for m in ["shift", "alt", "ctrl", "cmd"] {
            let mods = (r.modifiers ?? []) + [m]
            if existing(r.gesture, mods: mods) == nil {
                r.id = UUID(); r.modifiers = mods
                model.settings.commands.append(r); selected = r.id
                say("Copied with \(m) held so it does not clash with the original.")
                return
            }
        }
        say("Every modifier combination of this gesture is already used.")
    }

    // MARK: editor
    @ViewBuilder var editor: some View {
        if let i = model.settings.commands.firstIndex(where: { $0.id == selected }) {
            let r = $model.settings.commands[i]
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("Gesture", selection: r.gesture) {
                        ForEach(CommanderRule.gestureNames.filter { g in
                            g == r.wrappedValue.gesture || (g != reserved && existing(g, mods: r.wrappedValue.modifiers, excluding: r.wrappedValue.id) == nil)
                        }, id: \.self) { Text(Names.gesture($0)).tag($0) }
                    }
                    Picker("Action", selection: r.action) { ForEach(CommanderRule.actionNames, id: \.self) { Text(Names.action($0)).tag($0) } }
                    HStack {
                        Text("Only while holding")
                        ForEach(["cmd", "shift", "alt", "ctrl"], id: \.self) { m in
                            Toggle(m, isOn: Binding(get: { r.wrappedValue.modifiers?.contains(m) ?? false },
                                                    set: { on in
                                var a = r.wrappedValue.modifiers ?? []; a.removeAll { $0 == m }; if on { a.append(m) }
                                let next = a.isEmpty ? nil : a
                                if existing(r.wrappedValue.gesture, mods: next, excluding: r.wrappedValue.id) != nil {
                                    say("Another rule already uses this gesture with those keys.")
                                } else { r.wrappedValue.modifiers = next }
                            }))
                                .toggleStyle(.checkbox)
                        }
                    }
                    if r.wrappedValue.action == "keystroke", let held = r.wrappedValue.modifiers, !held.isEmpty,
                       !(prm(r, "key").wrappedValue.isEmpty), !prm(r, "key").wrappedValue.contains("+") || prm(r, "key").wrappedValue == "+" {
                        VStack(alignment: .leading, spacing: 6) {
                            Label("This rule only runs while you hold \(Self.symbols(held)) on the keyboard.", systemImage: "exclamationmark.triangle.fill")
                                .font(.callout).foregroundStyle(.orange)
                            Text("If you wanted the swipe to press \(Self.symbols(held))+\(prm(r, "key").wrappedValue) instead, move the key into the shortcut:")
                                .font(.caption).foregroundStyle(.secondary)
                            Button("Send \(Self.symbols(held)) with the key instead") {
                                prm(r, "key").wrappedValue = (held + [prm(r, "key").wrappedValue]).joined(separator: "+")
                                r.wrappedValue.modifiers = nil
                            }.buttonStyle(.borderedProminent).controlSize(.small)
                        }
                        .padding(8).background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                    }
                    params(r)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            Text("Select a gesture to edit its action.").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 90)
                .background(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary, style: StrokeStyle(lineWidth: 1, dash: [4])))
        }
    }

    func prm(_ r: Binding<CommanderRule>, _ k: String) -> Binding<String> {
        Binding(get: { r.wrappedValue.params?[k] ?? "" },
                set: { v in var p = r.wrappedValue.params ?? [:]; if v.isEmpty { p.removeValue(forKey: k) } else { p[k] = v }; r.wrappedValue.params = p.isEmpty ? nil : p })
    }

    @ViewBuilder func params(_ r: Binding<CommanderRule>) -> some View {
        switch r.wrappedValue.action {
        case "click":
            Picker("Mouse button", selection: Binding(get: { prm(r, "click button").wrappedValue == "2" ? "2" : "1" }, set: { prm(r, "click button").wrappedValue = $0 })) {
                Text("Left").tag("1"); Text("Right").tag("2")
            }.pickerStyle(.segmented)
            Toggle("Click the nearest clickable UI element", isOn: Binding(get: { prm(r, "click nearest").wrappedValue == "true" }, set: { prm(r, "click nearest").wrappedValue = $0 ? "true" : "" }))
        case "swipe between spaces":
            Picker("Direction", selection: Binding(get: { prm(r, "direction").wrappedValue }, set: { prm(r, "direction").wrappedValue = $0 })) {
                Text("Follow swipe").tag(""); Text("Left").tag("left"); Text("Right").tag("right")
            }
        case "keystroke":
            KeystrokeEditor(combo: prm(r, "key"))
        case "open app":
            HStack { TextField("App name or bundle id", text: prm(r, "app")); Button("Choose…") {
                let p = NSOpenPanel(); p.allowedContentTypes = [.application]; p.directoryURL = URL(fileURLWithPath: "/Applications")
                if p.runModal() == .OK, let u = p.url { prm(r, "app").wrappedValue = Bundle(url: u)?.bundleIdentifier ?? u.path }
            } }
        case "open url": TextField("https://…", text: prm(r, "url"))
        case "run shell command":
            TextEditor(text: prm(r, "command")).font(.system(.body, design: .monospaced)).frame(height: 60).border(.secondary.opacity(0.4))
        case "run applescript":
            TextEditor(text: prm(r, "script")).font(.system(.body, design: .monospaced)).frame(height: 60).border(.secondary.opacity(0.4))
        case "adjust magnification": Text("Pinch zooms the front app with ⌘+ / ⌘−.").font(.caption).foregroundStyle(.secondary)
        default: EmptyView()
        }
    }
}
