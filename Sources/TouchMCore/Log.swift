import Foundation

/// Small diagnostic log: ~/Library/Application Support/TouchM/debug.log (truncated at 256 KB).
public enum TMLog {
    public static var enabled = true
    private static let url = Store.dir.appendingPathComponent("debug.log")
    private static let q = DispatchQueue(label: "touchm.log")
    public static func write(_ s: String) {
        guard enabled else { return }
        q.async {
            let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"
            let line = "\(f.string(from: Date())) \(s)\n"
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile(); h.write(Data(line.utf8))
                if h.offsetInFile > 256_000 { h.truncateFile(atOffset: 0) }
                try? h.close()
            } else { try? Data(line.utf8).write(to: url) }
        }
    }
}

extension Timer {
    /// A timer that also fires while AppKit tracks events in a nested loop (list scrolling, menus, drags).
    /// Touch input must keep flowing then, or the touch screen stops responding.
    @discardableResult
    public static func common(withTimeInterval i: TimeInterval, repeats: Bool, block: @escaping @Sendable (Timer) -> Void) -> Timer {
        let t = Timer(timeInterval: i, repeats: repeats, block: block)
        RunLoop.main.add(t, forMode: .common)
        return t
    }
}
