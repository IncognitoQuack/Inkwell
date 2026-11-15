import CoreGraphics
import Foundation

// MARK: - Input filtering

/// The 1€ filter (Casiez et al. 2012): heavy smoothing when the pen moves slowly (kills hand and
/// sensor jitter), almost none when it moves fast (no visible lag).
struct OneEuroFilter {
    var minCutoff: Double
    var beta: Double
    var derivativeCutoff: Double = 1.0
    private var last: Double?
    private var lastDerivative = 0.0
    private var lastTime: Double?

    init(minCutoff: Double, beta: Double) {
        self.minCutoff = minCutoff
        self.beta = beta
    }

    mutating func reset() {
        last = nil
        lastTime = nil
        lastDerivative = 0
    }

    mutating func filter(_ x: Double, time t: Double) -> Double {
        guard let prev = last, let prevT = lastTime else {
            last = x
            lastTime = t
            return x
        }
        // Repeated or out-of-order timestamps happen with coalesced/replayed events; treat as 1 ms.
        let dt = (t - prevT) > 1e-4 ? (t - prevT) : 1e-3
        let derivative = (x - prev) / dt
        let smoothedDerivative = lastDerivative + Self.alpha(derivativeCutoff, dt) * (derivative - lastDerivative)
        let cutoff = minCutoff + beta * abs(smoothedDerivative)
        let value = prev + Self.alpha(cutoff, dt) * (x - prev)
        last = value
        lastTime = t
        lastDerivative = smoothedDerivative
        return value
    }

    static func alpha(_ cutoff: Double, _ dt: Double) -> Double {
        let tau = 1 / (2 * Double.pi * cutoff)
        return 1 / (1 + tau / dt)
    }
}

/// 1€ filter for a 2D position. The cutoff follows the pen's 2D speed, so both axes are smoothed
/// equally. Filtering x and y separately lets whichever axis is momentarily slow lag behind, which
/// squares off circles and spirals.
struct OneEuroFilter2D {
    var minCutoff: Double
    var beta: Double
    var derivativeCutoff: Double = 1.0
    private var last: (x: Double, y: Double)?
    private var lastSpeed = 0.0
    private var lastTime: Double?

    init(minCutoff: Double, beta: Double) {
        self.minCutoff = minCutoff
        self.beta = beta
    }

    mutating func filter(x: Double, y: Double, time t: Double) -> (x: Double, y: Double) {
        guard let prev = last, let prevT = lastTime else {
            last = (x, y)
            lastTime = t
            return (x, y)
        }
        let dt = (t - prevT) > 1e-4 ? (t - prevT) : 1e-3
        let speed = hypot(x - prev.x, y - prev.y) / dt
        let smoothedSpeed = lastSpeed + OneEuroFilter.alpha(derivativeCutoff, dt) * (speed - lastSpeed)
        let a = OneEuroFilter.alpha(minCutoff + beta * smoothedSpeed, dt)
        let out = (x: prev.x + a * (x - prev.x), y: prev.y + a * (y - prev.y))
        last = out
        lastTime = t
        lastSpeed = smoothedSpeed
        return out
    }
}

// MARK: - Stroke builder

/// Turns raw pointer samples into clean stroke points. All tuning is done in screen pixels, so the
/// feel is identical at every zoom level.
final class StrokeBuilder {
    let kind: ToolKind
    let color: RGBA
    let width: Float
    /// Screen pixels per page point (view magnification).
    let scale: Double
    /// True for mouse/trackpad input: pressure is synthesised from speed instead of read from the device.
    let simulatePressure: Bool
    /// Exponent applied to device pressure: < 1 feels soft (light touch is enough), > 1 feels firm.
    let pressureGamma: Double
    /// Personal curve from the Pen Lab; when set it replaces `pressureGamma`.
    let curve: PressureCurve?

    private(set) var points: [InkPoint] = []
    private var filter: OneEuroFilter2D
    private var startTime: Double?
    private var smoothedPressure: Double?
    private var lastRaw: (x: Double, y: Double, t: Double)?

