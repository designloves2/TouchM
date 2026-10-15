import AppKit
import CoreGraphics
import TouchMCore

/// Resolution / HiDPI mode switching and screen rotation, per display.
@MainActor
final class DisplayModes: ObservableObject {
    static let shared = DisplayModes()
    @Published private(set) var tick = 0           // bumps after a change so views re-read the current state

    struct Mode: Identifiable, Hashable {
        let cg: CGDisplayMode
        var id: Int32 { cg.ioDisplayModeID }
        var width: Int { cg.width }
        var height: Int { cg.height }
        var hidpi: Bool { cg.pixelWidth > cg.width }
        var hz: Double { cg.refreshRate }
        var label: String {
            "\(width) × \(height)" + (hidpi ? " HiDPI" : "") + (hz > 0 ? " · \(Int(hz.rounded())) Hz" : "")
        }
        static func == (a: Mode, b: Mode) -> Bool { a.id == b.id }
        func hash(into h: inout Hasher) { h.combine(id) }
    }

    /// Modes a person would pick from: usable on the desktop, with HiDPI variants included, best first.
    func modes(for id: CGDirectDisplayID) -> [Mode] {
        let opts = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        let all = (CGDisplayCopyAllDisplayModes(id, opts) as? [CGDisplayMode]) ?? []
        var seen = Set<String>()
        return all.filter { $0.isUsableForDesktopGUI() && $0.width >= 800 }.map(Mode.init)
            .sorted { ($0.width, $0.height, $0.hidpi ? 1 : 0, $0.hz) > ($1.width, $1.height, $1.hidpi ? 1 : 0, $1.hz) }
            .filter { seen.insert($0.label).inserted }
    }
    func current(for id: CGDirectDisplayID) -> Mode? { CGDisplayCopyDisplayMode(id).map(Mode.init) }

    func set(_ m: Mode, for id: CGDirectDisplayID) {
        var cfg: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&cfg) == .success, let c = cfg else { return }
        CGConfigureDisplayWithDisplayMode(c, id, m.cg, nil)
        if CGCompleteDisplayConfiguration(c, .permanently) != .success { CGCancelDisplayConfiguration(c) }
        tick += 1
    }

    // MARK: rotation
    private typealias RotFn = @convention(c) (UInt32, Int32) -> Int32
    /// Rotation goes through SkyLight's SLSSetDisplayRotation: the display ID and an angle in degrees.
    private let setRotation: RotFn? = {
        let h = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW)
        return dlsym(h, "SLSSetDisplayRotation").map { unsafeBitCast($0, to: RotFn.self) }
    }()
    func rotation(for id: CGDirectDisplayID) -> Int { Int(CGDisplayRotation(id)) }
    var canRotate: Bool { setRotation != nil }
    func rotate(_ degrees: Int, for id: CGDirectDisplayID) {
        guard [0, 90, 180, 270].contains(degrees), let setRotation else { return }
        let r = setRotation(id, Int32(degrees))
        TMLog.write("rotate display \(id) to \(degrees): result \(r)")
        tick += 1
    }
}
