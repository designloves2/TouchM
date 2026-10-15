import CoreGraphics
import Foundation
import AppKit

/// A magnifier lens the engine cooperates with: touches inside it aim at the magnified content.
public protocol LensHook: AnyObject {
    var lensActive: Bool { get }
    func lensContains(_ p: CGPoint) -> Bool
    func lensMap(_ p: CGPoint) -> CGPoint            // lens point -> the screen point it shows
    func lensMove(dx: Double, dy: Double)            // top-left coordinates, positive = right / down
}

/// Turns contact frames into Commander gestures and, where the matching rule says so, pointer / scroll events.
///
/// A single finger is *undecided* when it lands: no mouse event is sent. What it becomes depends on what the
/// finger does and on the rules that apply at that spot:
///   lifts quickly            -> "one finger tap"   (default: click)
///   rests in place           -> "one finger press" (default: right-click)
///   moves from a screen edge -> "one finger swipe <dir> from edge"
///   moves                    -> "one finger swipe <dir>" if such a rule exists, else "one finger drag"
///                               (default: click and drag; a rule can make it scroll or run any action)
public final class GestureEngine {
    public var settings: Settings { didSet { mapper = Mapper(settings); applyToInjector() } }
    /// Fired for Commander gestures: (gesture name, location).
    public var onGesture: ((String, CGPoint) -> Void)?
    /// Context-aware rule lookup (frontmost app, UI element under the touch, held keys).
    public var ruleLookup: ((String, CGPoint) -> CommanderRule?)?
    /// Live pinch step while two fingers pinch: +1 expand, -1 contract.
    public var onPinchStep: ((Int, CGPoint) -> Void)?
    public var onPoints: (([CGPoint]) -> Void)?          // mapped points for visual feedback / test window
    public var injectEnabled = true
    public weak var lens: LensHook?
    public var traceInjection: ((String, CGPoint) -> Void)? { didSet { inj.trace = traceInjection } }
    public var onHoldVisual: ((CGPoint, TimeInterval) -> Void)?
    public var onHoldCancel: (() -> Void)?

    private var mapper: Mapper
    private let inj = Injector()
    private var seen: [Int: Int] = [:]            // contact id -> frames seen (deglitch)
    private var smooth: [Int: CGPoint] = [:]      // contact id -> filtered point
    private var activeSince = Date()

    // magnifier
    private var lensTouch = false, lensMoving = false
    private var lensTravel = 0.0
    private var lensLast = CGPoint.zero, lensSpreadLast = 0.0, lensPinchAccum = 0.0

    // touch state
    private enum Mode { case idle, pending, single, multi }
    private var mode = Mode.idle
    private var downPoint = CGPoint.zero, lastPoint = CGPoint.zero
    private var downTime = Date.distantPast
    private var holdTimer: Timer?, ringTimer: Timer?

    // one finger
    private enum One { case undecided, drag, scroll, swipe(String), rightDrag, latchedRight, moveOnly(Bool), holdPending, done }   // moveOnly(clickOnLift)
    private var one = One.undecided
    private var mouseDown = false
    private var clicks: Int64 = 1
    private var lastTapTime = Date.distantPast, lastTapPoint = CGPoint.zero
    private var rTap: CommanderRule?, rPress: CommanderRule?, rDrag: CommanderRule?
    private var rSwipe: [String: CommanderRule] = [:]
    private var edgeDir: String?                  // direction of travel that would make an edge swipe, if this touch started at an edge
    private var scrollLast = CGPoint.zero
    private var stoppedMomentum = false      // this touch only stopped a gliding page: it must not also click

    // two or more fingers
    private var lastCentroid = CGPoint.zero
    private var multiStart = CGPoint.zero, multiStartTime = Date.distantPast, maxFingers = 0
    private var startSpread = 0.0, lastSpread = 0.0, pinchAccum = 0.0, pinchTotal = 0.0, pinchedLive = false
    private var angleTotal = 0.0, lastAngle = 0.0
    private var scrollAllowed = true
    private var peakCount = 0, peakStart = CGPoint.zero, peakLast = CGPoint.zero, peakTime = Date.distantPast
    private var swipeFired = false
    private var edgeStart = CGPoint.zero, edgeFired = false
    // "press and tap": first finger rests on an item, a second finger taps briefly.
    private var pressAnchor = CGPoint.zero, secondDown = Date.distantPast
    private var pressTapArmed = false, pressTapFired = false, secondTravel = 0.0