    init(kind: ToolKind, color: RGBA, width: Float, scale: Double, simulatePressure: Bool, pressureGamma: Double = 1,
         curve: PressureCurve? = nil, smoothing: Double = 2.0) {
        self.kind = kind
        self.color = color
        self.width = width
        self.scale = (scale.isFinite && scale > 0) ? scale : 1
        self.simulatePressure = simulatePressure
        self.pressureGamma = (pressureGamma.isFinite && pressureGamma > 0) ? pressureGamma.clamped(0.2, 5) : 1
        self.curve = curve?.isSane == true ? curve : nil
        // Tuned in screen pixels: ~1 Hz floor removes jitter, beta lets fast flicks through untouched.
        filter = OneEuroFilter2D(minCutoff: smoothing.isFinite ? smoothing.clamped(0.5, 6) : 2.0, beta: 0.02)
    }

    var isFull: Bool { points.count >= Stroke.maxPoints - 1 }

    /// Adds a sample. Returns true when a new point was appended (the caller should redraw).
    @discardableResult
    func add(x: Double, y: Double, pressure: Double, timestamp: Double) -> Bool {
        guard x.isFinite, y.isFinite, timestamp.isFinite, !isFull else { return false }
        let t0 = startTime ?? timestamp
        startTime = t0

        // Filter in screen space so smoothing strength doesn't change with zoom.
        let f = filter.filter(x: x * scale, y: y * scale, time: timestamp)
        let sx = f.x / scale, sy = f.y / scale

        var p: Double
        if !pressure.isFinite { p = 0.5 }
        else if let curve { p = curve.apply(pressure) }
        else { p = pow(pressure.clamped(0, 1), pressureGamma) }
        if simulatePressure {
            p = simulatedPressure(x: x, y: y, t: timestamp)
        } else if kind == .pen {
            // Light smoothing removes the stair-steps that cheaper tablets report.
            let prev = smoothedPressure ?? p
            p = prev + (p - prev) * 0.55
        }
        smoothedPressure = p
        lastRaw = (x, y, timestamp)

        let point = InkPoint(x: Float(sx), y: Float(sy), pressure: Float(p), time: Float(timestamp - t0))
        if let last = points.last {
            // Skip samples closer than ~0.4 screen px: they add cost and create micro-wobble.
            let dx = Double(point.x - last.x) * scale, dy = Double(point.y - last.y) * scale
            if dx * dx + dy * dy < 0.16 {
                points[points.count - 1].pressure = max(last.pressure, point.pressure)
                return false
            }
        }
        points.append(point)
        return true
    }

    /// Final sample on pen-up. The raw end position is appended so the filter's small lag never
    /// leaves the stroke short of where the pen actually lifted.
    func finish(x: Double, y: Double, pressure: Double, timestamp: Double) -> Stroke? {
        add(x: x, y: y, pressure: pressure, timestamp: timestamp)
        if x.isFinite, y.isFinite, let last = points.last, points.count > 1, !isFull {
            let dx = (x - Double(last.x)) * scale, dy = (y - Double(last.y)) * scale
            if dx * dx + dy * dy > 0.25 {
                points.append(InkPoint(x: Float(x), y: Float(y), pressure: last.pressure, time: last.time))
            }
        }
        return makeStroke()
    }

    func makeStroke() -> Stroke? {
        Stroke(kind: kind, color: color, width: width, points: points)
    }

    /// A short extrapolation of the pen's motion, drawn only on the live stroke to hide input latency.
    func predictedPoint(lookahead: Double = 0.012) -> InkPoint? {
        guard kind == .pen, points.count >= 3 else { return nil }
        let a = points[points.count - 3], b = points[points.count - 1]
        let dt = Double(b.time - a.time)
        guard dt > 0.002 else { return nil }
        var vx = Double(b.x - a.x) / dt, vy = Double(b.y - a.y) / dt
        // Never predict further than 12 screen px: a wrong guess must stay invisible.
        let maxStep = 12 / scale
        let step = (vx * vx + vy * vy).squareRoot() * lookahead
        if step > maxStep { vx *= maxStep / step; vy *= maxStep / step }
        return InkPoint(x: b.x + Float(vx * lookahead), y: b.y + Float(vy * lookahead), pressure: b.pressure, time: b.time)
    }

    private func simulatedPressure(x: Double, y: Double, t: Double) -> Double {
        guard let last = lastRaw else { return 0.62 }
        let dt = max(t - last.t, 1e-3)
        let speed = ((x - last.x) * (x - last.x) + (y - last.y) * (y - last.y)).squareRoot() * scale / dt // px/s
        // Faster strokes get thinner, like a real nib running dry.
        let target = (1.0 - speed / 2600).clamped(0.38, 0.95)
        let prev = smoothedPressure ?? target
        return prev + (target - prev) * 0.25
    }
}

