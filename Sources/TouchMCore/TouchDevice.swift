import Foundation
import IOKit.hid
import AppKit

/// Opens the touch controller through IOHIDManager, switches it to multi-touch mode,
/// and publishes contact frames.
public final class TouchDevice {
    public var vendorID = 0x0457
    public var productID: Int? = nil          // nil = any product of the vendor
    public var onFrame: (([Contact]) -> Void)?
    public var reinitOnWake = true
    private var attached: IOHIDDevice?
    public var onLog: ((String) -> Void)?
    public private(set) var connected = false
    private var lastAny = Date.distantPast, lastMulti = Date.distantPast, lastMouseMode = Date.distantPast
    private var supervisor: Timer?
    private var mouseModeActive = false
    public private(set) var info: [(String, String)] = []
    public func resendMode() { if let d = attached { modeOK = false; setMultiTouchMode(d) } }

    private let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    private let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 512)
    private var pending: [Int: Contact] = [:]

    public init() {}

    @discardableResult
    public func start() -> Bool {
        var match: [String: Int] = [kIOHIDVendorIDKey: vendorID]
        if let p = productID { match[kIOHIDProductIDKey] = p }
        IOHIDManagerSetDeviceMatching(manager, match as CFDictionary)
        let me = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { ctx, _, _, dev in
            Unmanaged<TouchDevice>.fromOpaque(ctx!).takeUnretainedValue().attach(dev)
        }, me)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { ctx, _, _, _ in
            let s = Unmanaged<TouchDevice>.fromOpaque(ctx!).takeUnretainedValue()
            s.connected = false; s.modeOK = false; s.attached = nil
            TMLog.write("touch panel removed (display sleep or USB reset?)"); s.onLog?("device removed")
        }, me)
        // macOS only delivers input reports once a value callback is registered.
        IOHIDManagerRegisterInputValueCallback(manager, { _, _, _, _ in }, nil)
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, self.reinitOnWake else { return }
            TMLog.write("wake: re-initialising the panel")
            self.modeOK = false
            for delay in [1.0, 4.0] {      // the panel can re-enumerate a moment after wake
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { if let d = self.attached, self.connected { self.setMultiTouchMode(d, quiet: delay < 4) } }
            }
        }
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        startSupervisor()
        let r = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        if r != kIOReturnSuccess { onLog?("IOHIDManagerOpen failed 0x\(String(UInt32(bitPattern: r), radix: 16)) (Input Monitoring permission?)") }
        return r == kIOReturnSuccess
    }

    private func attach(_ dev: IOHIDDevice) {
        guard (IOHIDDeviceGetProperty(dev, kIOHIDPrimaryUsagePageKey as CFString) as? Int) == 0x0D else { return }
        connected = true; attached = dev; modeOK = false
        func prop(_ k: String) -> String { IOHIDDeviceGetProperty(dev, k as CFString).map { "\($0)" } ?? "?" }
        let vid = Int(prop(kIOHIDVendorIDKey)) ?? 0, pid = Int(prop(kIOHIDProductIDKey)) ?? 0
        info = [("Product", prop(kIOHIDProductKey)), ("Manufacturer", prop(kIOHIDManufacturerKey)),
                ("USB ID", String(format: "%04X:%04X", vid, pid)), ("Serial", prop(kIOHIDSerialNumberKey)),
                ("Transport", prop(kIOHIDTransportKey)), ("Max input report", prop(kIOHIDMaxInputReportSizeKey)),
                ("Max feature report", prop(kIOHIDMaxFeatureReportSizeKey)), ("Location", prop(kIOHIDLocationIDKey))]
        onLog?("attached: \(IOHIDDeviceGetProperty(dev, kIOHIDProductKey as CFString) as? String ?? "touch device")")
        TMLog.write("touch panel attached: \(prop(kIOHIDProductKey)) \(String(format: "%04X:%04X", vid, pid))")
        _ = IOHIDDeviceOpen(dev, IOOptionBits(kIOHIDOptionsTypeNone))
        // The panel can reject feature writes right at enumeration; retry quickly now, then the supervisor keeps trying.
        for (i, delay) in [0.0, 0.4, 1.0, 2.5, 5.0].enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.connected, !self.modeOK else { return }
                self.setMultiTouchMode(dev, quiet: i < 4)
            }
        }
        let me = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(dev, buffer, 512, { ctx, _, _, _, id, rep, len in
            let s = Unmanaged<TouchDevice>.fromOpaque(ctx!).takeUnretainedValue()
            s.lastAny = Date()
            if id == 3 { s.handleMouseMode(body: rep, length: len); return }          // the panel is back in mouse mode
            guard id == TouchMProtocol.multiTouchReportID else { return }
            s.lastMulti = Date(); s.mouseModeActive = false
            // The callback buffer excludes the report ID when the descriptor uses report IDs; rebuild it.
            s.handle(reportID: id, body: rep, length: len)
        }, me)
    }

    public private(set) var modeOK = false
    public func setMultiTouchMode(_ dev: IOHIDDevice, quiet: Bool = false) {
        var report = TouchMProtocol.modeFeatureReport
        let r = IOHIDDeviceSetReport(dev, kIOHIDReportTypeFeature, CFIndex(report[0]), &report, report.count)
        // Read it back: a write that "succeeds" but is ignored would leave the panel in mouse mode.
        var back = [UInt8](repeating: 0, count: 8); var n = back.count
        let g = IOHIDDeviceGetReport(dev, kIOHIDReportTypeFeature, CFIndex(report[0]), &back, &n)
        let confirmed = g == kIOReturnSuccess && n >= 3 && back[1] == report[1]
        modeOK = r == kIOReturnSuccess && (confirmed || g != kIOReturnSuccess)
        TMLog.write("multi-touch mode: set=0x\(String(UInt32(bitPattern: r), radix: 16)) readback=\(g == kIOReturnSuccess ? back.prefix(n).map { String($0, radix: 16) }.joined(separator: " ") : "n/a") -> \(modeOK ? "ok" : "NOT ok")")
        if modeOK || !quiet { onLog?("multi-touch mode " + (modeOK ? "enabled" : "FAILED 0x\(String(UInt32(bitPattern: r), radix: 16))")) }
    }

    // MARK: supervision
    /// Keeps the panel usable: re-applies multi-touch mode until it sticks, and notices when the panel has fallen back to mouse mode.
    private func startSupervisor() {
        supervisor?.invalidate()
        supervisor = Timer.common(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self, self.connected, let dev = self.attached else { return }
            if !self.modeOK { self.setMultiTouchMode(dev, quiet: true); return }
            // Ask the panel which mode it is in; no touch is needed for this.
            var back = [UInt8](repeating: 0, count: 8); var n = back.count
            if IOHIDDeviceGetReport(dev, kIOHIDReportTypeFeature, CFIndex(TouchMProtocol.modeFeatureReport[0]), &back, &n) == kIOReturnSuccess,
               n >= 2, back[1] != TouchMProtocol.modeFeatureReport[1] {
                TMLog.write("panel reports device mode \(back[1]) instead of \(TouchMProtocol.modeFeatureReport[1]): re-applying multi-touch mode")
                self.modeOK = false; self.setMultiTouchMode(dev, quiet: true); return
            }
            // Mouse-mode reports with no multi-touch reports after them: the mode was lost silently (e.g. after the display slept).
            if self.mouseModeActive, Date().timeIntervalSince(self.lastMouseMode) < 4, Date().timeIntervalSince(self.lastMulti) > 1 {
                TMLog.write("panel is sending mouse-mode reports: multi-touch mode was lost, re-applying")
                self.modeOK = false; self.setMultiTouchMode(dev, quiet: true)
            }
        }
    }

    /// Mouse-mode report: [03][buttons][X lo hi][Y lo hi]. Used as a single-finger fallback so touch never goes completely dead.
    private func handleMouseMode(body: UnsafeMutablePointer<UInt8>, length: Int) {
        lastMouseMode = Date(); mouseModeActive = true
        let o = (body[0] == 3 && length >= 6) ? 1 : 0           // does the buffer include the report ID?
        guard length >= 5 + o - (o == 1 ? 0 : 0) else { return }
        let down = body[o] & 1 == 1
        let x = Int(body[o + 1]) | Int(body[o + 2]) << 8, y = Int(body[o + 3]) | Int(body[o + 4]) << 8
        if Date().timeIntervalSince(lastMulti) > 1 {              // only while multi-touch reports are absent
            onFrame?(down ? [Contact(id: 0, x: x, y: y, width: 1, height: 1, confident: true)] : [])
        }
    }

    private var scratch = [UInt8](repeating: 0, count: 512)
    private func handle(reportID: UInt32, body: UnsafeMutablePointer<UInt8>, length: Int) {
        // Normalise: guarantee index 0 is the report ID.
        let withID = body[0] == UInt8(reportID) && length >= 54
        var n = length
        if withID { scratch.replaceSubrange(0..<min(n, 512), with: UnsafeBufferPointer(start: body, count: min(n, 512))) }
        else { scratch[0] = UInt8(reportID); scratch.replaceSubrange(1..<min(n + 1, 512), with: UnsafeBufferPointer(start: body, count: min(n, 511))); n += 1 }
        guard let (contacts, total) = scratch.withUnsafeBufferPointer({ TouchMProtocol.parse($0.baseAddress!, length: n) }) else { return }
        for c in contacts { pending[c.id] = c }
        // A frame is complete once all `total` contacts of this scan have arrived (5 per report).
        if pending.count >= total || contacts.count < TouchMProtocol.slotsPerReport {
            onFrame?(pending.values.sorted { $0.id < $1.id })
            if total == 0 || contacts.isEmpty { onFrame?([]) }
            pending.removeAll(keepingCapacity: true)
        }
    }
}