    // liftoff watchdog
    private var lastFrame = Date(), watchdog: Timer?
    private var cursorHidden = false
    private func startWatchdog() {
        watchdog?.invalidate()
        watchdog = Timer.common(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self, self.settings.liftoffMs > 0, self.mode != .idle,
                  Date().timeIntervalSince(self.lastFrame) * 1000 > Double(self.settings.liftoffMs) else { return }
            TMLog.write("liftoff: no touch data for \(self.settings.liftoffMs) ms, treating the fingers as lifted")
            self.lastFrame = Date()
            self.handle([])
        }
    }
    private func setCursorHidden(_ hide: Bool) {
        guard hide != cursorHidden else { return }
        cursorHidden = hide
        // NSCursor.hide only affects our own windows; let a background process hide the system cursor like a tablet driver does.
        let cid = CGSMainConnectionID()
        _ = CGSSetConnectionProperty(cid, cid, "SetsCursorInBackground" as CFString, kCFBooleanTrue)
        if hide { CGDisplayHideCursor(CGMainDisplayID()) } else { CGDisplayShowCursor(CGMainDisplayID()) }
    }

    // anchor mouse
    private var anchorSample: CGPoint?, anchorPoint: CGPoint?, anchorSampler: Timer?, anchorReturn: Timer?
    private func startAnchorSampler() {
        anchorSampler?.invalidate(); anchorSampler = nil
        guard settings.anchorMouse else { return }
        anchorSampler = Timer.common(withTimeInterval: Double(max(settings.anchorSampleMs, 20)) / 1000, repeats: true) { [weak self] _ in
            guard let self, self.mode == .idle, self.anchorReturn == nil else { return }       // not while a touch moves the pointer
            self.anchorSample = CGEvent(source: nil)?.location
        }
    }

    public init(_ s: Settings) { settings = s; mapper = Mapper(s); activeSince = Date(); applyToInjector(); startWatchdog() }

    private func applyToInjector() {
        startAnchorSampler()
        inj.clickLasts = Double(settings.clickLastsMs) / 1000
        inj.momentumEnabled = settings.scrollMomentum
        inj.momentumDecay = 0.90 + min(max(settings.scrollInertia, 0), 1) * 0.08      // 0.90 ... 0.98 per 1/60 s
        Commander.tabletEnabled = settings.tabletScroll
    }

    // MARK: input
    public func handle(_ all: [Contact]) {
        // Deglitch: drop a contact's first N frames.
        var cs: [Contact] = []
        let ids = Set(all.map(\.id))
        seen = seen.filter { ids.contains($0.key) }; smooth = smooth.filter { ids.contains($0.key) }
        for c in all { seen[c.id, default: 0] += 1; if seen[c.id]! > settings.deglitchFrames { cs.append(c) } }
        // Low-pass filter in screen space.
        let g = min(max(settings.lowPassGain, 0), 0.95)
        let pts: [CGPoint] = cs.map { c in
            let raw = mapper.map(x: c.x, y: c.y)
            guard g > 0, let prev = smooth[c.id] else { smooth[c.id] = raw; return raw }
            let f = CGPoint(x: prev.x + (raw.x - prev.x) * (1 - g), y: prev.y + (raw.y - prev.y) * (1 - g))
            smooth[c.id] = f; return f
        }
        if Date().timeIntervalSince(activeSince) < Double(settings.startupDelaySec) { return }
        if !cs.isEmpty { lastFrame = Date() }
        onPoints?(pts)
        guard settings.enabled, injectEnabled else { if cs.isEmpty { reset() }; return }
        // Magnifier: a touch that starts inside the lens aims at the magnified content (one finger)
        // or moves / zooms the lens (two fingers).
        var ipts = pts
        if let lens, lens.lensActive {
            if mode == .idle, !cs.isEmpty { lensTouch = lens.lensContains(centroid(pts)) }
            if lensTouch && !cs.isEmpty {
                if cs.count >= 2 { lensGesture(pts); return }
                if lensMoving { return }                        // a finger left over after moving the lens stays inert
                ipts[0] = lens.lensMap(pts[0])
            }
        } else if cs.isEmpty { lensTouch = false }
        switch cs.count {
        case 0: allUp()
        case 1: oneFinger(ipts[0])
        default: manyFingers(pts)
        }
    }