// MARK: - Outline geometry

/// A sample on the smoothed centre line: position and nib radius.
struct NibSample {
    var x: CGFloat
    var y: CGFloat
    var r: CGFloat
}

enum InkGeometry {
    /// Nib radius for a point. The pen thins with light pressure; the highlighter is constant.
    static func radius(kind: ToolKind, width: Float, pressure: Float) -> CGFloat {
        let w = CGFloat(width)
        switch kind {
        case .highlighter:
            return w / 2
        case .pen:
            let p = CGFloat(pressure.clamped(0, 1))
            return w / 2 * (0.22 + 0.78 * pow(p, 0.7))
        }
    }

    /// Densifies points along a centripetal Catmull-Rom spline so sparse fast strokes still curve
    /// smoothly. `from` lets live rendering resume at a given segment.
    static func smoothSamples(_ pts: [InkPoint], kind: ToolKind, width: Float, fromSegment: Int = 0, toSegment: Int? = nil) -> [NibSample] {
        guard !pts.isEmpty else { return [] }
        func sample(_ p: InkPoint) -> NibSample {
            NibSample(x: CGFloat(p.x), y: CGFloat(p.y), r: radius(kind: kind, width: width, pressure: p.pressure))
        }
        if pts.count == 1 { return [sample(pts[0])] }

        let lastSegment = min(toSegment ?? (pts.count - 1), pts.count - 1)
        var out: [NibSample] = []
        if fromSegment == 0 { out.append(sample(pts[0])) }
        guard fromSegment < lastSegment else { return out }

        for i in fromSegment..<lastSegment {
            let p1 = pts[i], p2 = pts[i + 1]
            let p0 = i > 0 ? pts[i - 1] : reflect(p2, about: p1)
            let p3 = i + 2 < pts.count ? pts[i + 2] : reflect(p1, about: p2)
            let r1 = radius(kind: kind, width: width, pressure: p1.pressure)
            let r2 = radius(kind: kind, width: width, pressure: p2.pressure)
            let len = hypot(CGFloat(p2.x - p1.x), CGFloat(p2.y - p1.y))
            // Step at most half the thinner radius (and at most 2 pt) so edges stay perfectly round.
            let step = max(0.35, min(2, min(r1, r2) * 0.5))
            let n = Int((len / step).rounded(.up)).clamped(1, 64)
            for k in 1...n {
                let u = CGFloat(k) / CGFloat(n)
                let (x, y) = centripetal(p0, p1, p2, p3, u)
                out.append(NibSample(x: x, y: y, r: r1 + (r2 - r1) * u))
            }
        }
        return out
    }

    /// Appends the outline of a run of nib samples to `path`. Every segment is the convex hull of two
    /// circles with the same winding, so the non-zero fill unions them: no holes, spikes or seams at
    /// any turn.
    static func appendOutline(of samples: [NibSample], to path: CGMutablePath, startingAt start: Int = 0) {
        guard !samples.isEmpty else { return }
        if start == 0 { addCircle(samples[0], to: path) }
        var i = max(start, 1)
        while i < samples.count {
            addCapsule(samples[i - 1], samples[i], to: path)
            i += 1
        }
    }

    static func outlinePath(for stroke: Stroke) -> CGPath {
        let path = CGMutablePath()
        appendOutline(of: smoothSamples(stroke.points, kind: stroke.kind, width: stroke.width), to: path)
        return path
    }

    private static func addCircle(_ s: NibSample, to path: CGMutablePath) {
        let r = max(s.r, 0.05)
        path.move(to: CGPoint(x: s.x + r, y: s.y))
        path.addArc(center: CGPoint(x: s.x, y: s.y), radius: r, startAngle: 0, endAngle: 2 * .pi, clockwise: false)
        path.closeSubpath()
    }

