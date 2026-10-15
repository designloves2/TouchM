import SwiftUI
import AppKit
import ScreenCaptureKit
import CoreMedia
import CoreImage
import TouchMCore

/// Borderless floating lens showing a live, magnified view of the screen beneath it.
///
/// How it works
/// - One full-display capture stream runs while the lens is open; the lens window itself is excluded from it.
/// - The lens never reconfigures the stream. Moving or zooming only re-crops the newest frame (`updateRegion`),
///   so the lens reacts instantly and the image can only be as old as the last captured frame.
/// - The region shown is always centred exactly on the lens centre, so the lens centre is the magnified centre.
/// - The lens ignores mouse events. The gesture engine re-aims touches that land inside it (`map`) and moves it
///   with two fingers (`move`).
final class MagnifierPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Black backing with one child layer that carries the captured frame, positioned/cropped by `Magnifier.updateRegion`.
final class MagnifierVideoView: NSView {
    let frameLayer = CALayer()
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.black.cgColor
        frameLayer.contentsGravity = .resize
        frameLayer.magnificationFilter = .linear
        frameLayer.minificationFilter = .linear
        frameLayer.actions = ["contents": NSNull(), "contentsRect": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer?.addSublayer(frameLayer)
    }
    required init?(coder: NSCoder) { fatalError() }
}

/// Bridges the gesture engine (runs on the main thread) to the main-actor magnifier.
final class LensAdapter: LensHook {
    var lensActive: Bool { MainActor.assumeIsolated { Magnifier.shared.interactive } }
    func lensContains(_ p: CGPoint) -> Bool { MainActor.assumeIsolated { Magnifier.shared.contains(p) } }
    func lensMap(_ p: CGPoint) -> CGPoint { MainActor.assumeIsolated { Magnifier.shared.map(p) } }
    func lensMove(dx: Double, dy: Double) { MainActor.assumeIsolated { Magnifier.shared.move(dx: dx, dy: dy) } }
}

@MainActor
final class Magnifier: NSObject, SCStreamOutput, SCStreamDelegate {
    static let shared = Magnifier()

