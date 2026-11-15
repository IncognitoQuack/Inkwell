import CoreGraphics
import Foundation

/// Turns a held, roughly drawn stroke into a clean shape.
enum ShapeRecognizer {
    enum Shape: Equatable {
        case line, rectangle, ellipse, triangle, arrow
    }

    struct Result {
        var shape: Shape
        /// Outline points of the clean shape, in drawing order (closed shapes repeat the first point).
        var points: [CGPoint]
    }

    /// Returns nil when the stroke isn't confidently any shape, so freehand drawing is never "corrected"
    /// into something the user didn't mean.
    static func recognize(_ pts: [CGPoint]) -> Result? {
        let p = pts.filter { $0.x.isFinite && $0.y.isFinite }
        guard p.count >= 2 else { return nil }
        let length = pathLength(p)
        let box = p.reduce(CGRect.null) { $0.union(CGRect(origin: $1, size: .zero)) }
        let diag = hypot(box.width, box.height)
        guard length > 12, diag > 8 else { return nil }

        // Straight line: every point close to the chord.
        let a = p.first!, b = p.last!
        let chord = hypot(b.x - a.x, b.y - a.y)
        if chord > 0.6 * length {
            let dev = p.map { HitTest.distancePointSegment($0, a, b) }.max() ?? 0
            if dev < max(2.5, chord * 0.07) {
                return Result(shape: .line, points: [a, b])
            }
        }

        // Arrow drawn in one stroke: a shaft to the tip, then the head's barbs doubling back.
        if let arrow = recognizeArrow(p, diag: diag) { return arrow }

        // Closed shapes must end near where they started.
        guard hypot(b.x - a.x, b.y - a.y) < max(14, length * 0.18), box.width > 10, box.height > 10 else { return nil }
        var closed = p
        closed.append(a)

        // Corners via Douglas-Peucker on the closed path.
        let simplified = rdp(closed, epsilon: diag * 0.07)
        let corners = dedupeCorners(Array(simplified.dropLast()), minDistance: diag * 0.12)
        if corners.count == 3, polygonFitError(p, corners) < diag * 0.06 {
            return Result(shape: .triangle, points: corners + [corners[0]])
        }
        if corners.count == 4, polygonFitError(p, corners) < diag * 0.06 {
            // Hand-drawn rectangles are nearly always meant axis-aligned.
            let r = CGRect(x: box.minX, y: box.minY, width: box.width, height: box.height)
            let rect = [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)]
            if rectangularity(corners) < 0.3 { return Result(shape: .rectangle, points: rect + [rect[0]]) }
        }

