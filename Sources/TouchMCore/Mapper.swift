import CoreGraphics

public struct Mapper {
    public var settings: Settings
    public init(_ s: Settings) { settings = s }

    public var display: CGDirectDisplayID { settings.targetDisplay ?? CGMainDisplayID() }

    /// Raw panel coordinates -> global display point (top-left origin, points).
    public func map(x rx: Int, y ry: Int) -> CGPoint {
        var nx = Double(rx) / TouchMProtocol.rawMax
        var ny = Double(ry) / TouchMProtocol.rawMax
        if let cal = settings.calibration {
            (nx, ny) = cal.apply(nx, ny)
            // The calibration maps the panel onto the screen as it was turned when calibrating; follow later rotations.
            if settings.autoRotate || settings.rotationOverride != nil {
                let now = settings.rotationOverride ?? Int(CGDisplayRotation(display))
                switch ((now - (settings.calibrationRotation ?? now)) % 360 + 360) % 360 {
                case 90:  (nx, ny) = (ny, 1 - nx)
                case 180: (nx, ny) = (1 - nx, 1 - ny)
                case 270: (nx, ny) = (1 - ny, nx)
                default: break
                }
            }
        } else {
            if settings.swapXY { swap(&nx, &ny) }
            var fx = settings.flipX, fy = settings.flipY
            if settings.autoRotate || settings.rotationOverride != nil {
                switch settings.rotationOverride ?? Int(CGDisplayRotation(display)) {
                case 180: fx.toggle(); fy.toggle()
                case 90:  swap(&nx, &ny); fy.toggle()
                case 270: swap(&nx, &ny); fx.toggle()
                default: break
                }
            }
            if fx { nx = 1 - nx }
            if fy { ny = 1 - ny }
        }
        let b = CGDisplayBounds(display)
        nx = min(max(nx, 0), 1); ny = min(max(ny, 0), 1)
        return CGPoint(x: b.minX + nx * (b.width - 1), y: b.minY + ny * (b.height - 1))
    }

    /// Calibration targets as fractions of the screen (4, 9 or 25): 4 = corners, 9 = 3x3, 25 = 5x5.
    public static func targets(_ n: Int) -> [(Double, Double)] {
        let side = n >= 25 ? 5 : (n >= 16 ? 4 : (n >= 9 ? 3 : 2))
        let lo = 0.1, hi = 0.9
        let axis = (0..<side).map { lo + (hi - lo) * Double($0) / Double(side - 1) }
        return axis.flatMap { y in axis.map { x in (x, y) } }
    }

    /// RMS residual of a fit, as a fraction of the screen diagonal-free unit square.
    public static func rms(_ a: Affine, _ pairs: [(raw: (Double, Double), target: (Double, Double))]) -> Double {
        guard !pairs.isEmpty else { return 0 }
        let e = pairs.map { p -> Double in let o = a.apply(p.raw.0, p.raw.1); return (o.0 - p.target.0) * (o.0 - p.target.0) + (o.1 - p.target.1) * (o.1 - p.target.1) }
        return (e.reduce(0, +) / Double(e.count)).squareRoot()
    }

    /// Least-squares affine fit from 4+ (raw, target) pairs, all normalised 0...1.
    public static func fit(_ pairs: [(raw: (Double, Double), target: (Double, Double))]) -> Affine? {
        guard pairs.count >= 3 else { return nil }
        func solve(_ t: (Int) -> Double) -> (Double, Double, Double)? {
            var m = [[Double]](repeating: [Double](repeating: 0, count: 4), count: 3)
            for (i, p) in pairs.enumerated() {
                let row = [p.raw.0, p.raw.1, 1.0], v = t(i)
                for r in 0..<3 { for c in 0..<3 { m[r][c] += row[r] * row[c] }; m[r][3] += row[r] * v }
            }
            for i in 0..<3 {                       // Gaussian elimination
                guard let piv = (i..<3).max(by: { abs(m[$0][i]) < abs(m[$1][i]) }), abs(m[piv][i]) > 1e-12 else { return nil }
                m.swapAt(i, piv)
                for r in 0..<3 where r != i { let k = m[r][i] / m[i][i]; for c in i..<4 { m[r][c] -= k * m[i][c] } }
            }
            return (m[0][3] / m[0][0], m[1][3] / m[1][1], m[2][3] / m[2][2])
        }
        guard let X = solve({ pairs[$0].target.0 }), let Y = solve({ pairs[$0].target.1 }) else { return nil }
        var a = Affine(); a.a = X.0; a.b = X.1; a.c = X.2; a.d = Y.0; a.e = Y.1; a.f = Y.2
        return a
    }
}