    private func centroid(_ pts: [CGPoint]) -> CGPoint {
        CGPoint(x: pts.map(\.x).reduce(0, +) / Double(pts.count), y: pts.map(\.y).reduce(0, +) / Double(pts.count))
    }

    // MARK: orientation
    /// Which axes gestures must be read mirrored on: both when the display is rotated 180° (auto), or as chosen.
    private var flips: (x: Bool, y: Bool) {
        switch settings.gestureOrientation {
        case "inverted": return (true, true)
        case "normal": return (false, false)
        case "custom": return (settings.gestureFlipX, settings.gestureFlipY)
        default: let r = Int(CGDisplayRotation(mapper.display)) == 180; return (r, r)
        }
    }
    /// The point as seen in the frame gestures are recognised in.
    private func gp(_ p: CGPoint) -> CGPoint {
        let f = flips
        guard f.x || f.y else { return p }
        let r = CGDisplayBounds(mapper.display)
        return CGPoint(x: f.x ? r.minX + r.maxX - p.x : p.x, y: f.y ? r.minY + r.maxY - p.y : p.y)
    }
    private var signX: Double { flips.x ? -1 : 1 }
    private var signY: Double { flips.y ? -1 : 1 }

    // MARK: one finger
    private func oneFinger(_ p: CGPoint) {
        switch mode {
        case .idle:
            stoppedMomentum = inj.isCoasting
            inj.stopMomentum()                                  // touching a gliding page stops it
            if stoppedMomentum { TMLog.write("touch stopped a gliding page: its click is suppressed") }
            if settings.hideCursorDuringTouches { setCursorHidden(true) }
            inj.releaseStuckButtons(at: p)
            anchorReturn?.invalidate(); anchorReturn = nil
            if settings.anchorMouse { anchorPoint = anchorSample ?? CGEvent(source: nil)?.location }
            downPoint = p; lastPoint = p; downTime = Date(); mode = .pending; one = .undecided; mouseDown = false
            loadOneFingerRules(at: p)
            armHold()
            if settings.clickMode == 2, rTap == nil {                       // point and click: the click happens at the start; movement is ignored
                cancelTimers(); mode = .single; one = .done
                if settings.soundOnTouch { NSSound(named: "Tink")?.play() }
                inj.move(p); inj.click(p)
            } else if settings.clickMode == 3 {                              // no click: the pointer just follows the finger
                cancelTimers(); mode = .single; one = .moveOnly(false); inj.move(p)
            }
        case .pending:
            lastPoint = p
            decide(p)
        case .single:
            lastPoint = p
            carryOn(p)
        case .multi:
            inj.endScroll(momentum: true)                          // one finger of a two-finger scroll lifted first
            // One finger left after two: was the second a quick tap on top of a resting first finger?
            if pressTapArmed, !pressTapFired, maxFingers == 2, Date().timeIntervalSince(secondDown) < Double(settings.pressTapMaxMs) / 1000, secondTravel < 40 {
                pressTapFired = true
                onGesture?("press and tap", pressAnchor)
            }
        }
    }

