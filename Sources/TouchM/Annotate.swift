import SwiftUI
import AppKit

/// Draw on the screen with touch (or mouse). Close with the toolbar button.
@MainActor
final class Annotate {
    static let shared = Annotate()
    private var window: NSWindow?
    func toggle() {
        if let w = window { w.orderOut(nil); window = nil; return }
        guard let screen = NSScreen.main else { return }
        let w = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        w.level = .screenSaver; w.isOpaque = false; w.backgroundColor = NSColor.black.withAlphaComponent(0.01)
        let model = InkModel(); model.onClose = { [weak self] in self?.toggle() }
        w.contentView = NSHostingView(rootView: InkView(model: model)); w.makeKeyAndOrderFront(nil); window = w
    }
}

final class InkModel: ObservableObject {
    @Published var strokes: [(color: Color, pts: [CGPoint])] = []
    @Published var color = Color.red
    var onClose: () -> Void = {}
}

struct InkView: View {
    @ObservedObject var model: InkModel
    var body: some View {
        ZStack(alignment: .top) {
            Canvas { ctx, _ in
                for s in model.strokes where s.pts.count > 1 {
                    var p = Path(); p.addLines(s.pts)
                    ctx.stroke(p, with: .color(s.color), style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
                }
            }
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in
                    if model.strokes.isEmpty || v.translation == .zero { model.strokes.append((model.color, [v.location])) }
                    else { model.strokes[model.strokes.count - 1].pts.append(v.location) }
                })
            HStack(spacing: 14) {
                ForEach([Color.red, .yellow, .green, .blue, .white], id: \.self) { c in
                    Circle().fill(c).frame(width: 30, height: 30).onTapGesture { model.color = c }
                }
                Button("Clear") { model.strokes = [] }
                Button("Close") { model.onClose() }
            }.padding(10).background(.ultraThinMaterial, in: Capsule()).padding(.top, 12)
        }
    }
}
