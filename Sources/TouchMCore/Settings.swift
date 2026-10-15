import Foundation
import CoreGraphics

/// 2x3 affine transform on normalised coordinates: out = [a b c; d e f] * [x y 1]
public struct Affine: Codable, Equatable {
    public var a = 1.0, b = 0.0, c = 0.0, d = 0.0, e = 1.0, f = 0.0
    public init() {}
    public func apply(_ x: Double, _ y: Double) -> (Double, Double) { (a * x + b * y + c, d * x + e * y + f) }
}

public struct Settings: Codable, Equatable {
    public var enabled = true
    /// How swipe directions and screen edges are read: auto = reversed when the display is rotated 180°, normal, inverted.
    public var gestureOrientation = "auto"          // auto | normal | inverted | custom
    public var gestureFlipX = false                  // used when the orientation is custom: left <-> right
    public var gestureFlipY = false                  // used when the orientation is custom: up <-> down
    public var autoRotate = true             // follow the display rotation (0/90/180/270)
    public var flipX = false, flipY = false, swapXY = false
    public var calibration: Affine? = nil    // set by the calibration wizard
    /// Display rotation (0/90/180/270) in force when the calibration was made; later rotations are compensated.
    public var calibrationRotation: Int? = nil
    public var calibrationPoints = 4         // 4, 9 or 16
    public var targetDisplay: UInt32? = nil  // nil = main display

    public var rightClickOnHold = true
    public var holdMs = 550                    // press-and-hold time
    /// Press-and-hold: immediate = right click when the time is up; drag = right button down at that moment, up at lift;
    /// latched = right click at lift if the time had passed; off.
    /// Click mode: 0 click and drag (standard), 1 move then click, 2 point and click, 3 no click (movement only).
    public var clickMode = 0
    /// Lift-off timeout: if no touch data arrives for this long while a finger is down, it is treated as lifted (0 = off).
    public var liftoffMs = 0          // off: this panel sends nothing while a finger rests, so a timeout would cut holds short (a 500 ms timeout is for panels that keep reporting)
    /// Hide the pointer while touching.
    public var hideCursorDuringTouches = false
    /// In pages and lists, "press" means click-and-drag. With this on, holding and then lifting without moving opens the
    /// context menu instead, so both are available: hold + move = drag, hold + release = menu.
    public var holdReleaseMenu = true
    public var holdMode = "immediate"
    public var holdRadiusPx = 20.0
    public var dragStartPx = 10.0              // movement before a touch becomes a drag
    public var assistedDoubleClickMs = 500     // double-tap assist window
    public var assistedDoubleClickPx = 20.0
    public var twoFingerScroll = true
    // Gesture tuning.
    public var clickLastsMs = 40              // time between synthetic down and up
    public var clickNearestPx = 30.0          // snap distance for click-nearest
    public var pressTapRestMs = 150           // press and tap: first finger must rest this long
    public var pressTapMaxMs = 450            // press and tap: second finger must lift within this
    public var swipeDistancePx = 100.0        // 3+ finger swipe: travel needed
    public var edgeMarginPx = 60.0            // edge swipe: how close to the edge it must start
    public var edgeDistancePx = 120.0         // edge swipe: travel needed
    public var pinchStepPx = 28.0             // pinch-zoom step size
    public var scrollSpeed = 1.0
    public var naturalScroll = true
    public var scrollMomentum = true           // keep gliding after the fingers lift
    public var scrollInertia = 0.5             // 0 = stops soon ... 1 = glides far
    public var tabletScroll = true             // web pages and scroll areas: one finger drag scrolls
    public var showTouchFeedback = true
    public var startAtLogin = false
    // Anchor mouse: put the pointer back where it was before the touch, so a mouse and the touch panel can share the screen.
    public var anchorMouse = false
    public var anchorReturnMs = 500
    public var anchorSampleMs = 100
    // Smart Magnifier (follow touches / follow mouse / stay put)
    public var magnifierGesture = "four finger tap"   // opens / closes the lens; reserved, Commander cannot use it
    public var magnifierFollow = "never"        // never = stays put (touch inside to aim) | touches | mouse
    public var magnifierAnimate = true
    public var magnifierZoom = 200              // percent
    public var magnifierWidth = 420.0
    public var magnifierHeight = 300.0
    public var magnifierCircle = false
    public var magnifierHz = 60
    public var magnifierPinchSpeed = 1.0
    public var magnifierZoomReversed = false
    public var lowPassGain = 0.35            // 0 = off; higher = smoother but laggier
    public var deglitchFrames = 1            // ignore a contact's first N frames
    public var soundOnTouch = false
    public var soundOnLift = false
    public var rotationOverride: Int? = nil  // nil = follow display
    public var startupDelaySec = 0           // delay touch after launch
    public var brightnessMethod = "auto"       // auto: DDC on external displays, gamma dimming otherwise; ddc; software
    public var holdRingDelayMs = 250          // how long the finger rests before the ring starts to fill
    public var holdVisual = true             // show the hold ring
    public var reinitOnWake = true           // re-initialise the panel after wake
    public var commands: [CommanderRule] = CommanderRule.defaults
    public var commandsVersion: Int? = 15
    public init() {}
}