    /// Which rules apply where this touch landed (looked up once per touch).
    private func loadOneFingerRules(at p: CGPoint) {
        func rule(_ g: String) -> CommanderRule? { ruleLookup?(g, p) }
        rTap = rule("one finger tap"); rPress = rule("one finger press"); rDrag = rule("one finger drag")
        rSwipe = [:]
        for d in ["left", "right", "up", "down"] { if let r = rule("one finger swipe \(d)"), r.action != "none" { rSwipe[d] = r } }
        edgeDir = nil
        if !lensTouch, let dir = edgeDirection(of: gp(p)), let r = rule("one finger swipe \(dir) from edge"), r.action != "none" { edgeDir = dir }
    }

    /// "up" when the point is in the bottom edge zone (an edge swipe from there travels up), and so on.
    private func edgeDirection(of p: CGPoint) -> String? {
        let r = CGDisplayBounds(mapper.display), m = settings.edgeMarginPx
        if p.y > r.maxY - m { return "up" }
        if p.y < r.minY + m { return "down" }
        if p.x > r.maxX - m { return "left" }
        if p.x < r.minX + m { return "right" }
        return nil
    }

    private func armHold() {
        let rest = rPress?.action ?? ((settings.rightClickOnHold && settings.holdMode != "off") ? "click" : "none")
        guard rest != "none" else { return }
        let hold = Double(settings.holdMs) / 1000
        holdTimer?.invalidate()
        holdTimer = Timer.common(withTimeInterval: hold, repeats: false) { [weak self] _ in self?.holdFired() }
        if settings.holdVisual {
            let lead = min(Double(settings.holdRingDelayMs) / 1000, max(hold - 0.1, 0))
            ringTimer?.invalidate()
            ringTimer = Timer.common(withTimeInterval: lead, repeats: false) { [weak self] _ in
                guard let self, self.mode == .pending, self.lastPoint.distance(to: self.downPoint) <= self.settings.holdRadiusPx else { return }
                self.onHoldVisual?(self.downPoint, max(0.1, hold - lead))
            }
        }
    }

    private func cancelTimers() { holdTimer?.invalidate(); cancelRing() }
    private func cancelRing() { ringTimer?.invalidate(); onHoldCancel?() }

    /// The finger is down and has not been decided yet. Look at how far it has gone.
    private func decide(_ p: CGPoint) {
        let dx = (p.x - downPoint.x) * signX, dy = (p.y - downPoint.y) * signY, d = hypot(dx, dy)

        // Edge swipe: started in an edge zone and travels inward. Nothing is sent to the mouse while we wait.
        if let e = edgeDir {
            let along = (e == "up") ? -dy : (e == "down") ? dy : (e == "left") ? -dx : dx          // inward travel
            let across = (e == "up" || e == "down") ? abs(dx) : abs(dy)
            if along >= settings.edgeDistancePx && across < along {
                cancelTimers(); mode = .single; one = .done
                TMLog.write("edge swipe: one finger \(e) from edge, travel \(Int(along))")
                onGesture?("one finger swipe \(e) from edge", downPoint)
                return
            }
            if d > 24 && along < d * 0.6 { edgeDir = nil }          // not heading inward: it is an ordinary touch after all
            else if along < settings.edgeDistancePx { return }       // still deciding between edge swipe and drag
        }

        guard d > max(settings.dragStartPx, 3) else { return }
        cancelTimers()
        let dir = abs(dx) > abs(dy) ? (dx > 0 ? "right" : "left") : (dy > 0 ? "down" : "up")
        // A swipe rule for this direction wins unless a drag rule that says mouse-drag or scroll is at least as specific:
        // the active app's rules outrank "any application" rules, whichever kind of gesture they are for.
        let dragIsStrong = rDrag.map { $0.action == "click and drag" || $0.action == "scroll" } ?? false
        if let sw = rSwipe[dir], !dragIsStrong || Commander.specificity(sw) > Commander.specificity(rDrag!) {
            mode = .single; one = .swipe(dir); carryOn(p); return
        }
        switch rDrag?.action ?? (settings.clickMode == 1 ? "move then click" : "click and drag") {
        case "move then click":                                           // the pointer follows; the click comes when the finger lifts
            mode = .single; one = .moveOnly(true); inj.move(p)
        case "click and drag":
            mode = .single; one = .drag
            startMouseDrag(at: downPoint)
            carryOn(p)
        case "scroll":
            mode = .single; one = .scroll; inj.resetScroll(); scrollLast = downPoint
            carryOn(p)
        case "none":
            mode = .single; one = .done
        default:                                                      // keystroke, open app, ...: runs once
            mode = .single; one = .done
            onGesture?("one finger drag", downPoint)
        }
    }

