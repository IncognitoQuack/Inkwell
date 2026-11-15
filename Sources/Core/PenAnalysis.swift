import CoreGraphics
import Foundation

/// One raw pen event captured by the Pen Lab, unfiltered.
struct PenSample: Codable, Equatable {
    var t: Double            // event timestamp (s)
    var x: Double            // board coordinates (points)
    var y: Double
    var pressure: Double     // 0…1 as reported
    var tiltX: Double
    var tiltY: Double
    var rotation: Double
    var phase: Phase
    var button: Int          // 0 tip, 1 lower (right), 2 upper (other)
    var isTablet: Bool       // NSEvent subtype was tablet point

    enum Phase: String, Codable { case down, drag, up, hover }
}

/// A personal pressure curve: raw pressure is normalised between the user's own floor and ceiling,
/// then shaped by gamma so their natural "normal" pressure lands mid-range.
struct PressureCurve: Codable, Equatable {
    var floor: Double = 0
    var ceiling: Double = 1
    var gamma: Double = 1

    static let identity = PressureCurve()

    func apply(_ p: Double) -> Double {
        guard p.isFinite else { return 0.5 }
        let span = max(ceiling - floor, 0.05)
        let n = ((p - floor) / span).clamped(0, 1)
        return pow(n, gamma.clamped(0.2, 5))
    }

    var isSane: Bool {
        floor.isFinite && ceiling.isFinite && gamma.isFinite && floor >= 0 && ceiling <= 1 && ceiling - floor >= 0.05 && gamma >= 0.2 && gamma <= 5
    }
}

enum PenAnalysis {
    /// Contact strokes: runs from down to up (tip only).
    static func strokes(_ samples: [PenSample]) -> [[PenSample]] {
        var out: [[PenSample]] = [], cur: [PenSample] = []
        for s in samples where s.button == 0 && s.phase != .hover {
            if s.phase == .down { if !cur.isEmpty { out.append(cur) }; cur = [s] }
            else { cur.append(s); if s.phase == .up { out.append(cur); cur = [] } }
        }
        if !cur.isEmpty { out.append(cur) }
        return out.filter { !$0.isEmpty }
    }

    /// Median sample rate while touching, in Hz (robust to pauses and duplicates).
    static func reportRate(_ samples: [PenSample]) -> Double? {
        var rates: [Double] = []
        for st in strokes(samples) {
            for (a, b) in zip(st, st.dropFirst()) where b.t - a.t > 0.0005 && b.t - a.t < 0.1 { rates.append(1 / (b.t - a.t)) }
        }
        return median(rates)
    }

    struct PressureStats: Codable, Equatable {
        var min: Double
        var max: Double
        var distinctLevels: Int
        /// Smallest non-zero difference between reported values (≈ 1/levels of the device).
        var step: Double?
    }

    static func pressureStats(_ samples: [PenSample]) -> PressureStats? {
        let ps = samples.filter { $0.phase == .drag && $0.button == 0 && $0.pressure > 0 }.map(\.pressure)
        guard let lo = ps.min(), let hi = ps.max() else { return nil }
        let uniq = Set(ps.map { ($0 * 65_536).rounded() }).sorted()
        let diffs = zip(uniq, uniq.dropFirst()).map { ($1 - $0) / 65_536 }.filter { $0 > 0 }
        return PressureStats(min: lo, max: hi, distinctLevels: uniq.count, step: diffs.min())
    }

    /// Median pressure of the middle 60% of each stroke (ignores the ramp in and out).
    static func strokePressures(_ samples: [PenSample]) -> [Double] {
        strokes(samples).compactMap { st in
            let ps = st.filter { $0.phase == .drag }.map(\.pressure)
            guard ps.count >= 5 else { return nil }
            let a = ps.count / 5, b = ps.count - ps.count / 5
            return median(Array(ps[a..<max(a + 1, b)]))
        }
    }

    /// RMS distance of raw points from their best-fit line, per stroke (points).
    static func lineJitter(_ samples: [PenSample]) -> Double? {
        let errs = strokes(samples).compactMap { st -> Double? in
            let pts = st.map { CGPoint(x: $0.x, y: $0.y) }
            guard pts.count >= 10 else { return nil }
            // Total least squares via the covariance's principal axis.
            let n = Double(pts.count)
            let mx = pts.map { Double($0.x) }.reduce(0, +) / n, my = pts.map { Double($0.y) }.reduce(0, +) / n
            var sxx = 0.0, syy = 0.0, sxy = 0.0
            for p in pts { let dx = Double(p.x) - mx, dy = Double(p.y) - my; sxx += dx * dx; syy += dy * dy; sxy += dx * dy }
            let theta = 0.5 * atan2(2 * sxy, sxx - syy)
            let nx = -sin(theta), ny = cos(theta)
            let sq = pts.map { pow((Double($0.x) - mx) * nx + (Double($0.y) - my) * ny, 2) }.reduce(0, +)
            return (sq / n).squareRoot()
        }
        return median(errs)
    }