public enum Store {
    public static var dir: URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("TouchM")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    static var file: URL { dir.appendingPathComponent("settings.json") }
    /// Loads the saved settings. Keys missing from the file (added by a newer version) keep their default instead of
    /// making the whole file unreadable, so an update never throws away calibration or rules.
    public static func load() -> Settings {
        guard let data = try? Data(contentsOf: file),
              let stored = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let defData = try? JSONEncoder().encode(Settings()),
              var merged = (try? JSONSerialization.jsonObject(with: defData)) as? [String: Any] else { return Settings() }
        for (k, v) in stored { merged[k] = v }
        guard let mergedData = try? JSONSerialization.data(withJSONObject: merged),
              var st = try? JSONDecoder().decode(Settings.self, from: mergedData) else {
            // Keep the unreadable file for inspection rather than overwriting it silently.
            try? FileManager.default.copyItem(at: file, to: dir.appendingPathComponent("settings.unreadable.json"))
            return Settings()
        }
        if st.calibration != nil && st.calibrationRotation == nil {       // calibrated before rotation was tracked: it was made at today's rotation
            st.calibrationRotation = Int(CGDisplayRotation(CGMainDisplayID())); save(st)
        }
        let v = st.commandsVersion ?? 1
        if v < 2 { st.commands = CommanderRule.defaults }                                   // old gesture names
        else if v < 5 {                                                                      // add newly introduced defaults
            for d in CommanderRule.defaults where !st.commands.contains(where: { $0.gesture == d.gesture && $0.appId == nil && $0.role == nil }) { st.commands.append(d) }
        }
        if v < 6 { st.magnifierFollow = "never" }
        if v < 7 && st.magnifierHz == 30 { st.magnifierHz = 60 }
        if v < 8 {
            for i in st.commands.indices where st.commands[i].action == "show hide magnifier" {
                if st.commands[i].params?["size"] == "420x300" { st.commands[i].params?["size"] = nil }
                if st.commands[i].params?["magnification"] == "200" { st.commands[i].params?["magnification"] = nil }
                if st.commands[i].params?.isEmpty == true { st.commands[i].params = nil }
            }
        }
        if v < 9 {
            if st.dragStartPx < 3 { st.dragStartPx = 5 }
            if st.edgeMarginPx == 45 { st.edgeMarginPx = 60 }
            if st.edgeDistancePx == 150 { st.edgeDistancePx = 120 }
        }
        if v < 10 {
            for t in CommanderRule.tablet where !st.commands.contains(where: { $0.tag == "tablet" && $0.gesture == t.gesture && $0.role == t.role && $0.appId == t.appId }) { st.commands.append(t) }
        }
        if v < 15 { for i in st.commands.indices where st.commands[i].action == "accessibility keyboard" { st.commands[i].action = "keyboard viewer" } }
        if v < 14 {
            if st.assistedDoubleClickPx == 75 { st.assistedDoubleClickPx = 20 }
            if st.assistedDoubleClickMs == 750 { st.assistedDoubleClickMs = 500 }
        }
        if v < 11 {
            if st.holdMs == 800 { st.holdMs = 550 }
            if st.dragStartPx == 5 { st.dragStartPx = 10 }
            if st.assistedDoubleClickMs == 500 { st.assistedDoubleClickMs = 750 }
            if st.assistedDoubleClickPx == 30 { st.assistedDoubleClickPx = 75 }
        }
        if v < 12 {
            for r in st.commands where r.action == "show hide magnifier" && CommanderRule.magnifierChoices.contains(r.gesture) { st.magnifierGesture = r.gesture }
            st.commands.removeAll { $0.action == "show hide magnifier" }
        }
        if v < 13 && st.liftoffMs == 500 { st.liftoffMs = 0 }      // the 500 ms default cut resting fingers short
        st.commandsVersion = 15
        return st
    }
    public static func save(_ s: Settings) {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(s).write(to: file, options: .atomic)
    }
}