    /// Once decided, keep doing it.
    private func carryOn(_ p: CGPoint) {
        switch one {
        case .drag:
            inj.leftDrag(p, clicks: clicks)
        case .scroll:
            let k = settings.scrollSpeed * (settings.naturalScroll ? 1 : -1)
            inj.scroll(dx: (p.x - scrollLast.x) * k, dy: (p.y - scrollLast.y) * k)
            scrollLast = p
        case .swipe(let dir):
            let dx = p.x - downPoint.x, dy = p.y - downPoint.y
            let major = max(abs(dx), abs(dy)), minor = min(abs(dx), abs(dy))
            if major >= settings.swipeDistancePx * 0.8, major > minor * 1.3 {
                one = .done
                TMLog.write("swipe: one finger \(dir), travel \(Int(major))")
                onGesture?("one finger swipe \(dir)", downPoint)
            }
        case .rightDrag: inj.rightDrag(p)
        case .moveOnly: inj.move(p)
        case .holdPending:                                              // held long enough; moving now turns it into a drag
            if p.distance(to: downPoint) > settings.holdRadiusPx {
                one = .drag
                startMouseDrag(at: downPoint)
                inj.leftDrag(p, clicks: clicks)
            }
        case .undecided, .done, .latchedRight: break
        }
    }

    private func startMouseDrag(at p: CGPoint) {
        let now = Date()
        var q = p
        if now.timeIntervalSince(lastTapTime) * 1000 < Double(settings.assistedDoubleClickMs), q.distance(to: lastTapPoint) < settings.assistedDoubleClickPx {
            clicks += 1; q = lastTapPoint
        } else { clicks = 1 }
        downPoint = q
        inj.move(q); inj.leftDown(q, clicks: clicks); mouseDown = true
        if settings.soundOnTouch { NSSound(named: "Tink")?.play() }
    }

    private func holdFired() {
        if stoppedMomentum { return }
        guard mode == .pending, hypot(lastPoint.x - downPoint.x, lastPoint.y - downPoint.y) <= settings.holdRadiusPx else { return }
        let action = rPress?.action ?? "click"
        cancelRing()
        switch action {
        case "click":
            let button = Int(rPress?.params?["click button"] ?? "2") ?? 2
            let how = (rPress == nil && button == 2) ? settings.holdMode : "immediate"
            switch how {
            case "off": return
            case "drag":                                             // right button goes down now, up when the finger lifts
                inj.move(downPoint); inj.rightDown(downPoint); mode = .single; one = .rightDrag
            case "latched":                                          // the click happens at lift
                mode = .single; one = .latchedRight
            default:
                if button == 2 { inj.rightClick(downPoint) } else { inj.click(downPoint) }
                mode = .single; one = .done
            }
            if settings.soundOnLift { NSSound(named: "Pop")?.play() }
            clicks = 1; lastTapTime = .distantPast
        case "click and drag":                                        // press, then drag: the button goes down now
            if settings.holdReleaseMenu {                              // ...unless the finger is released without moving: then it is a menu
                mode = .single; one = .holdPending
                if settings.soundOnLift { NSSound(named: "Pop")?.play() }
            } else {
                mode = .single; one = .drag
                startMouseDrag(at: downPoint)
            }
        case "none": break
        default:
            mode = .single; one = .done
            onGesture?("one finger press", downPoint)
        }
    }

