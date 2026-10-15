import AppKit
import IOKit
import TouchMCore
import CoreGraphics

/// Display brightness: DDC/CI over the display cable (Apple Silicon, IOAVService) with a software gamma fallback.
/// Written from the public DDC/CI (VESA MCCS) protocol.
@MainActor
final class Brightness: ObservableObject {
    static let shared = Brightness()

    struct Screen: Identifiable { let id: CGDirectDisplayID; let name: String; let builtin: Bool }
    @Published private(set) var screens: [Screen] = []
    /// 0...1 per display; DDC supplies its own value, software dimming is remembered here.
    @Published var values: [CGDirectDisplayID: Double] = [:]
    /// Contrast 0...1 (0.5 = unchanged for software; DDC takes it as the monitor's own 0-100 scale).
    @Published var contrast: [CGDirectDisplayID: Double] = [:]
    @Published var ddcWorks: [CGDirectDisplayID: Bool] = [:]
    private var ddcMax: [CGDirectDisplayID: Int] = [:]
    private var queue = DispatchQueue(label: "touchm.ddc")

    init() { refresh() }

    func refresh() {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16); var n: UInt32 = 0
        CGGetActiveDisplayList(16, &ids, &n)
        screens = ids.prefix(Int(n)).map { id in
            let name = NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id }?.localizedName ?? "Display \(id)"
            return Screen(id: id, name: name, builtin: CGDisplayIsBuiltin(id) != 0)
        }
        for s in screens where values[s.id] == nil { values[s.id] = saved(s.id) ?? 1; contrast[s.id] = (UserDefaults.standard.object(forKey: key(s.id) + ".contrast") as? Double) ?? 0.5 }
    }
    private func key(_ id: CGDirectDisplayID) -> String { "brightness.\(CGDisplayVendorNumber(id)).\(CGDisplayModelNumber(id)).\(CGDisplaySerialNumber(id))" }
    private func saved(_ id: CGDirectDisplayID) -> Double? { UserDefaults.standard.object(forKey: key(id)) as? Double }

    /// Set brightness 0...1 (software dimming never goes below 5 % so the screen cannot be lost).
    func set(_ v: Double, for id: CGDirectDisplayID, method: String) {
        values[id] = min(max(v, 0), 1)
        UserDefaults.standard.set(values[id]!, forKey: key(id))
        push(0x10, values[id]!, id, method)
    }
    func setContrast(_ v: Double, for id: CGDirectDisplayID, method: String) {
        contrast[id] = min(max(v, 0), 1)
        UserDefaults.standard.set(contrast[id]!, forKey: key(id) + ".contrast")
        push(0x12, contrast[id]!, id, method)
    }
    /// Hardware first (external displays, unless software was chosen), software gamma otherwise.
    private func push(_ vcp: UInt8, _ v: Double, _ id: CGDirectDisplayID, _ method: String) {
        let hardware = method != "software" && CGDisplayIsBuiltin(id) == 0
        if hardware { sendHardware(vcp, Int((v * 100).rounded()), id) }
        applyGamma(id, hardware: method == "ddc" && hardware)
    }
    /// Monitors drop DDC writes while busy, so a dragged slider must not flood them: only the value the slider settles on is sent,
    /// then read back and re-sent until the monitor reports it.
    private var pending: [String: Int] = [:]
    private func sendHardware(_ vcp: UInt8, _ percent: Int, _ id: CGDirectDisplayID) {
        let k = "\(id).\(vcp)"
        let gen = (pending[k] ?? 0) + 1
        pending[k] = gen
        queue.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, !self.superseded(k, gen) else { return }
            var ok = false
            for attempt in 0..<4 {
                ok = self.ddcSet(vcp, percent, id: id)
                guard ok else { break }
                Thread.sleep(forTimeInterval: attempt == 0 ? 1.2 : 1.8)      // the monitor needs a moment to apply it
                if let r = self.ddcGet(vcp, id: id), abs(r.cur * 100 / max(r.max, 1) - percent) <= 1 { break }
                if self.superseded(k, gen) { return }
            }
            DispatchQueue.main.async { self.ddcWorks[id] = ok }
        }
    }
    nonisolated private func superseded(_ k: String, _ gen: Int) -> Bool { DispatchQueue.main.sync { [self] in pending[k] != gen } }
    /// Re-apply the remembered software settings (display changes and wake reset the gamma table).
    func reapply(method: String) {
        refresh()
        readHardware(method: method)
        for s in screens { applyGamma(s.id, hardware: method == "ddc" && !s.builtin) }
    }
    /// Gamma table: contrast stretches around mid-grey, brightness scales. Hardware mode leaves the table neutral.
    private func applyGamma(_ id: CGDirectDisplayID, hardware: Bool) {
        let br = hardware ? 1 : max(values[id] ?? 1, 0.05), c = hardware ? 1 : 0.5 + (contrast[id] ?? 0.5)
        var t = [CGGammaValue](repeating: 0, count: 256)
        for i in 0..<256 { t[i] = Float(min(max(((Double(i) / 255 - 0.5) * c + 0.5), 0), 1) * br) }
        CGSetDisplayTransferByTable(id, 256, t, t, t)
    }
    func restoreGamma() { CGDisplayRestoreColorSyncSettings() }

    // MARK: DDC/CI through IOAVService
    private typealias CreateFn = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
    private typealias WriteFn = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn
    private typealias ReadFn = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn
    private let create: CreateFn? = { dlsym(UnsafeMutableRawPointer(bitPattern: -2), "IOAVServiceCreateWithService").map { unsafeBitCast($0, to: CreateFn.self) } }()
    private let write: WriteFn? = { dlsym(UnsafeMutableRawPointer(bitPattern: -2), "IOAVServiceWriteI2C").map { unsafeBitCast($0, to: WriteFn.self) } }()
    private let read: ReadFn? = { dlsym(UnsafeMutableRawPointer(bitPattern: -2), "IOAVServiceReadI2C").map { unsafeBitCast($0, to: ReadFn.self) } }()

    /// External AV services, in registry order.
    private func externalServices() -> [CFTypeRef] {
        guard let create else { return [] }
        var out: [CFTypeRef] = []
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("DCPAVServiceProxy"), &it) == KERN_SUCCESS else { return [] }
        while case let s = IOIteratorNext(it), s != 0 {
            let loc = IORegistryEntryCreateCFProperty(s, "Location" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
            if loc == "External", let svc = create(kCFAllocatorDefault, s)?.takeRetainedValue() { out.append(svc) }
            IOObjectRelease(s)
        }
        IOObjectRelease(it)
        return out
    }
    private typealias EDIDFn = @convention(c) (CFTypeRef, UnsafeMutablePointer<Unmanaged<CFData>?>) -> IOReturn
    private let copyEDID: EDIDFn? = { dlsym(UnsafeMutableRawPointer(bitPattern: -2), "IOAVServiceCopyEDID").map { unsafeBitCast($0, to: EDIDFn.self) } }()
    /// The service whose EDID names this display's vendor and product; with no match the services are paired in order.
    private func service(for id: CGDirectDisplayID) -> CFTypeRef? {
        let svcs = externalServices()
        if let copyEDID {
            for svc in svcs {
                var d: Unmanaged<CFData>?
                guard copyEDID(svc, &d) == kIOReturnSuccess, let edid = d?.takeRetainedValue() as Data?, edid.count >= 12 else { continue }
                let vendor = UInt32(edid[8]) << 8 | UInt32(edid[9]), model = UInt32(edid[11]) << 8 | UInt32(edid[10])
                if vendor == CGDisplayVendorNumber(id) && model == CGDisplayModelNumber(id) { return svc }
            }
        }
        let externals = screens.filter { !$0.builtin }.map(\.id)
        guard let i = externals.firstIndex(of: id), i < svcs.count else { return nil }
        return svcs[i]
    }
    nonisolated private func packet(_ vcp: UInt8, _ value: UInt16) -> [UInt8] {
        var b: [UInt8] = [0x84, 0x03, vcp, UInt8(value >> 8), UInt8(value & 0xFF)]
        var chk: UInt8 = 0x6E ^ 0x51; for x in b { chk ^= x }
        b.append(chk); return b
    }
    /// Current and maximum value of a VCP feature, read from the monitor (so the sliders start where the monitor really is).
    nonisolated private func ddcGet(_ vcp: UInt8, id: CGDirectDisplayID) -> (cur: Int, max: Int)? {
        // Only the lookup runs on the main thread; the slow I2C traffic must not block the UI.
        guard let svc = DispatchQueue.main.sync(execute: { [self] in service(for: id) }), let write, let read else { return nil }
        do {
            var req: [UInt8] = [0x82, 0x01, vcp]
            var chk: UInt8 = 0x6E ^ 0x51; for x in req { chk ^= x }
            req.append(chk)
            for _ in 0..<3 {
                guard write(svc, 0x37, 0x51, &req, UInt32(req.count)) == kIOReturnSuccess else { return nil }
                usleep(60_000)
                var buf = [UInt8](repeating: 0, count: 16)
                guard read(svc, 0x37, 0x51, &buf, UInt32(buf.count)) == kIOReturnSuccess else { continue }
                // Reply: [.., 0x02, result, vcp, type, maxH, maxL, curH, curL, chk]; look for the 0x02 that is followed by our code.
                for i in 0..<(buf.count - 9) where buf[i] == 0x02 && buf[i + 1] == 0 && buf[i + 2] == vcp {
                    return (Int(buf[i + 6]) << 8 | Int(buf[i + 7]), Int(buf[i + 4]) << 8 | Int(buf[i + 5]))
                }
                TMLog.write("ddc read of \(vcp): unexpected reply \(buf.map { String($0, radix: 16) })")
            }
            return nil
        }
    }
    /// Ask every external monitor for its real brightness and contrast.
    func readHardware(method: String) {
        guard method != "software" else { return }
        for s in screens where !s.builtin {
            queue.async { [self] in
                for (vcp, isBrightness) in [(UInt8(0x10), true), (UInt8(0x12), false)] {
                    guard let r = ddcGet(vcp, id: s.id), r.max > 0 else { continue }
                    DispatchQueue.main.async {
                        self.ddcMax[s.id] = max(self.ddcMax[s.id] ?? 0, r.max)
                        let v = Double(r.cur) / Double(r.max)
                        if isBrightness { self.values[s.id] = v } else { self.contrast[s.id] = v }
                        self.ddcWorks[s.id] = true
                        TMLog.write("ddc read \(isBrightness ? "brightness" : "contrast") of \(s.name): \(r.cur)/\(r.max)")
                    }
                }
            }
        }
    }
    nonisolated private func ddcSet(_ vcp: UInt8, _ percent: Int, id: CGDirectDisplayID) -> Bool {
        let (svcOpt, maxV): (CFTypeRef?, Int) = DispatchQueue.main.sync { [self] in (service(for: id), ddcMax[id] ?? 100) }
        guard let write, let svc = svcOpt else { return false }
        do {
            var data = packet(vcp, UInt16(percent * maxV / 100))
            for _ in 0..<2 {                      // DDC/CI is flaky; send twice
                if write(svc, 0x37, 0x51, &data, UInt32(data.count)) != kIOReturnSuccess { return false }
                usleep(40_000)
            }
            return true
        }
    }
}