    private var panel: MagnifierPanel?
    private var video: MagnifierVideoView?
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "touchm.magnifier", qos: .userInteractive)
    private var observers: [NSObjectProtocol] = []
    private var mouseTimer: Timer?
    private var askedForScreenRecording = false
    private var settings: TouchMCore.Settings { AppModel.shared.settings }

    private(set) var zoom: CGFloat = 2
    private var circle = false
    var isVisible: Bool { panel != nil }

    /// The lens stays where it was put; touches inside it aim at the magnified content.
    var interactive: Bool { isVisible && settings.magnifierFollow == "never" }

    // MARK: geometry (global top-left coordinates unless noted)
    private var screenSize: CGSize { NSScreen.screens.first?.frame.size ?? .zero }

    /// Lens centre in top-left coordinates.
    private var lensCentre: CGPoint? {
        guard let f = panel?.frame else { return nil }
        return CGPoint(x: f.midX, y: screenSize.height - f.midY)
    }

    func contains(_ p: CGPoint) -> Bool {
        guard let f = panel?.frame else { return false }
        return f.contains(CGPoint(x: p.x, y: screenSize.height - p.y))
    }

    /// Lens point -> the screen point it displays: c + (p - c) / zoom, c being the lens centre.
    func map(_ p: CGPoint) -> CGPoint {
        guard let c = lensCentre else { return p }
        let s = screenSize
        let q = CGPoint(x: c.x + (p.x - c.x) / zoom, y: c.y + (p.y - c.y) / zoom)
        return CGPoint(x: min(max(q.x, 0), s.width - 1), y: min(max(q.y, 0), s.height - 1))
    }

    func move(dx: Double, dy: Double) {
        guard let w = panel else { return }
        var o = NSPoint(x: w.frame.origin.x + dx, y: w.frame.origin.y - dy)
        // The lens may hang off the screen (to reach corner buttons) but its centre must stay on it.
        let s = screenSize, half = w.frame.size
        o.x = min(max(o.x, -half.width / 2), s.width - half.width / 2)
        o.y = min(max(o.y, -half.height / 2), s.height - half.height / 2)
        w.setFrameOrigin(o)                                   // didMove -> updateRegion
    }

    // MARK: public API
    func toggle(zoomPercent: Int? = nil, size: CGSize? = nil, circle: Bool? = nil, at p: CGPoint? = nil) {
        if isVisible { hide() } else { show(zoomPercent: zoomPercent, size: size, circle: circle, at: p) }
    }

    func adjust(by factor: CGFloat) { setZoom(zoom * factor) }

    func pinch(expand: Bool) {
        let step = pow(1.12, settings.magnifierPinchSpeed)
        adjust(by: (expand != settings.magnifierZoomReversed) ? step : 1 / step)
    }

    /// Only used by the optional "follow touches / mouse" modes: centre the lens on the point.
    func touch(_ p: CGPoint) {
        guard isVisible, settings.magnifierFollow == "touches" else { return }
        follow(to: p)
    }

    /// Apply changed settings to an open lens immediately (size, zoom, shape, refresh rate, follow mode).
    func settingsChanged() {
        guard let w = panel else { return }
        let wantZoom = CGFloat(settings.magnifierZoom) / 100
        if abs(wantZoom - zoom) > 0.004 { zoom = min(max(wantZoom, 1.25), 8) }
        circle = settings.magnifierCircle
        // Resize around the current centre so the magnified spot does not jump.
        let want = NSSize(width: settings.magnifierWidth, height: settings.magnifierHeight)
        if abs(w.frame.width - want.width) > 0.5 || abs(w.frame.height - want.height) > 0.5 {
            let f = w.frame
            w.setFrame(NSRect(x: f.midX - want.width / 2, y: f.midY - want.height / 2, width: want.width, height: want.height), display: true)
            video?.frame = NSRect(origin: .zero, size: want)
        }
        startMouseFollow(); updateRegion(); applyShape()
        if let s = stream { Task { try? await s.updateConfiguration(makeConfig(for: nil)) } }
    }

    // MARK: show / hide
    func show(zoomPercent: Int?, size: CGSize?, circle: Bool?, at p: CGPoint?) {
        zoom = CGFloat(min(max(zoomPercent ?? settings.magnifierZoom, 125), 800)) / 100
        self.circle = circle ?? settings.magnifierCircle
        let sz = size ?? CGSize(width: settings.magnifierWidth, height: settings.magnifierHeight)
        let s = screenSize
        let centre = p ?? CGPoint(x: s.width / 2, y: s.height / 2)
        let rect = NSRect(x: centre.x - sz.width / 2, y: s.height - centre.y - sz.height / 2, width: sz.width, height: sz.height)

        let w = MagnifierPanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        w.level = .screenSaver; w.isOpaque = false; w.backgroundColor = .clear; w.hasShadow = true
        w.isReleasedWhenClosed = false; w.ignoresMouseEvents = true
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        let v = MagnifierVideoView(frame: NSRect(origin: .zero, size: sz))
        w.contentView = v
        w.setContentSize(sz)
        panel = w; video = v; regionLogs = 0
        applyShape(); updateRegion()
        w.orderFrontRegardless()

        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: w, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateRegion() }
        })
        Task { await startStream() }
        startMouseFollow()
    }

    func hide() {
        mouseTimer?.invalidate(); mouseTimer = nil
        observers.forEach(NotificationCenter.default.removeObserver); observers = []
        let s = stream; stream = nil
        Task { try? await s?.stopCapture() }
        panel?.orderOut(nil); panel = nil; video = nil
    }

    // MARK: following (optional modes)
    private func startMouseFollow() {
        mouseTimer?.invalidate(); mouseTimer = nil
        guard settings.magnifierFollow == "mouse" else { return }
        mouseTimer = Timer.common(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let m = NSEvent.mouseLocation
                self.follow(to: CGPoint(x: m.x, y: self.screenSize.height - m.y))
            }
        }
    }

    private func follow(to p: CGPoint) {
        guard let w = panel else { return }
        let size = w.frame.size, s = screenSize
        w.setFrameOrigin(NSPoint(x: p.x - size.width / 2, y: s.height - p.y - size.height / 2))
    }

    // MARK: shape / zoom
    private func setZoom(_ z: CGFloat) {
        zoom = min(max(z, 1.25), 8)
        updateRegion()
        AppModel.shared.settings.magnifierZoom = Int((zoom * 100).rounded())
    }

    private func applyShape() {
        guard let l = video?.layer, let f = panel?.frame else { return }
        l.cornerRadius = circle ? min(f.width, f.height) / 2 : 16
        l.borderWidth = 3; l.borderColor = NSColor.white.withAlphaComponent(0.9).cgColor
    }

    /// Crop the newest captured frame to the region centred under the lens and lay it out inside the lens.
    /// The region may extend past the screen edge; that part is simply left black (CALayer draws nothing for a
    /// crop outside the image, so only the on-screen intersection is drawn).
    func updateRegion() {
        guard let f = panel?.frame, let layer = video?.frameLayer else { return }
        let sz = screenSize
        let rw = f.width / zoom, rh = f.height / zoom
        let c = CGPoint(x: f.midX, y: sz.height - f.midY)
        let region = CGRect(x: c.x - rw / 2, y: c.y - rh / 2, width: rw, height: rh)
        let vis = region.intersection(CGRect(origin: .zero, size: sz))
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard !vis.isNull, vis.width > 0, vis.height > 0 else { layer.isHidden = true; return }
        layer.isHidden = false
        // Lens view is non-flipped (origin bottom-left); the region is in top-left coordinates.
        layer.frame = CGRect(x: (vis.minX - region.minX) * zoom, y: (region.maxY - vis.maxY) * zoom,
                             width: vis.width * zoom, height: vis.height * zoom)
        // contentsRect also has its origin at the bottom-left (verified empirically).
        layer.contentsRect = CGRect(x: vis.minX / sz.width, y: (sz.height - vis.maxY) / sz.height,
                                    width: vis.width / sz.width, height: vis.height / sz.height)
        applyShape()
        if regionLogs < 3 { regionLogs += 1; TMLog.write("magnifier region=\(region) vis=\(vis) layer=\(layer.frame) contentsRect=\(layer.contentsRect) lens=\(f)") }
    }
    private var regionLogs = 0

    // MARK: capture
    private func makeConfig(for display: SCDisplay?) -> SCStreamConfiguration {
        let c = SCStreamConfiguration()
        c.pixelFormat = kCVPixelFormatType_32BGRA
        c.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(settings.magnifierHz, 5)))
        c.queueDepth = 3; c.showsCursor = true
        let id = display?.displayID ?? CGMainDisplayID()
        c.width = CGDisplayPixelsWide(id); c.height = CGDisplayPixelsHigh(id)      // native pixels: sharp when magnified
        return c
    }

    private func startStream() async {
        guard let panel else { return }
        do {
            var content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            var me = content.windows.filter { $0.windowID == CGWindowID(panel.windowNumber) }
            var tries = 0
            while me.isEmpty && tries < 20 {          // a freshly shown window needs a moment to appear in the list
                try await Task.sleep(nanoseconds: 50_000_000)
                content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                me = content.windows.filter { $0.windowID == CGWindowID(panel.windowNumber) }
                tries += 1
            }
            TMLog.write("magnifier: lens window \(me.isEmpty ? "NOT FOUND (will capture itself)" : "excluded") after \(tries) retries")
            guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first else { return }
            let s = SCStream(filter: SCContentFilter(display: display, excludingWindows: me), configuration: makeConfig(for: display), delegate: self)
            try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
            try await s.startCapture()
            stream = s
            AppModel.shared.screenCaptureWorks = true
            Self.frameCount = 0
            TMLog.write("magnifier started zoom=\(zoom) hz=\(settings.magnifierHz)")
        } catch {
            TMLog.write("magnifier failed: \(error)  preflight=\(CGPreflightScreenCaptureAccess())")
            hide()
            // Only a refusal needs the user: ask once per run, never loop.
            if (error as NSError).code == -3801 || !CGPreflightScreenCaptureAccess() {
                AppModel.shared.status = "Magnifier needs Screen Recording permission"
                if !askedForScreenRecording { askedForScreenRecording = true; CGRequestScreenCaptureAccess(); AppModel.shared.openPrivacy("Privacy_ScreenCapture") }
            } else { AppModel.shared.status = "Magnifier failed: \(error.localizedDescription)" }
        }
    }

    private nonisolated(unsafe) static var frameCount = 0
    nonisolated func stream(_ s: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        guard let pb = CMSampleBufferGetImageBuffer(sb), let surf = CVPixelBufferGetIOSurface(pb)?.takeUnretainedValue() else {
            if Self.frameCount < 3 { TMLog.write("magnifier: frame without pixels") }
            Self.frameCount += 1; return
        }
        Self.frameCount += 1
        if Self.frameCount == 1 || Self.frameCount == 120 {
            TMLog.write("magnifier frame #\(Self.frameCount): \(CVPixelBufferGetWidth(pb))x\(CVPixelBufferGetHeight(pb)) fmt=\(CVPixelBufferGetPixelFormatType(pb))")
            let ci = CIImage(cvPixelBuffer: pb)
            if let cg = CIContext().createCGImage(ci, from: ci.extent), let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) {
                try? png.write(to: Store.dir.appendingPathComponent("magnifier-frame-\(Self.frameCount).png"))
            }
        }
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                CATransaction.begin(); CATransaction.setDisableActions(true)
                self.video?.frameLayer.contents = surf
                CATransaction.commit()
            }
        }
    }

    nonisolated func stream(_ s: SCStream, didStopWithError error: Error) {
        TMLog.write("magnifier stream stopped: \(error)")
        DispatchQueue.main.async { MainActor.assumeIsolated { self.hide() } }
    }
}