    /// Finger lifted without having moved or rested: a tap.
    private func tap() {
        if stoppedMomentum { stoppedMomentum = false; return }
        let action = rTap?.action ?? "click"
        switch action {
        case "click":
            let prm = rTap?.params ?? [:]
            var q = lastPoint.distance(to: downPoint) <= max(settings.dragStartPx, 3) ? lastPoint : downPoint   // click where the finger lifted
            if prm["click nearest"] == "true" { q = Commander.nearestClickable(q, threshold: Double(prm["threshold"] ?? "") ?? settings.clickNearestPx) }
            if settings.soundOnTouch { NSSound(named: "Tink")?.play() }
            if (Int(prm["click button"] ?? "1") ?? 1) == 2 { inj.move(q); inj.rightClick(q); return }
            let now = Date()
            if now.timeIntervalSince(lastTapTime) * 1000 < Double(settings.assistedDoubleClickMs), q.distance(to: lastTapPoint) < settings.assistedDoubleClickPx {
                clicks += 1; q = lastTapPoint            // snap so both clicks land on the same spot
            } else { clicks = 1 }
            inj.move(q); inj.click(q, clicks: clicks)
            lastTapTime = now; lastTapPoint = q
        case "none": break
        default: onGesture?("one finger tap", downPoint)
        }
    }

    // MARK: magnifier
    private func lensGesture(_ pts: [CGPoint]) {
        let c = centroid(pts)
        let spread = pts.map { hypot($0.x - c.x, $0.y - c.y) }.reduce(0, +) / Double(pts.count)
        if !lensMoving {
            lensMoving = true
            cancelTimers()
            if mouseDown { inj.leftUp(downPoint, clicks: clicks); mouseDown = false }       // the first finger's drag is cancelled
            mode = .multi
            lensLast = c; lensSpreadLast = spread; lensPinchAccum = 0; lensTravel = 0
            TMLog.write("lens: two-finger move begins at (\(Int(c.x)),\(Int(c.y)))")
            return
        }
        // Move the lens with every frame. A pinch is recognised only when the spread keeps growing or shrinking:
        // finger jitter changes sign and cancels out in the (decaying) sum, so slow drags never turn into zooms.
        lens?.lensMove(dx: c.x - lensLast.x, dy: c.y - lensLast.y)
        lensTravel += hypot(c.x - lensLast.x, c.y - lensLast.y)
        lensPinchAccum = lensPinchAccum * 0.92 + (spread - lensSpreadLast)
        if abs(lensPinchAccum) > settings.pinchStepPx { onPinchStep?(lensPinchAccum > 0 ? 1 : -1, c); lensPinchAccum = 0 }
        lensLast = c; lensSpreadLast = spread
    }

    // MARK: 2+ fingers
    private func geometry(_ pts: [CGPoint]) -> (centroid: CGPoint, spread: Double, angle: Double) {
        let c = centroid(pts)
        let spread = pts.map { hypot($0.x - c.x, $0.y - c.y) }.reduce(0, +) / Double(pts.count)
        let angle = atan2(pts[1].y - pts[0].y, pts[1].x - pts[0].x) * 180 / .pi
        return (c, spread, angle)
    }

