import SwiftUI
import AppKit

/// Click-through full-screen layer that draws touch points (feedback + test mode).
@MainActor
final class Overlay {
    static let shared = Overlay()
    private var window: NSWindow?
    private let model = OverlayModel()
    var testMode = false { didSet { refresh() } }

    func ring(at p: CGPoint, duration: TimeInterval) {
        if window == nil { make() }
        model.ring = RingState(point: p, duration: duration, id: UUID())
        let id = model.ring?.id
        DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.2) { [weak self] in if self?.model.ring?.id == id { self?.model.ring = nil } }
    }
    func cancelRing() { model.ring = nil }

    func update(_ pts: [CGPoint]) {
        guard testMode || AppModel.shared.settings.showTouchFeedback else { if window != nil { model.points = [] }; return }
        if window == nil { make() }
        let h = NSScreen.main?.frame.height ?? 0
        model.points = pts.map { CGPoint(x: $0.x, y: $0.y) }
        _ = h
    }
    private func refresh() { if testMode { make() } else if !AppModel.shared.settings.showTouchFeedback { window?.orderOut(nil); window = nil } }

    private func make() {
        guard window == nil, let screen = NSScreen.main else { return }
        let w = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        w.level = .screenSaver; w.isOpaque = false; w.backgroundColor = .clear
        w.ignoresMouseEvents = true; w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        w.contentView = NSHostingView(rootView: OverlayView(model: model))
        w.orderFrontRegardless(); window = w
    }
}

struct RingState: Equatable { var point: CGPoint; var duration: TimeInterval; var id: UUID }
final class OverlayModel: ObservableObject { @Published var points: [CGPoint] = []; @Published var ring: RingState? }

struct HoldRing: View {
    let state: RingState
    @State private var progress = 0.0
    var body: some View {
        Circle().trim(from: 0, to: progress).stroke(Color.orange, style: StrokeStyle(lineWidth: 6, lineCap: .round))
            .rotationEffect(.degrees(-90)).frame(width: 84, height: 84).position(state.point)
            .onAppear { withAnimation(.linear(duration: state.duration)) { progress = 1 } }
    }
}

struct OverlayView: View {
    @ObservedObject var model: OverlayModel
    /// Finger numbers are a test-mode aid only.
    var showNumbers: Bool { MainActor.assumeIsolated { Overlay.shared.testMode } }
    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(model.points.enumerated()), id: \.offset) { i, p in
                Circle().strokeBorder(Color.accentColor, lineWidth: 3).background(Circle().fill(Color.accentColor.opacity(0.2)))
                    .frame(width: 56, height: 56).overlay { if showNumbers { Text("\(i)").font(.caption.bold()) } }
                    .position(x: p.x, y: p.y)
            }
            if let r = model.ring { HoldRing(state: r).id(r.id) }
        }.frame(maxWidth: .infinity, maxHeight: .infinity).allowsHitTesting(false)
    }
}
