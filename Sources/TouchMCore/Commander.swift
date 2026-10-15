import AppKit
import ApplicationServices

/// Commander: rule matching, UI-element context detection and action execution.
public enum Commander {
    /// Set from Settings.tabletScroll: rules tagged "tablet" are ignored while this is false.
    public static var tabletEnabled = true
    /// The gesture that opens the magnifier. Rules written for exactly this gesture are ignored.
    public static var reservedGesture: String?
    private static var accessibilityEnabledPids = Set<pid_t>()

    /// Actions implemented by the host app (e.g. the magnifier), keyed by action name.
    public static var customActions: [String: (CommanderRule, CGPoint) -> Void] = [:]

    /// Direction of the most recent rotate gesture (set by the engine just before it fires).
    public static var lastRotationClockwise = true

    // MARK: context
    /// How specific a rule is: an app-specific rule outranks a UI-element rule, which outranks a global one.
    public static func specificity(_ r: CommanderRule) -> Int {
        ((r.appId?.isEmpty ?? true) || r.appId == "___global___" ? 0 : 8) + ((r.role?.isEmpty ?? true) ? 0 : 4) + ((r.modifiers?.isEmpty ?? true) ? 0 : 2)
    }

    private static var lastOtherApp: String?
    private static var tracking: NSObjectProtocol?
    /// The active app, as rules see it. TouchM itself never counts: after its settings window, magnifier or annotation
    /// has been used it can stay "active", which would hide every app-specific rule.
    public static func frontmostAppId() -> String? {
        let own = Bundle.main.bundleIdentifier
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        if let f = front, f != own { lastOtherApp = f; return f }
        return lastOtherApp ?? front
    }
    /// Remember the last app that was not TouchM so it is known even while TouchM holds focus.
    public static func startTrackingActiveApp() {
        guard tracking == nil else { return }
        _ = frontmostAppId()
        tracking = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { n in
            if let a = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication, let id = a.bundleIdentifier, id != Bundle.main.bundleIdentifier { lastOtherApp = id }
        }
    }