    private func manyFingers(_ pts: [CGPoint]) {
        let g = geometry(pts), c = g.centroid
        cancelTimers()
        if mode != .multi {
            let heldFor = Date().timeIntervalSince(downTime)
            pressTapArmed = (mode == .pending) && pts.count == 2 && heldFor > Double(settings.pressTapRestMs) / 1000
                && lastPoint.distance(to: downPoint) <= settings.holdRadiusPx * 1.5
            pressAnchor = downPoint; secondDown = Date(); pressTapFired = false; secondTravel = 0
            // The first finger is where an edge swipe starts, if it landed at an edge.
            edgeStart = (mode == .pending || mode == .single) ? downPoint : c; edgeFired = false
            if mouseDown { inj.leftUp(downPoint, clicks: clicks); mouseDown = false }       // cancel the drag
            mode = .multi; inj.resetScroll(); lastCentroid = c; multiStart = c; multiStartTime = Date(); maxFingers = pts.count
            startSpread = g.spread; lastSpread = g.spread; pinchAccum = 0; pinchTotal = 0; pinchedLive = false
            lastAngle = g.angle; angleTotal = 0
            peakCount = pts.count; peakStart = c; peakLast = c; peakTime = Date(); swipeFired = false
            scrollAllowed = ruleLookup?("two finger drag", c).map { $0.action != "none" } ?? true
            return
        }
        maxFingers = max(maxFingers, pts.count)
        if pts.count != 2 { inj.endScroll(momentum: false) }          // a third finger turns the scroll into a gesture
        if pts.count > peakCount { peakCount = pts.count; peakStart = c; peakLast = c; peakTime = Date() }
        else if pts.count == peakCount { peakLast = c }

        // Two-finger edge swipe: fire as soon as the fingers have travelled inward far enough.
        if pts.count == 2, !edgeFired, !pinchedLive,
           let name = Self.edgeSwipe(from: gp(edgeStart), to: gp(c), fingers: "two", elapsed: 0, display: mapper.display, margin: settings.edgeMarginPx, need: settings.edgeDistancePx) {
            edgeFired = true
            TMLog.write("edge swipe: \(name)")
            onGesture?(name, edgeStart)
        }
        // Multi-finger swipe: fire as soon as the fingers have travelled far enough, without waiting for lift.
        if pts.count >= 3, pts.count == peakCount, !swipeFired {
            let dx = (c.x - peakStart.x) * signX, dy = (c.y - peakStart.y) * signY
            let major = max(abs(dx), abs(dy)), minor = min(abs(dx), abs(dy))
            if major > settings.swipeDistancePx, major > minor * 1.3, Date().timeIntervalSince(peakTime) < 3 {
                let w = [3: "three", 4: "four", 5: "five"][pts.count] ?? "three"
                let dir = abs(dx) > abs(dy) ? (dx > 0 ? "right" : "left") : (dy > 0 ? "down" : "up")
                swipeFired = true
                TMLog.write("swipe fired live: \(w) \(dir) travel=\(Int(major)) in \(String(format: "%.2f", Date().timeIntervalSince(peakTime)))s")
                onGesture?("\(w) finger swipe \(dir)", peakStart)
            }
        }
        secondTravel += hypot(c.x - lastCentroid.x, c.y - lastCentroid.y)
        let dSpread = g.spread - lastSpread
        var dAngle = g.angle - lastAngle
        if dAngle > 180 { dAngle -= 360 } else if dAngle < -180 { dAngle += 360 }
        let moved = hypot(c.x - lastCentroid.x, c.y - lastCentroid.y)
        let pinching = abs(dSpread) > max(1.5, moved * 1.2)       // fingers converge/diverge more than they travel
        if pinching {
            pinchTotal += dSpread; pinchAccum += dSpread
            if abs(pinchAccum) > settings.pinchStepPx { onPinchStep?(pinchAccum > 0 ? 1 : -1, c); pinchedLive = true; pinchAccum = 0 }
        }
        if pts.count == 2 { angleTotal += dAngle }
        lastSpread = g.spread; lastAngle = g.angle
        if pts.count == 2, settings.twoFingerScroll, scrollAllowed, !pinching, !edgeFired, abs(angleTotal) < 25 {
            let k = settings.scrollSpeed * (settings.naturalScroll ? 1 : -1)
            inj.scroll(dx: (c.x - lastCentroid.x) * k, dy: (c.y - lastCentroid.y) * k)
        }
        lastCentroid = c
    }

    // MARK: lift
    private func allUp() {
        if settings.anchorMouse, anchorPoint != nil, mode != .idle {
            anchorReturn?.invalidate()
            anchorReturn = Timer.common(withTimeInterval: Double(settings.anchorReturnMs) / 1000, repeats: false) { [weak self] _ in
                guard let self, let p = self.anchorPoint else { return }
                CGWarpMouseCursorPosition(p); self.anchorReturn = nil
            }
        }
        if lensMoving { TMLog.write("lens: move ends, travelled \(Int(lensTravel)) px"); reset(); return }
        cancelTimers()
        switch mode {
        case .pending:
            tap()
        case .single:
            if mouseDown { inj.leftUp(lastPoint, clicks: clicks) }
            if case .scroll = one { inj.endScroll(momentum: true) }
            if case .rightDrag = one { inj.rightUp(lastPoint) }
            if case .moveOnly(true) = one { inj.click(lastPoint) }
            if case .holdPending = one { inj.rightClick(downPoint) }          // held, then released in place: context menu
            if case .latchedRight = one { inj.rightClick(lastPoint) }
            if settings.soundOnLift, mouseDown { NSSound(named: "Pop")?.play() }
        case .multi:
            inj.endScroll(momentum: true)
            classifyMulti()
        case .idle: break
        }
        reset()
    }