    private static func addCapsule(_ a: NibSample, _ b: NibSample, to path: CGMutablePath) {
        let ra = max(a.r, 0.05), rb = max(b.r, 0.05)
        let dx = b.x - a.x, dy = b.y - a.y
        let d = hypot(dx, dy)
        // One circle inside the other: the hull is simply the larger circle.
        if d <= abs(ra - rb) + 1e-6 {
            addCircle(ra >= rb ? a : b, to: path)
            return
        }
        let theta = atan2(dy, dx)
        let phi = acos(((ra - rb) / d).clamped(-1, 1))
        let ca = CGPoint(x: a.x, y: a.y), cb = CGPoint(x: b.x, y: b.y)
        path.move(to: CGPoint(x: a.x + ra * cos(theta + phi), y: a.y + ra * sin(theta + phi)))
        path.addArc(center: ca, radius: ra, startAngle: theta + phi, endAngle: theta + 2 * .pi - phi, clockwise: false)
        path.addLine(to: CGPoint(x: b.x + rb * cos(theta - phi), y: b.y + rb * sin(theta - phi)))
        path.addArc(center: cb, radius: rb, startAngle: theta - phi, endAngle: theta + phi, clockwise: false)
        path.closeSubpath()
    }

    private static func reflect(_ p: InkPoint, about c: InkPoint) -> InkPoint {
        InkPoint(x: 2 * c.x - p.x, y: 2 * c.y - p.y, pressure: c.pressure, time: c.time)
    }

    /// Centripetal Catmull-Rom (alpha 0.5, Barry-Goldman form). Falls back to a straight line when
    /// knots coincide, which would otherwise divide by zero.
    private static func centripetal(_ p0: InkPoint, _ p1: InkPoint, _ p2: InkPoint, _ p3: InkPoint, _ u: CGFloat) -> (CGFloat, CGFloat) {
        let P0 = (CGFloat(p0.x), CGFloat(p0.y)), P1 = (CGFloat(p1.x), CGFloat(p1.y))
        let P2 = (CGFloat(p2.x), CGFloat(p2.y)), P3 = (CGFloat(p3.x), CGFloat(p3.y))
        func knot(_ a: (CGFloat, CGFloat), _ b: (CGFloat, CGFloat)) -> CGFloat { pow(hypot(b.0 - a.0, b.1 - a.1), 0.5) }
        let t0: CGFloat = 0
        let t1 = t0 + knot(P0, P1), t2 = t1 + knot(P1, P2), t3 = t2 + knot(P2, P3)
        let eps: CGFloat = 1e-4
        guard t1 - t0 > eps, t2 - t1 > eps, t3 - t2 > eps else {
            return (P1.0 + (P2.0 - P1.0) * u, P1.1 + (P2.1 - P1.1) * u)
        }
        let t = t1 + (t2 - t1) * u
        func lerp(_ a: (CGFloat, CGFloat), _ b: (CGFloat, CGFloat), _ ta: CGFloat, _ tb: CGFloat) -> (CGFloat, CGFloat) {
            let wa = (tb - t) / (tb - ta), wb = (t - ta) / (tb - ta)
            return (a.0 * wa + b.0 * wb, a.1 * wa + b.1 * wb)
        }
        let A1 = lerp(P0, P1, t0, t1), A2 = lerp(P1, P2, t1, t2), A3 = lerp(P2, P3, t2, t3)
        let B1 = lerp(A1, A2, t0, t2), B2 = lerp(A2, A3, t1, t3)
        let C = lerp(B1, B2, t1, t2)
        guard C.0.isFinite, C.1.isFinite else { return (P1.0 + (P2.0 - P1.0) * u, P1.1 + (P2.1 - P1.1) * u) }
        return C
    }
}

// MARK: - Hit testing