        // Ellipse: radial error against the bounding-box ellipse.
        let cx = box.midX, cy = box.midY, rx = box.width / 2, ry = box.height / 2
        let err = p.map { abs(hypot(($0.x - cx) / rx, ($0.y - cy) / ry) - 1) }.reduce(0, +) / CGFloat(p.count)
        if err < 0.11 {
            let n = 96
            let pts = (0...n).map { i -> CGPoint in
                let t = CGFloat(i) / CGFloat(n) * 2 * .pi
                return CGPoint(x: cx + rx * cos(t), y: cy + ry * sin(t))
            }
            return Result(shape: .ellipse, points: pts)
        }
        return nil
    }

    /// Finds "shaft then head" strokes: the tip is the point farthest from the start; what follows it
    /// must be short (the head) and point back towards the start on both sides of the shaft.
    private static func recognizeArrow(_ p: [CGPoint], diag: CGFloat) -> Result? {
        let a = p[0]
        // The pen passes the tip twice (end of shaft, and between the barbs): take the first arrival.
        let dist = p.map { hypot($0.x - a.x, $0.y - a.y) }
        let far = dist.max() ?? 0
        guard let tipIndex = dist.firstIndex(where: { $0 >= far * 0.97 }), tipIndex > 2, tipIndex < p.count - 2 else { return nil }
        let tip = p[tipIndex]
        let shaftLen = hypot(tip.x - a.x, tip.y - a.y)
        guard shaftLen > 30 else { return nil }
        // The shaft must be straight.
        let shaft = Array(p[0...tipIndex])
        guard (shaft.map { HitTest.distancePointSegment($0, a, tip) }.max() ?? 0) < max(4, shaftLen * 0.08) else { return nil }
        let head = Array(p[tipIndex...])
        let headLen = pathLength(head)
        guard headLen > shaftLen * 0.12, headLen < shaftLen * 1.4 else { return nil }
        // Every head point stays near the tip and behind it.
        let dir = CGVector(dx: (tip.x - a.x) / shaftLen, dy: (tip.y - a.y) / shaftLen)
        var left = false, right = false
        for q in head {
            let vx = q.x - tip.x, vy = q.y - tip.y
            let along = vx * dir.dx + vy * dir.dy          // < 0 means behind the tip
            let side = vx * -dir.dy + vy * dir.dx           // signed distance from the shaft line
            guard hypot(vx, vy) < shaftLen * 0.6, along < max(4, shaftLen * 0.06) else { return nil }
            if hypot(vx, vy) > shaftLen * 0.06 {
                if side > shaftLen * 0.04 { left = true }
                if side < -shaftLen * 0.04 { right = true }
            }
        }
        guard left && right else { return nil }
        // Clean, symmetric head: 28° barbs, 18% of the shaft (8…40 pt).
        let barb = (shaftLen * 0.18).clamped(8, 40)
        let ang: CGFloat = 28 * .pi / 180
        func rot(_ t: CGFloat) -> CGPoint {
            let bx = -dir.dx, by = -dir.dy
            return CGPoint(x: tip.x + barb * (bx * cos(t) - by * sin(t)), y: tip.y + barb * (bx * sin(t) + by * cos(t)))
        }
        return Result(shape: .arrow, points: [a, tip, rot(ang), tip, rot(-ang)])
    }

    static func pathLength(_ p: [CGPoint]) -> CGFloat {
        zip(p, p.dropFirst()).reduce(0) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) }
    }

    /// Ramer–Douglas–Peucker simplification.
    static func rdp(_ p: [CGPoint], epsilon: CGFloat) -> [CGPoint] {
        guard p.count > 2 else { return p }
        var keep = [Bool](repeating: false, count: p.count)
        keep[0] = true
        keep[p.count - 1] = true
        var stack = [(0, p.count - 1)]
        while let (s, e) = stack.popLast() {
            guard e > s + 1 else { continue }
            var best = 0, dmax: CGFloat = 0
            for i in (s + 1)..<e {
                let d = HitTest.distancePointSegment(p[i], p[s], p[e])
                if d > dmax { dmax = d; best = i }
            }
            if dmax > epsilon {
                keep[best] = true
                stack.append((s, best))
                stack.append((best, e))
            }
        }
        return p.indices.filter { keep[$0] }.map { p[$0] }
    }

    private static func dedupeCorners(_ c: [CGPoint], minDistance: CGFloat) -> [CGPoint] {
        var out: [CGPoint] = []
        for q in c where !out.contains(where: { hypot($0.x - q.x, $0.y - q.y) < minDistance }) { out.append(q) }
        return out
    }

    /// Mean distance from the drawn points to the polygon's edges.
    private static func polygonFitError(_ p: [CGPoint], _ poly: [CGPoint]) -> CGFloat {
        let edges = poly.indices.map { (poly[$0], poly[($0 + 1) % poly.count]) }
        let total = p.reduce(CGFloat(0)) { acc, q in acc + (edges.map { HitTest.distancePointSegment(q, $0.0, $0.1) }.min() ?? 0) }
        return total / CGFloat(p.count)
    }

    /// 0 for a perfect rectangle: mean |cos| of the corner angles.
    private static func rectangularity(_ c: [CGPoint]) -> CGFloat {
        var sum: CGFloat = 0
        for i in c.indices {
            let a = c[(i + c.count - 1) % c.count], b = c[i], d = c[(i + 1) % c.count]
            let v1 = CGVector(dx: a.x - b.x, dy: a.y - b.y), v2 = CGVector(dx: d.x - b.x, dy: d.y - b.y)
            let n = hypot(v1.dx, v1.dy) * hypot(v2.dx, v2.dy)
            if n > 0 { sum += abs((v1.dx * v2.dx + v1.dy * v2.dy) / n) }
        }
        return sum / CGFloat(c.count)
    }

    /// Builds a stroke for a recognised shape, keeping the drawn stroke's style and average pressure.
    static func stroke(for result: Result, like original: Stroke) -> Stroke? {
        let avg = original.points.isEmpty ? 0.6 : original.points.map(\.pressure).reduce(0, +) / Float(original.points.count)
        // Densify long edges so precise erasing and hit-testing behave like on hand-drawn ink.
        var pts: [InkPoint] = []
        for (a, b) in zip(result.points, result.points.dropFirst()) {
            let n = max(1, Int(hypot(b.x - a.x, b.y - a.y) / 6))
            for k in 0..<n {
                let u = CGFloat(k) / CGFloat(n)
                pts.append(InkPoint(x: Float(a.x + (b.x - a.x) * u), y: Float(a.y + (b.y - a.y) * u), pressure: avg, time: 0))
            }
        }
        if let l = result.points.last { pts.append(InkPoint(x: Float(l.x), y: Float(l.y), pressure: avg, time: 0)) }
        return Stroke(kind: original.kind, color: original.color, width: original.width, points: pts)
    }
}

