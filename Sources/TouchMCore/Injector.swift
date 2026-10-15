import CoreGraphics
import Foundation
import AppKit

/// Posts synthetic mouse / scroll / key events.
public final class Injector {
    private var clickState: Int64 = 1
    public var clickLasts = 0.04
    /// Test seam: when set, events are described here instead of being posted.
    public var trace: ((String, CGPoint) -> Void)?
    public init() {}

    /// Events are created from the HID system state (CGEventSourceCreate(1)), so a synthetic event never inherits
    /// modifier flags that other synthetic events left behind.
    private let source = CGEventSource(stateID: .hidSystemState)
    /// Marks events as ours (kCGEventSourceUserData).
    public static let userDataTag: Int64 = 0x544D

    private var rightIsDown = false, rightDownAt = Date.distantPast
    // Click state, computed like the system does: a press within the system double-click interval and 20 points of the
    // previous press of the same button is the next click of a multi-click.
    private var lastDownTime = TimeInterval.zero, lastDownPoint = CGPoint(x: -1000, y: -1000), lastDownButton = -1
    private var clickCount: [Int64] = [1, 1, 1]
    private var eventNumber: [Int64] = [0, 0, 0]
    private var lastPos = CGPoint.zero

    private func buttonIndex(_ t: CGEventType) -> Int {
        switch t {
        case .leftMouseDown, .leftMouseUp, .leftMouseDragged: return 0
        case .rightMouseDown, .rightMouseUp, .rightMouseDragged: return 1
        default: return 2
        }
    }