    /// AX roles of the element under `p` and its ancestors, plus special contexts (titlebar, file dialog).
    public static func roles(at p: CGPoint) -> Set<String> {
        var out = Set<String>()
        var el: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(p.x), Float(p.y), &el) == .success, var cur = el else { return out }
        // Chromium / Electron only build their accessibility tree when asked; without it web pages have no AXWebArea.
        var pid: pid_t = 0
        if AXUIElementGetPid(cur, &pid) == .success, !accessibilityEnabledPids.contains(pid) {
            accessibilityEnabledPids.insert(pid)
            AXUIElementSetAttributeValue(AXUIElementCreateApplication(pid), "AXManualAccessibility" as CFString, kCFBooleanTrue)
        }
        for depth in 0..<12 {
            if let r = attr(cur, kAXRoleAttribute) as? String {
                out.insert(r)
                // Sliders, scroll bars, fields... must be dragged, not scrolled, even inside a scroll area (tablet rules skip them).
                if depth < 2, Self.dragControls.contains(r) { out.insert("__drag_control") }
                if r == "AXSheet" { out.insert("file dialog") }
                if r == "AXWindow", let sub = attr(cur, kAXSubroleAttribute) as? String, sub == "AXDialog" || sub == "AXSystemDialog" { out.insert("file dialog") }
                if r == "AXWindow", let pos = point(cur, kAXPositionAttribute), p.y - pos.y < 30 { out.insert("titlebar") }
            }
            guard let parent = attr(cur, kAXParentAttribute) else { break }
            cur = parent as! AXUIElement
        }
        return out
    }
    /// macOS Keyboard Viewer (an on-screen keyboard you can tap), toggled through the input menu in the menu bar.
    /// Needs "Show Input menu in menu bar" (System Settings > Keyboard > Text Input).
    public static func toggleKeyboardViewer() {
        DispatchQueue.global(qos: .userInitiated).async {
            guard let agent = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.TextInputMenuAgent").first else { TMLog.write("keyboard viewer: input menu agent not running"); return }
            let app = AXUIElementCreateApplication(agent.processIdentifier)
            func kids(_ e: AXUIElement) -> [AXUIElement] { (attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] }
            guard let bar = attr(app, "AXExtrasMenuBar") as! AXUIElement?, let item = kids(bar).first else { TMLog.write("keyboard viewer: input menu not in the menu bar"); return }
            func pick() -> Bool {
                for menu in kids(item) {
                    for e in kids(menu) {
                        let t = ((attr(e, kAXTitleAttribute) as? String) ?? "").precomposedStringWithCanonicalMapping
                        if t.localizedCaseInsensitiveContains("Keyboard Viewer") || t.contains("키보드 뷰어") { AXUIElementPerformAction(e, kAXPressAction as CFString); return true }
                    }
                }
                return false
            }
            let t0 = Date()
            // The agent fills its closed menu lazily: the first look can see only part of it, so look again a few times.
            for _ in 0..<6 {
                if pick() { TMLog.write(String(format: "keyboard viewer: pressed directly in %.0f ms", Date().timeIntervalSince(t0) * 1000)); return }
                usleep(60_000)
            }                       // the closed menu's items can be pressed directly, so nothing flashes on screen
            AXUIElementPerformAction(item, kAXPressAction as CFString)   // fall back to opening the menu
            usleep(250_000)
            TMLog.write("keyboard viewer: had to open the menu (closed menu showed \(kids(item).map { kids($0).count }) entries)")
            if pick() { return }
            let menu = kids(item).first
            TMLog.write("keyboard viewer: menu item not found")
            if let m = menu { AXUIElementPerformAction(m, kAXCancelAction as CFString) }
        }
    }
    static let dragControls: Set<String> = ["AXSlider", "AXScrollBar", "AXValueIndicator", "AXSplitter", "AXIncrementor", "AXColorWell", "AXTextField", "AXTextArea", "AXSearchField", "AXStepper"]
    private static func attr(_ e: AXUIElement, _ a: String) -> AnyObject? {
        var v: CFTypeRef?; return AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success ? v : nil
    }
    private static func point(_ e: AXUIElement, _ a: String) -> CGPoint? {
        guard let v = attr(e, a), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var p = CGPoint.zero; return AXValueGetValue(v as! AXValue, .cgPoint, &p) ? p : nil
    }

    // MARK: matching
    static func gestureMatches(rule: String, actual: String) -> Int {      // 0 = no, 2 = exact, 1 = alias
        if rule == actual { return 2 }
        for (alias, dirs) in [("horizontal", ["left", "right"]), ("vertical", ["up", "down"])] where rule.hasSuffix("swipe \(alias)") {
            let prefix = String(rule.dropLast(alias.count))
            if dirs.contains(where: { prefix + $0 == actual }) { return 1 }
        }
        return 0
    }

    /// Most specific enabled rule: app + role beat app, which beats role, which beats global.
    public static func match(_ rules: [CommanderRule], gesture: String, appId: String?, roles: Set<String>, modifiers: NSEvent.ModifierFlags) -> CommanderRule? {
        var best: (score: Int, rule: CommanderRule)?
        for r in rules where r.enabled && (r.tag != "tablet" || tabletEnabled) && r.gesture != reservedGesture {
            let g = gestureMatches(rule: r.gesture, actual: gesture); guard g > 0 else { continue }
            if let a = r.appId, !a.isEmpty, a != "___global___", a != appId { continue }
            if let role = r.role, !role.isEmpty, !roles.contains(role) { continue }
            if r.tag == "tablet", roles.contains("__drag_control") { continue }
            if let need = r.modifiers, !need.isEmpty {
                let have = Set([modifiers.contains(.command) ? "cmd" : "", modifiers.contains(.shift) ? "shift" : "",
                                modifiers.contains(.option) ? "alt" : "", modifiers.contains(.control) ? "ctrl" : ""].filter { !$0.isEmpty })
                if have != Set(need) { continue }
            }
            let score = specificity(r) + g
            if best == nil || score >= best!.score { best = (score, r) }      // on a tie the rule added last wins, so your own rules beat the defaults
        }
        return best?.rule
    }

    /// Resolve with live context (frontmost app, AX roles at the point, held modifiers).
    public static func resolve(_ rules: [CommanderRule], gesture: String, at p: CGPoint) -> CommanderRule? {
        let needsRoles = rules.contains { $0.enabled && ($0.role?.isEmpty == false) && gestureMatches(rule: $0.gesture, actual: gesture) > 0 }
        return match(rules, gesture: gesture, appId: frontmostAppId(), roles: needsRoles ? roles(at: p) : [], modifiers: NSEvent.modifierFlags)
    }

    // MARK: actions
    public static func run(_ r: CommanderRule, gesture: String, at p: CGPoint, injector inj: Injector, nearestPx: Double = 30) {
        let prm = r.params ?? [:]
        let b = CGDisplayBounds(CGMainDisplayID())
        switch r.action {
        case "none", "scroll", "click and drag": break                       // handled by the engine
        case "click":
            let target = (prm["click nearest"] == "true") ? nearestClickable(p, threshold: Double(prm["threshold"] ?? "") ?? nearestPx) : p
            inj.move(target)
            if (Int(prm["click button"] ?? "1") ?? 1) == 2 { inj.rightClick(target) }
            else { inj.click(target) }
        case "move cursor": inj.move(p)
        case "mission control":
            // Launching the system app works even when the keyboard shortcut is disabled.
            let url = URL(fileURLWithPath: "/System/Applications/Mission Control.app")
            if FileManager.default.fileExists(atPath: url.path) { NSWorkspace.shared.open(url) } else { inj.key("ctrl+up") }
        case "show app windows":
            if !dockExpose() { inj.key("ctrl+down") }
        case "swipe between spaces":
            let left = prm["direction"].map { $0 == "left" } ?? gesture.contains("left")
            inj.key(left ? "ctrl+right" : "ctrl+left")                       // content follows the fingers
        case "desktop launchpad":
            for path in ["/System/Applications/Apps.app", "/System/Applications/Launchpad.app"] where FileManager.default.fileExists(atPath: path) {
                NSWorkspace.shared.open(URL(fileURLWithPath: path)); break
            }
        case "notification center":
            let q = CGPoint(x: b.maxX - 45, y: b.minY + 12); inj.move(q); inj.click(q)
        case "keyboard viewer": toggleKeyboardViewer()
        case "look up in dictionary": inj.move(p); inj.key("ctrl+cmd+d")
        case "show hide dock":
            // An auto-hidden Dock opens when the pointer is pushed into the screen edge and stays there a moment; a single jump is not
            // always enough, so approach the edge in steps and keep pressing against it.
            let ys: [Double] = [b.maxY - 80, b.maxY - 40, b.maxY - 15, b.maxY - 4, b.maxY - 1, b.maxY - 1, b.maxY - 1, b.maxY - 1]
            for (i, y) in ys.enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.05) { inj.move(CGPoint(x: b.midX, y: y)) }
            }
        case "adjust magnification": inj.key(gesture.contains("contract") ? "cmd+-" : "cmd+=")
        case "rotate":
            // macOS exposes no public API for rotation gestures; use the apps' own shortcuts (Preview: ⌘L / ⌘R).
            let ccw = prm["counterclockwise key"] ?? "cmd+l", cw = prm["clockwise key"] ?? "cmd+r"
            inj.key(lastRotationClockwise ? cw : ccw)
        case "keystroke": if let k = prm["key"] { inj.key(k) }
        case "open app":
            if let a = prm["app"] {
                if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: a) { NSWorkspace.shared.openApplication(at: url, configuration: .init()) }
                else { NSWorkspace.shared.launchApplication(a) }
            }
        case "open url": if let u = prm["url"].flatMap(URL.init(string:)) { NSWorkspace.shared.open(u) }
        case "run shell command": if let c = prm["command"] { spawn("/bin/zsh", ["-c", c]) }
        case "run applescript": if let c = prm["script"] { spawn("/usr/bin/osascript", ["-e", c]) }
        default: customActions[r.action]?(r, p)
        }
    }

    /// App Exposé: perform AXShowExpose on the frontmost app's Dock item.
    static func dockExpose() -> Bool {
        guard let front = NSWorkspace.shared.frontmostApplication?.localizedName,
              let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return false }
        func find(_ e: AXUIElement, depth: Int) -> AXUIElement? {
            if depth > 4 { return nil }
            if (attr(e, kAXTitleAttribute) as? String) == front, (attr(e, kAXRoleAttribute) as? String) == "AXDockItem" { return e }
            for c in (attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] { if let f = find(c, depth: depth + 1) { return f } }
            return nil
        }
        guard let item = find(AXUIElementCreateApplication(dock.processIdentifier), depth: 0) else { TMLog.write("dock item for \(front) not found"); return false }
        let r = AXUIElementPerformAction(item, "AXShowExpose" as CFString)
        TMLog.write("AXShowExpose on \(front): \(r.rawValue)")
        return r == .success
    }

    private static func spawn(_ exe: String, _ args: [String]) {
        let p = Process(); p.executableURL = URL(fileURLWithPath: exe); p.arguments = args; try? p.run()
    }

    static let clickable: Set<String> = ["AXButton", "AXLink", "AXCheckBox", "AXRadioButton", "AXMenuItem", "AXMenuBarItem",
                                         "AXPopUpButton", "AXMenuButton", "AXTabGroup", "AXTextField", "AXComboBox", "AXDisclosureTriangle"]
    /// "Click the nearest clickable UI element".
    public static func nearestClickable(_ p: CGPoint, threshold: Double) -> CGPoint {
        func role(_ q: CGPoint) -> String? {
            var el: AXUIElement?
            guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(q.x), Float(q.y), &el) == .success, let e = el else { return nil }
            return attr(e, kAXRoleAttribute) as? String
        }
        if let r = role(p), clickable.contains(r) { return p }
        var radius = 8.0
        while radius <= threshold {
            for k in 0..<12 {
                let a = Double(k) / 12 * 2 * .pi, q = CGPoint(x: p.x + cos(a) * radius, y: p.y + sin(a) * radius)
                if let r = role(q), clickable.contains(r) { return q }
            }
            radius += 8
        }
        return p
    }
}
