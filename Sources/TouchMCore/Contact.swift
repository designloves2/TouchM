import Foundation

/// One finger as reported by the panel. Coordinates are raw panel units (0...4095).
public struct Contact: Equatable {
    public var id: Int
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int
    public var confident: Bool
    public init(id: Int, x: Int, y: Int, width: Int, height: Int, confident: Bool) {
        self.id = id; self.x = x; self.y = y; self.width = width; self.height = height; self.confident = confident
    }
}

public enum TouchMProtocol {
    public static let rawMax = 4095.0
    public static let multiTouchReportID: UInt32 = 0x91
    public static let slotsPerReport = 5
    public static let bytesPerSlot = 10
    /// Feature report that selects the panel's input mode:
    /// [reportID, deviceMode (2 = multi-input), deviceIdentifier (1)]
    public static let modeFeatureReport: [UInt8] = [0x07, 0x02, 0x01]

    /// Parse an input report (buffer includes the report-ID byte at index 0).
    /// Slot layout: flags(tip,confidence) | contactID | X16 | Y16 | W16 | H16, then contact count and scan time.
    public static func parse(_ r: UnsafePointer<UInt8>, length: Int) -> (contacts: [Contact], count: Int)? {
        guard length >= 1 + slotsPerReport * bytesPerSlot + 1, UInt32(r[0]) == multiTouchReportID else { return nil }
        var out: [Contact] = []
        for i in 0..<slotsPerReport {
            let o = 1 + i * bytesPerSlot
            let flags = r[o]
            guard flags & 1 == 1 else { continue }
            func u16(_ k: Int) -> Int { Int(r[o + k]) | Int(r[o + k + 1]) << 8 }
            out.append(Contact(id: Int(r[o + 1]), x: u16(2), y: u16(4), width: u16(6), height: u16(8), confident: flags & 2 != 0))
        }
        return (out, Int(r[1 + slotsPerReport * bytesPerSlot]))
    }
}
