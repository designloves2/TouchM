import Foundation
import IOKit.hid

// Read-only probe for the SiS HID touch controller (VID 0x0457, PID 0x0819).
let vid = 0x0457, pid = 0x0819
let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
IOHIDManagerSetDeviceMatching(mgr, [kIOHIDVendorIDKey: vid, kIOHIDProductIDKey: pid] as CFDictionary)

func prop(_ d: IOHIDDevice, _ k: String) -> Any? { IOHIDDeviceGetProperty(d, k as CFString) }

IOHIDManagerRegisterDeviceMatchingCallback(mgr, { _, _, _, dev in
    print("device: \(prop(dev, kIOHIDProductKey) ?? "?")  usagePage=\(prop(dev, kIOHIDPrimaryUsagePageKey) ?? "?") usage=\(prop(dev, kIOHIDPrimaryUsageKey) ?? "?")")
    if let d = prop(dev, kIOHIDReportDescriptorKey) as? Data {
        print("report descriptor (\(d.count) bytes):\n" + d.map { String(format: "%02x", $0) }.joined(separator: " "))
    }
    if CommandLine.arguments.contains("--mt") {
        // Feature report 7 = [id, deviceMode=2 (multi-input), deviceIdentifier=1]
        var out: [UInt8] = [0x07, 0x02, 0x01]
        let r = IOHIDDeviceSetReport(dev, kIOHIDReportTypeFeature, 7, &out, out.count)
        print("set feature 07 02 01 -> 0x\(String(UInt32(bitPattern: r), radix: 16))")
        var back = [UInt8](repeating: 0, count: 8); var n = back.count
        let g = IOHIDDeviceGetReport(dev, kIOHIDReportTypeFeature, 7, &back, &n)
        print("get feature 7 -> 0x\(String(UInt32(bitPattern: g), radix: 16)) bytes:", back.prefix(n).map { String(format: "%02x", $0) }.joined(separator: " "))
    }
    let elems = IOHIDDeviceCopyMatchingElements(dev, nil, IOOptionBits(kIOHIDOptionsTypeNone)) as? [IOHIDElement] ?? []
    for e in elems where IOHIDElementGetType(e) == kIOHIDElementTypeInput_Misc || IOHIDElementGetType(e) == kIOHIDElementTypeInput_Button {
        print(String(format: "  page=0x%02x usage=0x%02x min=%d max=%d", IOHIDElementGetUsagePage(e), IOHIDElementGetUsage(e), IOHIDElementGetLogicalMin(e), IOHIDElementGetLogicalMax(e)))
    }
}, nil)

let bufSize = 128
let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
var shown = 0
IOHIDManagerRegisterInputReportCallback(mgr, { _, _, _, _, id, rep, len in
    if shown < 12 { shown += 1; print("report id=\(id) len=\(len):", (0..<min(len, 24)).map { String(format: "%02x", rep[$0]) }.joined(separator: " ")) }
    guard id == 0x91, len >= 51 else { return }
    // 5 slots x 10 bytes: flags, contactID, X(16), Y(16), W(16), H(16); then count, scantime
    var out: [String] = []
    for i in 0..<5 {
        let o = i * 10
        let f = rep[o]
        guard f & 1 == 1 else { continue }
        let x = Int(rep[o+2]) | Int(rep[o+3]) << 8, y = Int(rep[o+4]) | Int(rep[o+5]) << 8
        out.append("id\(rep[o+1]) (\(x),\(y))")
    }
    if !out.isEmpty { print("touch:", out.joined(separator: "  "), " raw:", (0..<min(len, 16)).map { String(format: "%02x", rep[$0]) }.joined(separator: " ")) }
}, nil)
var vcount = 0
IOHIDManagerRegisterInputValueCallback(mgr, { _, _, _, value in
    let e = IOHIDValueGetElement(value)
    let page = IOHIDElementGetUsagePage(e), usage = IOHIDElementGetUsage(e)
    guard page == 0x01 || page == 0x0d || page == 0x09, vcount < 80 else { return }
    vcount += 1
    print(String(format: "value page=0x%02x usage=0x%02x = %d", page, usage, IOHIDValueGetIntegerValue(value)))
}, nil)
let seconds = Double(CommandLine.arguments.dropFirst().first { Double($0) != nil } ?? "10") ?? 10
IOHIDManagerScheduleWithRunLoop(mgr, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
let r = IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))   // non-seizing open
print("open result: 0x\(String(UInt32(bitPattern: r), radix: 16)) (0 = ok)")
CFRunLoopRunInMode(.defaultMode, seconds, false)