    private func post(_ type: CGEventType, _ p: CGPoint, button: CGMouseButton = .left, click: Int64? = nil) {
        if type == .rightMouseDown { rightIsDown = true; rightDownAt = Date(); TMLog.write("right button DOWN at (\(Int(p.x)),\(Int(p.y)))") }
        if type == .rightMouseUp { rightIsDown = false; TMLog.write("right button up at (\(Int(p.x)),\(Int(p.y)))") }
        let bi = buttonIndex(type)
        if type == .leftMouseDown || type == .rightMouseDown {
            let now = ProcessInfo.processInfo.systemUptime
            if lastDownButton == bi, now - lastDownTime < NSEvent.doubleClickInterval, hypot(p.x - lastDownPoint.x, p.y - lastDownPoint.y) < 20 { clickCount[bi] += 1 }
            else { clickCount[bi] = 1 }
            lastDownTime = now; lastDownPoint = p; lastDownButton = bi
            eventNumber[bi] += 1
        }
        if let t = trace { t("\(type.rawValue)", p); lastPos = p; return }
        guard let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: button) else { return }
        e.setIntegerValueField(.mouseEventClickState, value: clickCount[bi])        // the caller's count (if any) is ignored on purpose
        e.setIntegerValueField(.mouseEventNumber, value: eventNumber[bi])
        if type == .mouseMoved || type == .leftMouseDragged || type == .rightMouseDragged {
            e.setIntegerValueField(.mouseEventDeltaX, value: Int64((p.x - lastPos.x).rounded()))     // apps that follow drags by delta need these
            e.setIntegerValueField(.mouseEventDeltaY, value: Int64((p.y - lastPos.y).rounded()))
        }
        e.setIntegerValueField(.eventSourceUserData, value: Self.userDataTag)
        lastPos = p
        e.post(tap: .cghidEventTap)
    }
    public func move(_ p: CGPoint) { post(.mouseMoved, p) }
    public func leftDown(_ p: CGPoint, clicks: Int64) { post(.leftMouseDown, p, click: clicks) }
    public func leftDrag(_ p: CGPoint, clicks: Int64) { post(.leftMouseDragged, p, click: clicks) }
    public func leftUp(_ p: CGPoint, clicks: Int64) { post(.leftMouseUp, p, click: clicks) }
    /// Down and up are spaced out like a real click; back-to-back events can leave a context menu
    /// tracking a button that it never saw being released.
    /// Called whenever a new touch begins: a right button left down would make every later touch a right-drag
    /// and keep a context menu following the finger.
    public func releaseStuckButtons(at p: CGPoint) {
        if rightIsDown { TMLog.write("right button was still down when a new touch began: releasing it"); post(.rightMouseUp, p, button: .right, click: 1) }
    }
    public func rightDown(_ p: CGPoint) { post(.rightMouseDown, p, button: .right, click: 1) }
    public func rightDrag(_ p: CGPoint) { post(.rightMouseDragged, p, button: .right, click: 1) }
    public func rightUp(_ p: CGPoint) { post(.rightMouseUp, p, button: .right, click: 1) }
    public func rightClick(_ p: CGPoint) {
        post(.rightMouseDown, p, button: .right, click: 1)
        DispatchQueue.main.asyncAfter(deadline: .now() + clickLasts) { [self] in post(.rightMouseUp, p, button: .right, click: 1) }
    }
    /// Time the pointer rests on the target before the button goes down. A touch teleports the pointer; menus (and their
    /// sub-menus) only highlight an item once they have seen the pointer arrive, otherwise the press counts as "outside" and closes them.
    public var hoverBeforeClick = 0.06
    public func click(_ p: CGPoint, clicks: Int64 = 1) {
        let wait = trace == nil ? hoverBeforeClick : 0
        post(.mouseMoved, p)
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [self] in
            post(.leftMouseDown, p, click: clicks)
            DispatchQueue.main.asyncAfter(deadline: .now() + clickLasts) { [self] in post(.leftMouseUp, p, click: clicks) }
        }
    }

    // MARK: scrolling
    // Events carry trackpad-style phases (began / changed / ended, then momentum begin / continue / end) so that apps
    // do inertial scrolling, rubber-banding and "swipe between pages" exactly as they do for a real trackpad.
    private var remX = 0.0, remY = 0.0
    private var scrolling = false
    private var samples: [(t: TimeInterval, dx: Double, dy: Double)] = []
    private var momentumTimer: Timer?
    private var mvx = 0.0, mvy = 0.0, mrx = 0.0, mry = 0.0, momentumStarted = false
    public var momentumEnabled = true
    /// Fraction of speed kept per 1/60 s while coasting (0.90 stops quickly, 0.98 glides for seconds).
    public var momentumDecay = 0.95
    public var isScrolling: Bool { scrolling || momentumTimer != nil }

    private func postScroll(_ ix: Int32, _ iy: Int32, phase: Int64, momentum: Int64) {
        if let t = trace { t("scroll sp=\(phase) mp=\(momentum)", CGPoint(x: Double(ix), y: Double(iy))); return }
        guard let e = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2, wheel1: iy, wheel2: ix, wheel3: 0) else { return }
        e.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        e.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)          // CGScrollPhase: 1 began, 2 changed, 4 ended
        e.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)     // CGMomentumScrollPhase: 1 begin, 2 continue, 3 end
        e.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: Int64(iy))
        e.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: Int64(ix))
        e.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: Double(iy))
        e.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: Double(ix))
        e.post(tap: .cghidEventTap)
    }

    /// Finger movement in pixels. The first call of a gesture starts it (phase "began"); later calls continue it.
    public func scroll(dx: Double, dy: Double) {
        stopMomentum()
        samples.append((Date.timeIntervalSinceReferenceDate, dx, dy))
        if samples.count > 24 { samples.removeFirst(samples.count - 24) }
        remX += dx; remY += dy
        let ix = Int32(remX.rounded(.towardZero)), iy = Int32(remY.rounded(.towardZero))
        remX -= Double(ix); remY -= Double(iy)
        guard ix != 0 || iy != 0 else { return }
        postScroll(ix, iy, phase: scrolling ? 2 : 1, momentum: 0)
        scrolling = true
    }

    /// Fingers lifted. With `momentum` the content keeps gliding at the speed the fingers had, slowing down gradually.
    public func endScroll(momentum: Bool) {
        guard scrolling else { return }
        scrolling = false
        postScroll(0, 0, phase: 4, momentum: 0)
        let now = Date.timeIntervalSinceReferenceDate
        let recent = samples.filter { now - $0.t < 0.12 }
        samples = []; remX = 0; remY = 0
        guard momentum, momentumEnabled, recent.count >= 2, now - recent.last!.t < 0.07 else { return }   // fingers had stopped: no coasting
        let dt = max(recent.last!.t - recent.first!.t, 0.016)
        mvx = recent.dropFirst().map(\.dx).reduce(0, +) / dt
        mvy = recent.dropFirst().map(\.dy).reduce(0, +) / dt
        guard hypot(mvx, mvy) > 180 else { return }                                                           // px/s
        mrx = 0; mry = 0; momentumStarted = false
        momentumTimer = Timer.common(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.momentumTick() }
    }

    private func momentumTick() {
        let dt = 1.0 / 60
        mvx *= momentumDecay; mvy *= momentumDecay
        if hypot(mvx, mvy) < 25 { stopMomentum(); return }
        mrx += mvx * dt; mry += mvy * dt
        let ix = Int32(mrx.rounded(.towardZero)), iy = Int32(mry.rounded(.towardZero))
        mrx -= Double(ix); mry -= Double(iy)
        guard ix != 0 || iy != 0 else { return }
        postScroll(ix, iy, phase: 0, momentum: momentumStarted ? 2 : 1)
        momentumStarted = true
    }

    /// A new touch (or a new scroll) stops coasting, like putting a finger on a moving list.
    /// True while the content is still gliding after the fingers left.
    public var isCoasting: Bool { momentumTimer != nil }

    public func stopMomentum() {
        guard let t = momentumTimer else { return }
        t.invalidate(); momentumTimer = nil
        if momentumStarted { postScroll(0, 0, phase: 0, momentum: 3) }
        momentumStarted = false
    }

    public func resetScroll() { remX = 0; remY = 0; samples = [] }

    /// "cmd+shift+t", "ctrl+left", "f5" ... Arrow, navigation and function keys carry the fn flag like a real keyboard does.
    public func key(_ combo: String) {
        let parts = combo.lowercased().split(separator: "+", omittingEmptySubsequences: true).map(String.init)
        guard let k = parts.last, let code = Self.keyCodes[k] else { TMLog.write("key: unknown '\(combo)'"); return }
        var flags: CGEventFlags = []
        for m in parts.dropLast() {
            switch m { case "cmd": flags.insert(.maskCommand); case "shift": flags.insert(.maskShift)
                       case "alt", "opt": flags.insert(.maskAlternate); case "ctrl": flags.insert(.maskControl)
                       case "fn": flags.insert(.maskSecondaryFn); default: break }
        }
        if Self.fnKeys.contains(k) { flags.insert(.maskSecondaryFn) }
        TMLog.write("key \(combo) -> code \(code) flags \(flags.rawValue)")
        if let t = trace { t("key:\(combo)", .zero); return }
        // Modifiers are announced with flagsChanged events and released the same way, like a real keyboard, so the system's
        // modifier state is back to "none" afterwards and no later click turns into a Control-click.
        let modFlags: [(String, CGEventFlags)] = [("ctrl", .maskControl), ("alt", .maskAlternate), ("shift", .maskShift), ("cmd", .maskCommand)]
        let used = modFlags.filter { parts.dropLast().contains($0.0) || ($0.0 == "alt" && parts.dropLast().contains("opt")) }
        var acc: CGEventFlags = []
        func flagsChanged(_ f: CGEventFlags) {
            guard let e = CGEvent(source: source) else { return }
            e.type = .flagsChanged; e.flags = f
            e.setIntegerValueField(.eventSourceUserData, value: Self.userDataTag)
            e.post(tap: .cghidEventTap)
        }
        func key(down: Bool, _ f: CGEventFlags) {
            let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down); e?.flags = f
            e?.setIntegerValueField(.eventSourceUserData, value: Self.userDataTag); e?.post(tap: .cghidEventTap)
        }
        for m in used { acc.insert(m.1); flagsChanged(acc) }
        key(down: true, flags); key(down: false, flags)
        for m in used.reversed() { acc.remove(m.1); flagsChanged(acc) }
    }

    static let fnKeys: Set<String> = ["left", "right", "up", "down", "home", "end", "pageup", "pagedown", "forwarddelete",
                                      "f1", "f2", "f3", "f4", "f5", "f6", "f7", "f8", "f9", "f10", "f11", "f12"]

    public static let keyCodes: [String: CGKeyCode] = [
        "a":0,"s":1,"d":2,"f":3,"h":4,"g":5,"z":6,"x":7,"c":8,"v":9,"b":11,"q":12,"w":13,"e":14,"r":15,"y":16,"t":17,
        "1":18,"2":19,"3":20,"4":21,"6":22,"5":23,"=":24,"9":25,"7":26,"-":27,"8":28,"0":29,"]":30,"o":31,"u":32,"[":33,
        "i":34,"p":35,"return":36,"l":37,"j":38,"'":39,"k":40,";":41,"\\":42,",":43,"/":44,"n":45,"m":46,".":47,
        "tab":48,"space":49,"`":50,"delete":51,"escape":53,
        "f1":122,"f2":120,"f3":99,"f4":118,"f5":96,"f6":97,"f7":98,"f8":100,"f9":101,"f10":109,"f11":103,"f12":111,
        "home":115,"end":119,"pageup":116,"pagedown":121,"forwarddelete":117,
        "left":123,"right":124,"down":125,"up":126,
    ]

    /// Reverse lookup, used when a shortcut is recorded from the keyboard.
    public static func name(forKeyCode c: CGKeyCode) -> String? { keyCodes.first { $0.value == c }?.key }
}