enum HitTest {
    /// True when an eraser swept from `a` to `b` with radius `r` touches the stroke.
    /// Testing the whole sweep (not just the end position) means fast eraser moves never skip strokes.
    static func eraser(from a: CGPoint, to b: CGPoint, radius r: CGFloat, hits stroke: Stroke) -> Bool {
        let sweep = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y)).insetBy(dx: -r, dy: -r)
        guard sweep.intersects(stroke.bounds) else { return false }
        let pts = stroke.points
        if pts.count == 1 {
            let p = pts[0]
            return distancePointSegment(p.cgPoint, a, b) <= r + InkGeometry.radius(kind: stroke.kind, width: stroke.width, pressure: p.pressure)
        }
        for i in 1..<pts.count {
            let p = pts[i - 1], q = pts[i]
            let nib = InkGeometry.radius(kind: stroke.kind, width: stroke.width, pressure: max(p.pressure, q.pressure))
            if distanceSegmentSegment(a, b, p.cgPoint, q.cgPoint) <= r + nib { return true }
        }
        return false
    }

    /// Precise erasing: cuts away the parts of `stroke` under an eraser swept from `a` to `b`.
    /// Returns nil when the stroke is untouched, otherwise the surviving pieces (empty = fully erased).
    /// The first piece keeps the original id so caches and selection stay stable.
    static func eraseSplit(_ stroke: Stroke, from a: CGPoint, to b: CGPoint, radius r: CGFloat) -> [Stroke]? {
        guard eraser(from: a, to: b, radius: r, hits: stroke) else { return nil }
        let pts = stroke.points
        func nib(_ p: InkPoint) -> CGFloat { InkGeometry.radius(kind: stroke.kind, width: stroke.width, pressure: p.pressure) }
        // A point is erased when the eraser reaches its centre line (plus half the nib, so no slivers remain).
        let erased = pts.map { distancePointSegment($0.cgPoint, a, b) <= r + nib($0) * 0.5 }
        var pieces: [[InkPoint]] = []
        var run: [InkPoint] = []
        for i in pts.indices {
            if erased[i] {
                if !run.isEmpty { pieces.append(run); run = [] }
                continue
            }
            // A fast sweep can pass between two kept samples: cut the link between them too.
            if i > 0, !erased[i - 1], !run.isEmpty,
               distanceSegmentSegment(pts[i - 1].cgPoint, pts[i].cgPoint, a, b) <= r {
                pieces.append(run)
                run = []
            }
            run.append(pts[i])
        }
        if !run.isEmpty { pieces.append(run) }
        // Single leftover points would render as stray dots; drop them (unless the stroke was a dot).
        if pts.count > 1 { pieces.removeAll { $0.count < 2 } }
        if pieces.count == 1, pieces[0].count == pts.count { return nil } // grazed the padding only
        return pieces.enumerated().compactMap { i, run in
            Stroke(id: i == 0 ? stroke.id : UUID(), kind: stroke.kind, color: stroke.color, width: stroke.width, points: run)
        }
    }

    /// A stroke counts as lassoed when at least 60% of its points fall inside the polygon,
    /// so grazing the edge of a stroke doesn't grab it.
    static func lasso(_ polygon: [CGPoint], contains stroke: Stroke) -> Bool {
        guard polygon.count >= 3 else { return false }
        let box = polygon.reduce(CGRect.null) { $0.union(CGRect(origin: $1, size: .zero)) }
        guard box.intersects(stroke.bounds) else { return false }
        let pts = stroke.points
        let stride = max(1, pts.count / 400) // sample long strokes
        var inside = 0, total = 0
        var i = 0
        while i < pts.count {
            total += 1
            if pointInPolygon(pts[i].cgPoint, polygon) { inside += 1 }
            i += stride
        }
        return Double(inside) >= Double(total) * 0.6
    }

    static func pointInPolygon(_ p: CGPoint, _ poly: [CGPoint]) -> Bool {
        var inside = false
        var j = poly.count - 1
        for i in 0..<poly.count {
            let a = poly[i], b = poly[j]
            if (a.y > p.y) != (b.y > p.y), p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x {
                inside.toggle()
            }
            j = i
        }
        return inside
    }

    static func distancePointSegment(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let abx = b.x - a.x, aby = b.y - a.y
        let len2 = abx * abx + aby * aby
        guard len2 > 1e-12 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = (((p.x - a.x) * abx + (p.y - a.y) * aby) / len2).clamped(0, 1)
        return hypot(p.x - (a.x + t * abx), p.y - (a.y + t * aby))
    }

    static func distanceSegmentSegment(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint, _ d: CGPoint) -> CGFloat {
        if segmentsIntersect(a, b, c, d) { return 0 }
        return min(distancePointSegment(a, c, d), distancePointSegment(b, c, d),
                   distancePointSegment(c, a, b), distancePointSegment(d, a, b))
    }

    private static func segmentsIntersect(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint, _ d: CGPoint) -> Bool {
        func cross(_ o: CGPoint, _ p: CGPoint, _ q: CGPoint) -> CGFloat { (p.x - o.x) * (q.y - o.y) - (p.y - o.y) * (q.x - o.x) }
        let d1 = cross(c, d, a), d2 = cross(c, d, b), d3 = cross(a, b, c), d4 = cross(a, b, d)
        return ((d1 > 0 && d2 < 0) || (d1 < 0 && d2 > 0)) && ((d3 > 0 && d4 < 0) || (d3 < 0 && d4 > 0))
    }
}
