import AppKit

// Renders the TouchM icon (white hand on a blue gradient) into an .iconset folder.
let out = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
func render(_ px: Int) -> Data {
    let img = NSImage(size: NSSize(width: px, height: px), flipped: false) { r in
        let path = NSBezierPath(roundedRect: r.insetBy(dx: r.width * 0.06, dy: r.height * 0.06), xRadius: r.width * 0.22, yRadius: r.width * 0.22)
        NSGradient(colors: [NSColor(calibratedRed: 0.20, green: 0.55, blue: 1.0, alpha: 1), NSColor(calibratedRed: 0.10, green: 0.20, blue: 0.75, alpha: 1)])!
            .draw(in: path, angle: -90)
        let cfg = NSImage.SymbolConfiguration(pointSize: r.width * 0.5, weight: .semibold).applying(.init(paletteColors: [.white]))
        if let sym = NSImage(systemSymbolName: "hand.point.up.left.fill", accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
            let s = sym.size
            sym.draw(in: NSRect(x: (r.width - s.width) / 2, y: (r.height - s.height) / 2, width: s.width, height: s.height))
        }
        return true
    }
    let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
    return rep.representation(using: .png, properties: [:])!
}
for (name, px) in [("16", 16), ("16@2x", 32), ("32", 32), ("32@2x", 64), ("128", 128), ("128@2x", 256), ("256", 256), ("256@2x", 512), ("512", 512), ("512@2x", 1024)] {
    try! render(px).write(to: URL(fileURLWithPath: "\(out)/icon_\(name.replacingOccurrences(of: "@2x", with: ""))\(name.contains("@2x") ? "@2x" : "").png".replacingOccurrences(of: "icon_\(name.replacingOccurrences(of: "@2x", with: ""))", with: "icon_\(name.replacingOccurrences(of: "@2x", with: ""))x\(name.replacingOccurrences(of: "@2x", with: ""))")))
}
