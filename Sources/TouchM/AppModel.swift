import SwiftUI
import TouchMCore
import IOKit.hid
import UniformTypeIdentifiers

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()
    @Published var settings = Store.load() { didSet {
        if settings.magnifierGesture != oldValue.magnifierGesture { reserveMagnifierGesture() }
        Commander.reservedGesture = settings.magnifierGesture
        Store.save(settings); engine.settings = settings; Commander.tabletEnabled = settings.tabletScroll; Magnifier.shared.settingsChanged(); injector.clickLasts = Double(settings.clickLastsMs) / 1000; device.reinitOnWake = settings.reinitOnWake; applyLogin() } }
    @Published var status = "starting…"
    @Published var points: [CGPoint] = []
    @Published var live: [Contact] = []
    @Published var fps = 0
    private var frames = 0, lastLive = Date.distantPast, lastFps = Date()
    @Published var accessibilityOK = AXIsProcessTrusted()
    /// CGPreflightScreenCaptureAccess() can stay false after approval until relaunch, so a working capture counts too.
    @Published var screenCaptureWorks = false
    @Published var screenRecordingPreflight = CGPreflightScreenCaptureAccess()
    var screenRecordingOK: Bool { screenCaptureWorks || screenRecordingPreflight }
    @Published var inputMonitoringOK = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted

    let device = TouchDevice()
    let engine: GestureEngine
    private let lensAdapter = LensAdapter()
    let injector = Injector()
    /// Raw frames, used by the calibration wizard.
    var rawTap: (([Contact]) -> Void)?

    private init() {
        engine = GestureEngine(Store.load())
        engine.onPoints = { [weak self] p in
            self?.points = p; Overlay.shared.update(p)
            if let first = p.first { MainActor.assumeIsolated { Magnifier.shared.touch(first) } }
        }
        engine.lens = lensAdapter
        engine.onHoldVisual = { p, d in Overlay.shared.ring(at: p, duration: d) }
        engine.onHoldCancel = { Overlay.shared.cancelRing() }
        engine.onGesture = { [weak self] g, p in self?.runCommand(g, at: p) }
        engine.ruleLookup = { [weak self] g, p in
            guard let self else { return nil }
            return Commander.resolve(self.settings.commands, gesture: g, at: p)
        }
        engine.onPinchStep = { [weak self] dir, p in
            guard let self else { return }
            if Magnifier.shared.contains(p) || Magnifier.shared.isVisible { Task { @MainActor in Magnifier.shared.pinch(expand: dir > 0) }; return }
            let g = "two finger pinch " + (dir > 0 ? "expand" : "contract")
            if let r = Commander.resolve(self.settings.commands, gesture: g, at: p), r.action == "adjust magnification" {
                Commander.run(r, gesture: g, at: p, injector: self.injector, nearestPx: self.settings.clickNearestPx)
            }
        }
        device.onLog = { [weak self] m in Task { @MainActor in self?.status = m } }
        device.onFrame = { [weak self] cs in
            guard let self else { return }
            self.rawTap?(cs)
            self.frames += 1
            let now = Date()
            if now.timeIntervalSince(lastLive) > 0.066 || cs.isEmpty { lastLive = now; self.live = cs }
            if now.timeIntervalSince(lastFps) >= 1 { self.fps = self.frames; self.frames = 0; self.lastFps = now }
            if self.rawTap == nil { self.engine.handle(cs) }   // calibration swallows input
        }
    }

    func openPrivacy(_ pane: String) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
    }
    var permissionsOK: Bool { accessibilityOK && inputMonitoringOK }
    var statusLine: (text: String, color: Color) {
        if !permissionsOK { return ("Permissions needed", .orange) }
        if !device.connected { return ("Touch panel not found", .red) }
        if !settings.enabled { return ("Touch paused", .gray) }
        return ("Ready", .green)
    }

    func exportSettings() {
        let p = NSSavePanel(); p.nameFieldStringValue = "TouchM-settings.json"
        if p.runModal() == .OK, let u = p.url { let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]; try? e.encode(settings).write(to: u) }
    }
    func importSettings() {
        let p = NSOpenPanel(); p.allowedContentTypes = [.json]
        if p.runModal() == .OK, let u = p.url, let d = try? Data(contentsOf: u), let s = try? JSONDecoder().decode(Settings.self, from: d) { settings = s }
    }

    func start() {
        Commander.startTrackingActiveApp()
        let reapply = { Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            Brightness.shared.reapply(method: AppModel.shared.settings.brightnessMethod) } }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in reapply() }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in reapply() }
        reapply()
        Commander.reservedGesture = settings.magnifierGesture; Commander.tabletEnabled = settings.tabletScroll
        TMLog.write("launch: accessibility=\(AXIsProcessTrusted()) screenPreflight=\(CGPreflightScreenCaptureAccess())")
        _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        accessibilityOK = AXIsProcessTrustedWithOptions(opts)
        Timer.common(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.accessibilityOK = AXIsProcessTrusted()
                self.screenRecordingPreflight = CGPreflightScreenCaptureAccess()
                self.inputMonitoringOK = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
                self.objectWillChange.send()      // refreshes the menu-bar icon / connection state
            }
        }
        if !device.start() { status = "Cannot open touch device — grant Input Monitoring" }
    }

    func runCommand(_ gesture: String, at p: CGPoint) {
        if gesture == settings.magnifierGesture {
            TMLog.write("gesture '\(gesture)' -> magnifier")
            Task { @MainActor in Magnifier.shared.toggle(at: p) }
            return
        }
        let r0 = Commander.resolve(settings.commands, gesture: gesture, at: p)
        TMLog.write("gesture '\(gesture)' at (\(Int(p.x)),\(Int(p.y))) app=\(Commander.frontmostAppId() ?? "?") -> \(r0.map { ($0.appId ?? "").isEmpty ? "GLOBAL rule" : "APP rule" } ?? "no rule"): \(r0?.action ?? "NONE") accessibility=\(AXIsProcessTrusted())")
        guard let r = r0 else { return }
        if r.action == "adjust magnification" && gesture.contains("pinch") { return }   // already applied live
        Commander.run(r, gesture: gesture, at: p, injector: injector, nearestPx: settings.clickNearestPx)
    }

    @Published var importNote = ""

    /// Switch off Commander rules that use the magnifier's gesture, so the two never fight over it.
    private func reserveMagnifierGesture() {
        for i in settings.commands.indices where settings.commands[i].gesture == settings.magnifierGesture { settings.commands[i].enabled = false }
    }
    /// Imports rules from a TouchM export (.json: a rule list or a whole settings file) or an INI preset file.
    func importPreset() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json, .text, .data]
        panel.allowsOtherFileTypes = true
        panel.allowsMultipleSelection = true; panel.title = String(localized: "Import rules")
        panel.message = String(localized: "Choose a TouchM rules file (.json) or an INI preset file.")
        guard panel.runModal() == .OK else { return }
        var added = 0, skipped = 0, duplicates = 0
        for u in panel.urls {
            var incoming: [CommanderRule] = []
            var unusable = 0
            if let d = try? Data(contentsOf: u), let rules = try? JSONDecoder().decode([CommanderRule].self, from: d) { incoming = rules }
            else if let d = try? Data(contentsOf: u), let st = try? JSONDecoder().decode(Settings.self, from: d) { incoming = st.commands }
            else if let t = try? String(contentsOf: u, encoding: .utf8) { let r = PresetFile.parse(t); incoming = r.rules; unusable = r.skipped }
            // The magnifier has its own gesture and is not driven by Commander rules.
            let usable = incoming.filter { $0.action != "show hide magnifier" && $0.action != "move magnifier" && $0.gesture != settings.magnifierGesture }
            var fresh: [CommanderRule] = []
            for var rule in usable where !(settings.commands + fresh).contains(where: { $0.competes(with: rule) }) { rule.id = UUID(); fresh.append(rule) }
            duplicates += usable.count - fresh.count
            added += fresh.count; skipped += unusable + (incoming.count - usable.count)
            settings.commands.append(contentsOf: fresh)
        }
        importNote = Names.korean
            ? "규칙 \(added)개를 불러왔습니다" + (duplicates > 0 ? ", 중복 \(duplicates)개 제외" : "") + (skipped > 0 ? ", 사용 불가 \(skipped)개" : "")
            : "Imported \(added) rules" + (duplicates > 0 ? ", \(duplicates) skipped as duplicates" : "") + (skipped > 0 ? ", \(skipped) not usable" : "")
    }

    private func applyLogin() {
        let plist = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/com.touchm.app.plist")
        if settings.startAtLogin, let exe = Bundle.main.executablePath {
            let d: [String: Any] = ["Label": "com.touchm.app", "ProgramArguments": [exe], "RunAtLoad": true, "KeepAlive": ["SuccessfulExit": false]]
            (d as NSDictionary).write(to: plist, atomically: true)
        } else { try? FileManager.default.removeItem(at: plist) }
    }
}