    private func classifyMulti() {
        let dt = Date().timeIntervalSince(multiStartTime)
        let dx = lastCentroid.x - multiStart.x, dy = lastCentroid.y - multiStart.y
        let n = maxFingers
        let names = [2: "two", 3: "three", 4: "four", 5: "five"]
        guard let w = names[n] else { return }
        let dist = hypot(dx, dy)
        TMLog.write(String(format: "multi end: fingers=%d dt=%.2f dist=%.0f dx=%.0f dy=%.0f pinch=%.0f angle=%.0f", n, dt, dist, dx, dy, pinchTotal, angleTotal))
        if edgeFired { return }
        // Pinch (any finger count).
        let peakDist = peakStart.distance(to: peakLast)   // lifting fingers one by one drags the final centroid, so judge travel while all were down
        if abs(pinchTotal) > (n == 2 ? 60 : 50) && (n == 2 ? dist < 150 : peakDist < 110) {
            onGesture?("\(w) finger pinch \(pinchTotal > 0 ? "expand" : "contract")", multiStart); return
        }
        if n == 2 {
            if abs(angleTotal) > 30 && dist < 120 { Commander.lastRotationClockwise = angleTotal > 0; onGesture?("two finger rotate", multiStart); return }
            if dist < 20 && dt < 0.35 && !pinchedLive && !pressTapArmed && !pressTapFired { onGesture?("two finger tap", multiStart) }
            return
        }
        if swipeFired { return }
        let pdt = Date().timeIntervalSince(peakTime), pdist = peakStart.distance(to: peakLast)
        if pdist < 30 && pdt < 0.5 { onGesture?("\(w) finger tap", multiStart); return }
        TMLog.write("no \(w)-finger gesture: peak travel \(Int(pdist)) over \(String(format: "%.2f", pdt))s")
    }

    /// Edge gestures are named after the direction of travel ("swipe up from edge" starts at the bottom).
    static func edgeSwipe(from a: CGPoint, to b: CGPoint, fingers: String, elapsed: TimeInterval, display: CGDirectDisplayID, margin: Double, need: Double) -> String? {
        let r = CGDisplayBounds(display)
        guard elapsed < 0.8 || elapsed == 0 else { return nil }
        let dx = b.x - a.x, dy = b.y - a.y
        if a.y > r.maxY - margin, -dy > need, abs(dx) < -dy { return "\(fingers) finger swipe up from edge" }
        if a.y < r.minY + margin, dy > need, abs(dx) < dy { return "\(fingers) finger swipe down from edge" }
        if a.x > r.maxX - margin, -dx > need, abs(dy) < -dx { return "\(fingers) finger swipe left from edge" }
        if a.x < r.minX + margin, dx > need, abs(dy) < dx { return "\(fingers) finger swipe right from edge" }
        return nil
    }

    private func reset() {
        setCursorHidden(false)
        stoppedMomentum = false
        mode = .idle; one = .undecided; mouseDown = false; pressTapArmed = false; peakCount = 0; lensTouch = false; lensMoving = false
        edgeDir = nil
        cancelTimers()
    }
}

@_silgen_name("CGSMainConnectionID") private func CGSMainConnectionID() -> Int32
@_silgen_name("CGSSetConnectionProperty") private func CGSSetConnectionProperty(_ cid: Int32, _ target: Int32, _ key: CFString, _ value: CFTypeRef) -> Int32

extension CGPoint { func distance(to o: CGPoint) -> Double { hypot(x - o.x, y - o.y) } }