/// Detects a "scratch-out" scribble drawn over ink, the gesture for deleting it.
enum ScribbleDetector {
    /// True when the stroke zig-zags back and forth densely: long path in a small box with many reversals.
    static func isScribble(_ stroke: Stroke) -> Bool {
        let p = stroke.points.map(\.cgPoint)
        guard p.count >= 16 else { return false }
        let box = stroke.bounds.insetBy(dx: CGFloat(stroke.width), dy: CGFloat(stroke.width))
        let diag = hypot(box.width, box.height)
        guard diag > 10 else { return false }
        let length = ShapeRecognizer.pathLength(p)
        guard length / diag > 3.2 else { return false }
        // Count reversals along the box's longer axis, ignoring wiggles smaller than 15% of it.
        let horizontal = box.width >= box.height
        let span = horizontal ? box.width : box.height
        var reversals = 0, dir: CGFloat = 0, anchor = horizontal ? p[0].x : p[0].y
        for q in p {
            let v = horizontal ? q.x : q.y
            let d = v - anchor
            guard abs(d) > span * 0.15 else { continue }
            let s: CGFloat = d > 0 ? 1 : -1
            if dir != 0 && s != dir { reversals += 1 }
            dir = s
            anchor = v
        }
        return reversals >= 4
    }

    /// Strokes the scribble deletes: ones it actually crosses and that mostly sit inside its area,
    /// so a long line merely crossed by the scribble survives.
    static func targets(of scribble: Stroke, in strokes: [Stroke]) -> Set<UUID> {
        let area = scribble.bounds
        let sp = scribble.points.map(\.cgPoint)
        var out = Set<UUID>()
        for s in strokes where s.id != scribble.id && s.bounds.intersects(area) {
            let inter = s.bounds.intersection(area)
            guard inter.width * inter.height >= 0.5 * max(1, s.bounds.width * s.bounds.height) else { continue }
            let crosses = zip(sp, sp.dropFirst()).contains { a, b in
                HitTest.eraser(from: a, to: b, radius: CGFloat(scribble.width) / 2, hits: s)
            }
            if crosses { out.insert(s.id) }
        }
        return out
    }
}

/// Finds a handwritten "=" and the sum written before it, for answers that appear as you write.
enum EqualsDetector {
    /// Two short, flat, stacked strokes of similar length that overlap horizontally.
    static func isEqualsSign(_ a: Stroke, _ b: Stroke) -> Bool {
        func flat(_ s: Stroke) -> (CGRect, Bool) {
            let w = s.bounds.width - CGFloat(s.width), h = s.bounds.height - CGFloat(s.width)
            let pts = s.points.map(\.cgPoint)
            guard let f = pts.first, let l = pts.last else { return (s.bounds, false) }
            let straight = (pts.map { HitTest.distancePointSegment($0, f, l) }.max() ?? 99) < max(2.5, w * 0.12)
            return (s.bounds.insetBy(dx: CGFloat(s.width) / 2, dy: CGFloat(s.width) / 2),
                    straight && w >= 6 && w <= 90 && h <= max(4, w * 0.3))
        }
        let (ra, fa) = flat(a), (rb, fb) = flat(b)
        guard fa, fb else { return false }
        let wa = ra.width, wb = rb.width
        guard min(wa, wb) / max(wa, wb) > 0.5 else { return false }                  // similar lengths
        let overlap = min(ra.maxX, rb.maxX) - max(ra.minX, rb.minX)
        guard overlap > 0.5 * min(wa, wb) else { return false }                       // one above the other
        let gap = abs(ra.midY - rb.midY)
        return gap >= 2 && gap <= max(wa, wb) * 0.9                                     // close, but not touching
    }

    /// The strokes of the sum to the left of the "=" on the same line, nearest first, stopping at a
    /// wide gap. Line height comes from the "=" itself.
    static func sum(before eq: CGRect, in strokes: [Stroke], excluding: Set<UUID>) -> [Stroke] {
        let lineH = max(eq.height * 3.2, 24)
        let band = CGRect(x: -1e6, y: eq.midY - lineH / 2, width: 2e6, height: lineH)
        var candidates = strokes.filter { s in
            !excluding.contains(s.id) && s.bounds.maxX <= eq.minX + eq.width * 0.3 &&
                s.bounds.intersection(band).height >= min(s.bounds.height, lineH) * 0.5
        }
        candidates.sort { $0.bounds.maxX > $1.bounds.maxX }
        var out: [Stroke] = []
        var left = eq.minX
        let maxGap = max(lineH * 1.6, 40)
        for s in candidates {
            if left - s.bounds.maxX > maxGap { break }  // a big gap ends the sum
            out.append(s)
            left = min(left, s.bounds.minX)
        }
        return out
    }
}