/// Commander rule, using plain gesture/action names.
public struct CommanderRule: Codable, Equatable, Identifiable {
    public var id = UUID()
    public var gesture: String          // "three finger swipe up", "two finger tap", "five finger pinch expand"…
    public var action: String           // "mission control", "click", "keystroke", "open app", …
    public var params: [String: String]? = nil   // e.g. ["click button": "2"], ["key": "cmd+w"], ["app": "Safari"]
    public var appId: String? = nil     // bundle id, nil = all applications
    public var role: String? = nil      // AX role / special context ("AXScrollArea", "titlebar"…), nil = anywhere
    public var modifiers: [String]? = nil      // keyboard modifiers that must be held: cmd, shift, alt, ctrl
    public var tag: String? = nil              // "tablet" = switched as a group by the Tablet scrolling setting
    public var enabled = true
    public init(gesture: String, action: String, params: [String: String]? = nil, appId: String? = nil, role: String? = nil, tag: String? = nil) {
        self.gesture = gesture; self.action = action; self.params = params; self.appId = appId; self.role = role; self.tag = tag
    }

    /// What makes a screen feel like a tablet: dragging a page or list scrolls it, press-then-drag selects / moves.
    public static let tablet: [CommanderRule] = {
        var r: [CommanderRule] = []
        for role in ["AXWebArea", "AXScrollArea"] {
            r.append(CommanderRule(gesture: "one finger drag", action: "scroll", role: role, tag: "tablet"))
            r.append(CommanderRule(gesture: "one finger press", action: "click and drag", role: role, tag: "tablet"))
        }
        // Finder's icon views are scroll areas too: keep dragging icons there.
        r.append(CommanderRule(gesture: "one finger drag", action: "click and drag", appId: "com.apple.finder", role: "AXScrollArea", tag: "tablet"))
        return r
    }()
    /// Whether two rules compete for the same situation (same gesture, app, UI element and held keys).
    public func competes(with o: CommanderRule) -> Bool {
        gesture == o.gesture && (appId ?? "") == (o.appId ?? "") && (role ?? "") == (o.role ?? "") && Set(modifiers ?? []) == Set(o.modifiers ?? [])
    }
    public static let defaults: [CommanderRule] = tablet + [
        CommanderRule(gesture: "three finger swipe horizontal", action: "swipe between spaces"),
        CommanderRule(gesture: "three finger swipe up", action: "mission control"),
        CommanderRule(gesture: "three finger swipe down", action: "show app windows"),
        CommanderRule(gesture: "three finger tap", action: "look up in dictionary"),
        CommanderRule(gesture: "five finger pinch expand", action: "desktop launchpad"),
        CommanderRule(gesture: "two finger swipe left from edge", action: "notification center"),
        CommanderRule(gesture: "one finger swipe up from edge", action: "show hide dock"),
        CommanderRule(gesture: "two finger tap", action: "click", params: ["click button": "2"]),
        CommanderRule(gesture: "press and tap", action: "click", params: ["click button": "2"]),
        CommanderRule(gesture: "two finger rotate", action: "rotate"),
    ]
    public static let gestureNames: [String] = {
        var g = ["one finger tap", "one finger press", "one finger drag", "one finger swipe left", "one finger swipe right",
                 "one finger swipe up", "one finger swipe down", "one finger swipe horizontal", "one finger swipe vertical", "press and tap", "two finger tap", "two finger drag",
                 "two finger pinch expand", "two finger pinch contract", "two finger rotate"]
        for n in ["three", "four", "five"] {
            g += ["\(n) finger tap", "\(n) finger swipe left", "\(n) finger swipe right", "\(n) finger swipe up", "\(n) finger swipe down",
                  "\(n) finger swipe horizontal", "\(n) finger swipe vertical", "\(n) finger pinch expand", "\(n) finger pinch contract"]
        }
        for d in ["up", "down", "left", "right"] { g.append("one finger swipe \(d) from edge"); g.append("two finger swipe \(d) from edge") }
        return g
    }()
    /// Gestures that may open the magnifier: discrete ones, not the continuous finger-following gestures.
    public static let magnifierChoices: [String] = {
        var g = ["two finger tap", "press and tap", "two finger rotate", "two finger pinch expand", "two finger pinch contract"]
        for n in ["three", "four", "five"] {
            g += ["\(n) finger tap", "\(n) finger swipe up", "\(n) finger swipe down", "\(n) finger swipe left", "\(n) finger swipe right",
                  "\(n) finger pinch expand", "\(n) finger pinch contract"]
        }
        for d in ["up", "down", "left", "right"] { g.append("one finger swipe \(d) from edge"); g.append("two finger swipe \(d) from edge") }
        return g
    }()
    public static let actionNames = ["click", "click and drag", "scroll", "move cursor", "mission control", "show app windows",
        "swipe between spaces", "desktop launchpad", "notification center", "look up in dictionary", "show hide dock", "keyboard viewer",
        "adjust magnification", "rotate", "keystroke", "open app", "open url", "run shell command", "none"]
}