    /// RMS radial error from a least-squares circle (Kåsa fit), per stroke (points).
    static func circleJitter(_ samples: [PenSample]) -> Double? {
        let errs = strokes(samples).compactMap { st -> Double? in
            guard st.count >= 12 else { return nil }
            guard let (cx, cy, r) = fitCircle(st.map { ($0.x, $0.y) }), r > 5 else { return nil }
            let sq = st.map { pow(hypot($0.x - cx, $0.y - cy) - r, 2) }.reduce(0, +)
            return (sq / Double(st.count)).squareRoot()
        }
        return median(errs)
    }

    static func fitCircle(_ p: [(Double, Double)]) -> (Double, Double, Double)? {
        // Solve x² + y² + D x + E y + F = 0 by least squares (3×3 normal equations).
        var a = [[Double]](repeating: [0, 0, 0], count: 3), b = [0.0, 0.0, 0.0]
        for (x, y) in p {
            let row = [x, y, 1.0], z = -(x * x + y * y)
            for i in 0..<3 { for j in 0..<3 { a[i][j] += row[i] * row[j] }; b[i] += row[i] * z }
        }
        guard let s = solve3(a, b) else { return nil }
        let cx = -s[0] / 2, cy = -s[1] / 2, r2 = cx * cx + cy * cy - s[2]
        return r2 > 0 ? (cx, cy, r2.squareRoot()) : nil
    }

    private static func solve3(_ m: [[Double]], _ v: [Double]) -> [Double]? {
        var a = m, b = v
        for c in 0..<3 {
            guard let p = (c..<3).max(by: { abs(a[$0][c]) < abs(a[$1][c]) }), abs(a[p][c]) > 1e-12 else { return nil }
            a.swapAt(c, p); b.swapAt(c, p)
            for r in 0..<3 where r != c {
                let f = a[r][c] / a[c][c]
                for k in c..<3 { a[r][k] -= f * a[c][k] }
                b[r] -= f * b[c]
            }
        }
        return (0..<3).map { b[$0] / a[$0][$0] }
    }

    /// Peak speed while touching (points/s), smoothed over 3 samples.
    static func peakSpeed(_ samples: [PenSample]) -> Double? {
        var speeds: [Double] = []
        for st in strokes(samples) where st.count > 3 {
            for i in 3..<st.count {
                let a = st[i - 3], b = st[i]
                let dt = b.t - a.t
                if dt > 0.002 { speeds.append(hypot(b.x - a.x, b.y - a.y) / dt) }
            }
        }
        return speeds.max()
    }

    static func median(_ v: [Double]) -> Double? {
        let s = v.filter(\.isFinite).sorted()
        guard !s.isEmpty else { return nil }
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    static func percentile(_ v: [Double], _ q: Double) -> Double? {
        let s = v.filter(\.isFinite).sorted()
        guard !s.isEmpty else { return nil }
        return s[min(s.count - 1, max(0, Int((Double(s.count - 1) * q).rounded())))]
    }

    struct Recommendation: Codable, Equatable {
        var curve: PressureCurve
        /// 1€ filter minimum cutoff (Hz, screen space): lower = smoother.
        var smoothing: Double
        var notes: [String]
    }

    /// Builds personal settings from the light / normal / firm exercises and the jitter measurements.
    /// Falls back to safe defaults for anything that wasn't measured.
    static func recommend(light: [Double], normal: [Double], firm: [Double], allContact: [Double],
                          jitter: Double?, reportRate: Double?) -> Recommendation {
        var notes: [String] = []
        // Floor: just below the user's lightest deliberate pressure (dead zone removed, but taps still register).
        let floor = ((percentile(light, 0.1) ?? percentile(allContact, 0.02) ?? 0) * 0.6).clamped(0, 0.3)
        // Ceiling: their firm pressure, so full width doesn't require crushing the nib.
        let ceiling = max(floor + 0.15, (percentile(firm, 0.9) ?? percentile(allContact, 0.98) ?? 1).clamped(0.3, 1))
        var curve = PressureCurve(floor: floor, ceiling: ceiling, gamma: 1)
        if let n = median(normal) {
            // Choose gamma so that their normal pressure maps to 0.55 of full width.
            let x = ((n - floor) / (ceiling - floor)).clamped(0.05, 0.95)
            curve.gamma = (log(0.55) / log(x)).clamped(0.35, 2.8)
            notes.append(String(format: "Your normal pressure is %.0f%% of the pen's range; mapped to 55%% width.", n * 100))
        } else {
            notes.append("Normal pressure wasn't measured; gamma left at 1.")
        }
        notes.append(String(format: "Pressure range used: %.0f%%–%.0f%%.", floor * 100, ceiling * 100))
        var smoothing = 2.0
        if let j = jitter {
            smoothing = j < 0.25 ? 2.6 : j < 0.6 ? 2.0 : j < 1.2 ? 1.5 : 1.1
            notes.append(String(format: "Hand/sensor jitter %.2f pt → smoothing %.1f.", j, smoothing))
        }
        if let r = reportRate {
            notes.append(String(format: "Report rate ≈ %.0f samples/s%@", r, r < 120 ? " (low: check USB connection or driver)." : "."))
        }
        return Recommendation(curve: curve, smoothing: smoothing, notes: notes)
    }
}
