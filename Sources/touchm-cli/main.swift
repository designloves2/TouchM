import CoreGraphics
import AppKit
import Foundation
setvbuf(stdout, nil, _IOLBF, 0)
import TouchMCore

let args = Array(CommandLine.arguments.dropFirst())
TMLog.enabled = false          // the harness must not write into the real app log
if args.contains("--settings-check") {
    let st = Store.load()
    print("version", st.commandsVersion ?? 0, "| rules", st.commands.count, "| calibrated", st.calibration != nil, "| holdMs", st.holdMs, "| holdMode", st.holdMode,
          "| magnifierGesture", st.magnifierGesture, "| naturalScroll", st.naturalScroll, "| lowPass", st.lowPassGain, "| magnifier", st.magnifierWidth, "x", st.magnifierHeight)
    print("magnifier rules left:", st.commands.filter { $0.action == "show hide magnifier" }.count, "| tablet rules:", st.commands.filter { $0.tag == "tablet" }.count)
    exit(0)
}
if args.contains("--match-real") {
    // Which rule would run for each gesture in the active app, using the real saved settings?
    let st = Store.load()
    let apps = Array(Set(st.commands.compactMap { $0.appId }.filter { !$0.isEmpty })).sorted() + [nil]
    let gestures = ["three finger swipe left", "three finger swipe right", "three finger swipe up", "three finger swipe down", "three finger tap", "two finger tap"]
    for app in apps {
        print("Active app:", app ?? "(an app with no rules of its own)")
        for g in gestures {
            let r = Commander.match(st.commands, gesture: g, appId: app, roles: [], modifiers: [])
            let scope = r.map { ($0.appId ?? "").isEmpty ? "GLOBAL" : "APP RULE" } ?? "-"
            print(String(format: "   %-26@ -> %-9@ %@", g as NSString, scope as NSString, (r.map { "\($0.action) \($0.params ?? [:])" } ?? "(none)") as NSString))
        }
    }
    exit(0)
}
if args.contains("--match-check") {
    // The active app's rule must beat an "any application" rule in every combination.
    func m(_ rules: [CommanderRule], _ g: String, app: String?, roles: Set<String> = [], mods: NSEvent.ModifierFlags = []) -> String {
        Commander.match(rules, gesture: g, appId: app, roles: roles, modifiers: mods)?.action ?? "(none)"
    }
    let any = CommanderRule(gesture: "three finger swipe up", action: "mission control")
    let appRule = CommanderRule(gesture: "three finger swipe up", action: "keystroke", appId: "com.apple.Safari")
    print("exact vs exact            ->", m([any, appRule], "three finger swipe up", app: "com.apple.Safari"), "(expect keystroke)")
    print("order reversed            ->", m([appRule, any], "three finger swipe up", app: "com.apple.Safari"), "(expect keystroke)")
    var anyRole = CommanderRule(gesture: "three finger swipe up", action: "mission control", role: "AXWebArea"); anyRole.modifiers = ["cmd"]
    let appAlias = CommanderRule(gesture: "three finger swipe vertical", action: "keystroke", appId: "com.apple.Safari")
    print("app alias vs any exact+role+mods ->", m([anyRole, appAlias], "three finger swipe up", app: "com.apple.Safari", roles: ["AXWebArea"], mods: [.command]), "(expect keystroke)")
    var safariCmd = CommanderRule(gesture: "three finger swipe left", action: "keystroke", params: ["key": "["], appId: "com.apple.Safari"); safariCmd.modifiers = ["cmd"]
    let spaces = CommanderRule(gesture: "three finger swipe horizontal", action: "swipe between spaces")
    print("YOUR CASE, ⌘ not held     ->", m([spaces, safariCmd], "three finger swipe left", app: "com.apple.Safari"), "(Safari rule needs ⌘ held, so Any-app wins)")
    print("YOUR CASE, ⌘ held         ->", m([spaces, safariCmd], "three finger swipe left", app: "com.apple.Safari", mods: [.command]), "(Safari rule applies)")
    print("other app                 ->", m([any, appRule], "three finger swipe up", app: "com.apple.finder"), "(expect mission control)")
    print("no active app known       ->", m([any, appRule], "three finger swipe up", app: nil), "(expect mission control)")
    exit(0)
}
if args.contains("--simulate") {
    // Drive the real engine with synthetic fingers and print what it would do.
    let b = CGDisplayBounds(CGMainDisplayID())
    let names = [1: "leftDown", 2: "leftUp", 3: "rightDown", 4: "rightUp", 5: "move", 6: "drag", 22: "scroll"]
    func contact(_ id: Int, _ x: Double, _ y: Double) -> Contact { Contact(id: id, x: Int(x / (b.width - 1) * 4095), y: Int(y / (b.height - 1) * 4095), width: 1, height: 1, confident: true) }
    func run(_ title: String, rules: [CommanderRule] = [], app: String? = nil, roles: Set<String> = [], fingers: [[(Double, Double)]], hold: Double = 0, gap: Double = 0.016, tail: Double = 0.4, lift: Bool = true, tweak: ((inout Settings) -> Void)? = nil) {
        var st = Settings(); st.calibration = Affine(); st.lowPassGain = 0; st.deglitchFrames = 0; st.startupDelaySec = 0; st.gestureOrientation = "normal"; tweak?(&st)
        let eng = GestureEngine(st)
        var out: [String] = [], scrollSum = 0.0, scrollTags: [String] = []
        eng.ruleLookup = { g, _ in Commander.match(rules, gesture: g, appId: app, roles: roles, modifiers: []) }
        eng.traceInjection = { t, p in
            if t.hasPrefix("scroll") {
                scrollSum += p.y
                let tag = String(t.dropFirst(7))
                if scrollTags.last != tag { scrollTags.append(tag) }
                return
            }
            if t.hasPrefix("key:") { out.append("KEY \(t.dropFirst(4))"); return }
            let n = names[Int(t) ?? 0] ?? t
            if out.last?.hasPrefix(n) == true && n == "drag" { out[out.count - 1] = "drag…(\(Int(p.x)),\(Int(p.y)))" } else { out.append("\(n)(\(Int(p.x)),\(Int(p.y)))") }
        }
        eng.onGesture = { g, _ in out.append("GESTURE '\(g)'") }
        var t = 0.0
        let frames = fingers.first!.count
        for i in 0..<frames {
            t += (i == frames - 1 && hold > 0) ? hold : gap
            let fs = fingers.enumerated().map { contact($0.offset, $0.element[i].0, $0.element[i].1) }
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { eng.handle(fs) }
        }
        if lift { DispatchQueue.main.asyncAfter(deadline: .now() + t + 0.05) { eng.handle([]) } }
        RunLoop.main.run(until: Date(timeIntervalSinceNow: t + tail))
        if scrollSum != 0 { out.append(String(format: "scroll Σ%.0f", scrollSum) + " phases[" + scrollTags.joined(separator: " ") + "]") }
        print("• \(title)\n    " + (out.isEmpty ? "(nothing)" : out.joined(separator: " → ")))
    }
    func line(_ a: (Double, Double), _ b2: (Double, Double), steps: Int) -> [(Double, Double)] {
        (0...steps).map { (a.0 + (b2.0 - a.0) * Double($0) / Double(steps), a.1 + (b2.1 - a.1) * Double($0) / Double(steps)) }
    }
    let H = b.height, W = b.width
    let dock = CommanderRule(gesture: "one finger swipe up from edge", action: "show hide dock")
    run("tap (default: click on release)", fingers: [[(800, 500), (800, 500), (800, 500), (800, 500)]])
    run("drag (default: click and drag)", fingers: [line((500, 500), (620, 530), steps: 12)])
    run("press and hold 1.0 s (default: right-click)", fingers: [[(800, 500), (800, 500), (800, 500)]], hold: 1.0)
    run("edge swipe up from bottom edge WITH rule", rules: [dock], fingers: [line((1000, H - 20), (1000, H - 220), steps: 14)])
    run("same motion but NO edge rule -> ordinary drag", fingers: [line((1000, H - 20), (1000, H - 220), steps: 14)])
    run("drag starting at bottom edge but sideways (rule present) -> drag", rules: [dock], fingers: [line((1000, H - 20), (1300, H - 20), steps: 14)])
    run("one finger swipe left rule = keystroke", rules: [CommanderRule(gesture: "one finger swipe left", action: "keystroke", params: ["key": "left"])],
        fingers: [line((900, 600), (700, 605), steps: 14)])
    run("swipe horizontal rule, finger moves right", rules: [CommanderRule(gesture: "one finger swipe horizontal", action: "keystroke", params: ["key": "right"])],
        fingers: [line((700, 600), (900, 605), steps: 14)])
    run("drag rule = scroll (e.g. inside a scroll area)", rules: [CommanderRule(gesture: "one finger drag", action: "scroll")],
        fingers: [line((800, 500), (800, 700), steps: 14)])
    run("swipe left rule exists but drag rule says click and drag -> drag", rules: [CommanderRule(gesture: "one finger swipe left", action: "keystroke", params: ["key": "left"]), CommanderRule(gesture: "one finger drag", action: "click and drag")],
        fingers: [line((900, 600), (700, 605), steps: 14)])
    let notif = CommanderRule(gesture: "two finger swipe left from edge", action: "notification center")
    run("two fingers swipe left from the right edge", rules: [notif],
        fingers: [line((W - 15, 600), (W - 220, 600), steps: 14), line((W - 15, 660), (W - 220, 660), steps: 14)])
    run("INVERTED: finger starts at the bottom edge and moves up -> read as 'down from edge' at the top (rule 'down' present)",
        rules: [CommanderRule(gesture: "one finger swipe down from edge", action: "show hide dock")],
        fingers: [line((1000, H - 20), (1000, H - 220), steps: 14)], tweak: { $0.gestureOrientation = "inverted" })
    run("INVERTED: the same swipe does NOT match an 'up from edge' rule", rules: [dock],
        fingers: [line((1000, H - 20), (1000, H - 220), steps: 14)], tweak: { $0.gestureOrientation = "inverted" })
    run("INVERTED: two fingers from the LEFT edge moving right = 'left from edge' (notification centre)", rules: [notif],
        fingers: [line((15, 600), (220, 600), steps: 14), line((15, 660), (220, 660), steps: 14)], tweak: { $0.gestureOrientation = "inverted" })
    run("INVERTED: one finger swipe left rule fires when the finger moves right", rules: [CommanderRule(gesture: "one finger swipe left", action: "keystroke", params: ["key": "left"])],
        fingers: [line((700, 600), (900, 605), steps: 14)], tweak: { $0.gestureOrientation = "inverted" })
    let tabletDrag = CommanderRule(gesture: "one finger drag", action: "scroll", role: "AXWebArea", tag: "tablet")
    let safariSwipe = CommanderRule(gesture: "one finger swipe left", action: "keystroke", params: ["key": "left"], appId: "com.apple.Safari")
    run("PRIORITY: Safari has a swipe-left rule, Any-app has drag=scroll for web pages (in Safari) -> Safari's rule must win",
        rules: [tabletDrag, safariSwipe], app: "com.apple.Safari", roles: ["AXWebArea"], fingers: [line((900, 600), (700, 605), steps: 14)])
    run("PRIORITY: same rules in another app -> the Any-app drag=scroll applies",
        rules: [tabletDrag, safariSwipe], app: "com.apple.finder", roles: ["AXWebArea"], fingers: [line((900, 600), (700, 605), steps: 14)])
    run("PRIORITY: Safari defines its own drag=click-and-drag AND a swipe rule -> its drag rule is more specific than nothing, swipe still ties: drag wins by being explicit",
        rules: [tabletDrag, safariSwipe, CommanderRule(gesture: "one finger drag", action: "click and drag", appId: "com.apple.Safari")], app: "com.apple.Safari", roles: ["AXWebArea"], fingers: [line((900, 600), (700, 605), steps: 14)])
    run("click_mode 1 (move then click): drag moves the pointer, click only at lift", fingers: [line((500, 500), (620, 530), steps: 12)], tweak: { $0.clickMode = 1 })
    run("click_mode 2 (point and click): click at once, movement ignored", fingers: [line((500, 500), (620, 530), steps: 12)], tweak: { $0.clickMode = 2 })
    run("click_mode 3 (no click): pointer only", fingers: [line((500, 500), (620, 530), steps: 12)], tweak: { $0.clickMode = 3 })
    run("LIFT-OFF: finger goes down in a drag and the panel then stops reporting (no lift ever arrives) -> button must be released ~500 ms later",
        fingers: [line((500, 500), (620, 530), steps: 8)], tail: 1.2, lift: false)
    do {
        // A fast two-finger flick leaves the page gliding. A tap while it glides must only stop it; the next tap clicks.
        var st = Settings(); st.calibration = Affine(); st.lowPassGain = 0; st.deglitchFrames = 0; st.gestureOrientation = "normal"
        let eng = GestureEngine(st); var out: [String] = []
        eng.traceInjection = { t, p in if !t.hasPrefix("scroll") { out.append("\(names[Int(t) ?? 0] ?? t)(\(Int(p.x)),\(Int(p.y)))") } else if t.contains("mp=3") { out.append("momentum-stopped") } }
        var t = 0.0
        for i in 0...10 { t += 0.016; let y = 500.0 + Double(i) * 14; DispatchQueue.main.asyncAfter(deadline: .now() + t) { eng.handle([contact(0, 600, y), contact(1, 680, y)]) } }
        DispatchQueue.main.asyncAfter(deadline: .now() + t + 0.02) { eng.handle([]) }                       // lift: the page glides on
        DispatchQueue.main.asyncAfter(deadline: .now() + t + 0.30) { eng.handle([contact(0, 800, 500)]) }   // tap 1 while it glides
        DispatchQueue.main.asyncAfter(deadline: .now() + t + 0.38) { eng.handle([]) }
        DispatchQueue.main.asyncAfter(deadline: .now() + t + 1.0) { eng.handle([contact(0, 800, 500)]) }    // tap 2 after it has stopped
        DispatchQueue.main.asyncAfter(deadline: .now() + t + 1.08) { eng.handle([]) }
        RunLoop.main.run(until: Date(timeIntervalSinceNow: t + 1.6))
        print("• MOMENTUM: tap 1 lands on a gliding page, tap 2 comes after it stopped\n    " + out.joined(separator: " → "))
    }
    do {
        let tabletPress = CommanderRule(gesture: "one finger press", action: "click and drag", role: "AXWebArea", tag: "tablet")
        for (title, moves) in [("TABLET AREA: hold 0.7 s then release in place -> context menu", false), ("TABLET AREA: hold 0.7 s then move -> drag", true)] {
            var st = Settings(); st.calibration = Affine(); st.lowPassGain = 0; st.deglitchFrames = 0; st.gestureOrientation = "normal"
            let eng = GestureEngine(st); var out: [String] = []
            eng.ruleLookup = { g, _ in Commander.match([tabletPress], gesture: g, appId: nil, roles: ["AXWebArea"], modifiers: []) }
            eng.traceInjection = { t, p in if !t.hasPrefix("scroll") { out.append("\(names[Int(t) ?? 0] ?? t)(\(Int(p.x)),\(Int(p.y)))") } }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.0) { eng.handle([contact(0, 800, 500)]) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { eng.handle([contact(0, 800, 500)]) }
            if moves { for i in 1...6 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.75 + Double(i) * 0.016) { eng.handle([contact(0, 800 + Double(i) * 12, 500 + Double(i) * 6)]) } } }
            DispatchQueue.main.asyncAfter(deadline: .now() + (moves ? 0.95 : 0.8)) { eng.handle([]) }
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 1.2))
            print("• " + title + "\n    " + out.joined(separator: " → "))
        }
    }
    run("CUSTOM (mirror left/right only): swipe up from the bottom edge still triggers 'up from edge' (the Dock)", rules: [dock],
        fingers: [line((1000, H - 20), (1000, H - 220), steps: 14)], tweak: { $0.gestureOrientation = "custom"; $0.gestureFlipX = true; $0.gestureFlipY = false })
    run("CUSTOM (mirror left/right only): two fingers from the LEFT edge moving right = 'left from edge'", rules: [notif],
        fingers: [line((15, 600), (220, 600), steps: 14), line((15, 660), (220, 660), steps: 14)], tweak: { $0.gestureOrientation = "custom"; $0.gestureFlipX = true; $0.gestureFlipY = false })
    run("hold 0.7 s, default mode (immediate) -> right-click at 550 ms", fingers: [[(800, 500), (800, 500), (800, 500)]], hold: 0.7)
    run("hold 0.7 s, mode = drag -> right button down, moves, up at lift", fingers: [[(800, 500), (800, 500), (830, 520), (860, 540)]], hold: 0.7, tweak: { $0.holdMode = "drag" })
    run("hold 0.7 s, mode = latched -> nothing until lift", fingers: [[(800, 500), (800, 500)]], hold: 0.7, tweak: { $0.holdMode = "latched" })
    run("quick drag of 9 px stays a tap (drag threshold = 10)", fingers: [[(800, 500), (804, 503), (808, 506), (806, 504)]])
    run("two-finger scroll, fast flick then lift: phases + inertia", fingers: [(0...10).map { (600.0, 500.0 + Double($0) * 14) }, (0...10).map { (680.0, 500.0 + Double($0) * 14) }], tail: 1.4)
    run("two-finger scroll, slow then stop, then lift: no inertia", fingers: [(0...10).map { (600.0, 500.0 + Double($0) * 14) } + [(600.0, 640.0)], (0...10).map { (680.0, 500.0 + Double($0) * 14) } + [(680.0, 640.0)]], hold: 0.2, tail: 0.6)
    exit(0)
}
if args.contains("--simulate-lens") {
    // Feed synthetic one-finger frames through the engine with a fake 2x lens and print the mouse events it would post.
    final class FakeLens: LensHook {
        let rect = CGRect(x: 500, y: 400, width: 400, height: 300), zoom = 2.0
        var lensActive: Bool { true }
        func lensContains(_ p: CGPoint) -> Bool { rect.contains(p) }
        func lensMap(_ p: CGPoint) -> CGPoint { let c = CGPoint(x: rect.midX, y: rect.midY); return CGPoint(x: c.x + (p.x - c.x) / zoom, y: c.y + (p.y - c.y) / zoom) }
        var moveHook: ((Double, Double) -> Void)?
        func lensMove(dx: Double, dy: Double) { moveHook?(dx, dy) }
    }
    var st = Settings(); st.calibration = Affine(); st.lowPassGain = 0; st.deglitchFrames = 0; st.startupDelaySec = 0
    let eng = GestureEngine(st); let lens = FakeLens(); eng.lens = lens
    let names = [1: "mouseDown?", 2: "leftMouseDown", 3: "leftMouseUp", 4: "rightMouseDown", 5: "rightMouseUp", 6: "leftMouseDragged", 7: "mouseMoved"]
    eng.traceInjection = { t, p in print("  inject", names[Int(t) ?? 0] ?? t, String(format: "(%.0f,%.0f)", p.x, p.y)) }
    let b = CGDisplayBounds(CGMainDisplayID())
    func contact(_ x: Double, _ y: Double) -> Contact { Contact(id: 0, x: Int(x / (b.width - 1) * 4095), y: Int(y / (b.height - 1) * 4095), width: 1, height: 1, confident: true) }
    let path = (0...12).map { (700.0 + Double($0) * 10, 550.0 + Double($0) * 4) }      // finger starts in the lens centre and drags right/down
    var t = 0.0
    print("down at (700,550) inside lens, dragging to (820,598), then lift")
    for (i, pt) in path.enumerated() { t += 0.016; DispatchQueue.main.asyncAfter(deadline: .now() + t) { print("frame \(i) finger \(pt)"); eng.handle([contact(pt.0, pt.1)]) } }
    DispatchQueue.main.asyncAfter(deadline: .now() + t + 0.05) { print("lift"); eng.handle([]) }
    RunLoop.main.run(until: Date(timeIntervalSinceNow: t + 0.6))
    eng.handle([])
    // Second scenario: two fingers drag the lens slowly (3 px/frame) with realistic +-2 px jitter between them.
    var movedTotal = 0.0
    eng.traceInjection = { _, _ in }
    lens.moveHook = { dx, dy in movedTotal += dx }
    var t2 = 0.0
    var jitter = [2.0, -2.0, 1.0, -1.0, 2.0, -2.0, 1.5, -1.5, 2.0, -2.0, 1.0, -1.0, 2.0, -2.0, 1.0, -1.0, 2.0, -2.0, 1.0, -1.0, 2.0, -2.0, 1.0, -1.0, 2.0]
    var zoomSteps = 0
    eng.onPinchStep = { d, _ in zoomSteps += d }
    print("\ntwo fingers drag right 3px/frame x 24 frames (expect ~72 px of lens movement)")
    for i in 0..<24 {
        t2 += 0.016
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 + t2) {
            let cx = 700.0 + Double(i) * 3, j = jitter[i] * 1.5     // +-3 px spread noise, harsher than a real hand
            var a = contact(cx - 40 - j, 550.0); a.id = 0
            var b2 = contact(cx + 40 + j, 550.0); b2.id = 1
            eng.handle([a, b2])
        }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 + t2 + 0.05) { eng.handle([]) }
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 1.0 + t2 + 0.5))
    print(String(format: "lens moved %.0f px, zoom steps %d", movedTotal, zoomSteps))
    exit(0)
}
if let i = args.firstIndex(of: "--preset"), i + 1 < args.count {      // touchm-cli --preset <file> : dry-run the importer
    let t = (try? String(contentsOfFile: args[i + 1], encoding: .utf8)) ?? ""
    let r = PresetFile.parse(t)
    print(r.summary)
    for x in r.rules.prefix(40) { print(" ", x.appId ?? "*", "|", x.role ?? "-", "|", x.gesture, "=>", x.action, x.params ?? [:], x.modifiers ?? []) }
    exit(0)
}
let seconds = Double(args.first { Double($0) != nil } ?? "30") ?? 30
let dev = TouchDevice()
dev.onLog = { print("[touchm]", $0) }
var last = Date.distantPast
dev.onFrame = { cs in
    guard Date().timeIntervalSince(last) > 0.1 || cs.isEmpty else { return }
    last = Date()
    print(cs.isEmpty ? "frame: (no contacts)" : "frame: " + cs.map { "id\($0.id)(\($0.x),\($0.y))" }.joined(separator: " "))
}
guard dev.start() else { exit(1) }
RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds))
