import SwiftUI
import AppKit
import TouchMCore

final class KeyWindow: NSWindow { override var canBecomeKey: Bool { true } }

/// Full-screen multi-point calibration. Samples raw panel coordinates and fits an affine transform.
@MainActor
final class Calibration: ObservableObject {
    static let shared = Calibration()
    @Published var step = 0
    @Published var message = ""
    private var window: NSWindow?
    private var keyMonitor: Any?
    private var samples: [(raw: (Double, Double), target: (Double, Double))] = []
    private var last: Contact?
    var targets: [(Double, Double)] = Mapper.targets(4)

    func begin() {
        guard let screen = NSScreen.main else { return }
        targets = Mapper.targets(AppModel.shared.settings.calibrationPoints)
        step = 0; samples = []; message = "Touch the target"; last = nil
        let w = KeyWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        w.level = .screenSaver; w.backgroundColor = .black
        w.contentView = NSHostingView(rootView: CalibrationView(cal: self)); w.makeKeyAndOrderFront(nil); window = w
        var s = AppModel.shared.settings; s.calibration = nil; AppModel.shared.settings = s   // calibrate from raw
        AppModel.shared.rawTap = { [weak self] cs in Task { @MainActor in self?.feed(cs) } }
        NSApp.activate(ignoringOtherApps: true)
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            if e.keyCode == 53 { self?.cancel(); return nil }; return e
        }
    }

    private func feed(_ cs: [Contact]) {
        if let c = cs.first, cs.count == 1 { last = c; return }
        guard cs.isEmpty, let c = last else { return }          // finger lifted: take the last good point
        last = nil
        samples.append(((Double(c.x) / TouchMProtocol.rawMax, Double(c.y) / TouchMProtocol.rawMax), targets[step]))
        step += 1
        if step == targets.count { finish() }
    }

    private func finish() {
        AppModel.shared.rawTap = nil
        if let a = Mapper.fit(samples) {
            var s = AppModel.shared.settings; s.calibration = a; s.calibrationRotation = Int(CGDisplayRotation(CGMainDisplayID())); AppModel.shared.settings = s
            let e = Mapper.rms(a, samples) * Double(NSScreen.main?.frame.width ?? 1000)
            message = String(format: "Calibration saved (average error %.1f px)", e)
        } else { message = "Calibration failed — try again" }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in self?.cancel() }
    }
    func cancel() {
        AppModel.shared.rawTap = nil; window?.orderOut(nil); window = nil
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
    }
}

struct CalibrationView: View {
    @ObservedObject var cal: Calibration
    var body: some View {
        GeometryReader { g in
            ZStack {
                Color.black
                Text(cal.step < cal.targets.count ? "Touch each cross (\(cal.step + 1)/\(cal.targets.count)) — Esc to cancel" : cal.message).foregroundColor(.white).font(.title)
                if cal.step < cal.targets.count {
                    let t = cal.targets[cal.step]
                    Image(systemName: "plus.circle").font(.system(size: 64)).foregroundColor(.green)
                        .position(x: g.size.width * t.0, y: g.size.height * t.1)
                }
            }
        }.ignoresSafeArea()
    }
}
