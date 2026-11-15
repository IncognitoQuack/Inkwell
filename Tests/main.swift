import CoreGraphics
import Foundation
import ImageIO

// Standalone test runner: XCTest isn't available with Command Line Tools only.
// Build and run with `zsh test.sh`.

var failures = 0
var passes = 0

func check(_ cond: @autoclosure () -> Bool, _ msg: String, line: Int = #line) {
    if cond() { passes += 1 } else { failures += 1; print("FAIL line \(line): \(msg)") }
}

func test(_ name: String, _ body: () throws -> Void) {
    do { try body() } catch { failures += 1; print("FAIL \(name): threw \(error)") }
}

func pt(_ x: Float, _ y: Float, _ p: Float = 0.5, _ t: Float = 0) -> InkPoint { InkPoint(x: x, y: y, pressure: p, time: t) }

let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("inkwell-tests-\(UUID().uuidString)")
defer { try? FileManager.default.removeItem(at: tmp) }

// MARK: Model sanitising

test("stroke rejects empty and non-finite input") {
    check(Stroke(kind: .pen, color: RGBA(0, 0, 0), width: 2, points: []) == nil, "empty stroke should be nil")
    check(Stroke(kind: .pen, color: RGBA(0, 0, 0), width: 2, points: [pt(.nan, 1), pt(1, .infinity)]) == nil, "all-NaN stroke should be nil")
    let s = Stroke(kind: .pen, color: RGBA(0, 0, 0), width: .nan, points: [pt(.nan, 1), pt(5, 5, 7), pt(6, 6, -3)])!
    check(s.points.count == 2, "NaN point dropped")
    check(s.points[0].pressure == 1 && s.points[1].pressure == 0, "pressure clamped to 0...1")
    check(s.width == 2, "NaN width falls back to 2")
    let huge = Stroke(kind: .pen, color: RGBA(0, 0, 0), width: 1e9, points: [pt(1e30, -1e30)])!
    check(huge.width == Stroke.widthRange.upperBound, "width clamped")
    check(huge.points[0].x == 1e6 && huge.points[0].y == -1e6, "coordinates clamped")
    let long = Stroke(kind: .pen, color: RGBA(0, 0, 0), width: 2, points: (0..<20_000).map { pt(Float($0), 0) })!
    check(long.points.count == Stroke.maxPoints, "point count capped")
}

test("RGBA clamps out-of-range components") {
    let c = RGBA(2, -1, 0.5, 9)
    check(c == RGBA(1, 0, 0.5, 1), "components clamped")
}

test("titles are cleaned") {
    check(Notebook.cleanTitle("   ") == "Untitled", "blank title")
    check(Notebook.cleanTitle("a\u{0}b\nc") == "abc", "control chars stripped")
    check(Notebook.cleanTitle(String(repeating: "x", count: 500)).count == 200, "title length capped")
}

test("translate moves points and bounds together") {
    let s = Stroke(kind: .pen, color: RGBA(0, 0, 0), width: 2, points: [pt(0, 0), pt(10, 10)])!
    let m = s.translated(dx: 5, dy: -5)
    check(m.points[0].x == 5 && m.points[1].y == 5, "points moved")
    check(abs(m.bounds.minX - (s.bounds.minX + 5)) < 1e-4 && abs(m.bounds.minY - (s.bounds.minY - 5)) < 1e-4, "bounds moved")
    check(m.id == s.id, "id preserved")
}

test("moved strokes equal their reloaded selves") {
    let s = Stroke(kind: .pen, color: RGBA(0, 0, 0), width: 2.4, points: [pt(0.1, 0.2), pt(10.3, 7.7)])!
    let moved = s.translated(dx: 100.37, dy: -3.11)
    let back = try PropertyListDecoder().decode(Stroke.self, from: PropertyListEncoder().encode(moved))
    check(back == moved, "bounds recomputed identically after move + reload")
}

// MARK: Engine

test("1€ filter tolerates duplicate and backwards timestamps") {
    var f = OneEuroFilter(minCutoff: 1, beta: 0.01)
    _ = f.filter(0, time: 1)
    let a = f.filter(10, time: 1)
    let b = f.filter(20, time: 0.5)
    check(a.isFinite && b.isFinite, "no NaN from dt <= 0")
}

test("builder: single tap makes a dot") {
    let b = StrokeBuilder(kind: .pen, color: RGBA(0, 0, 0), width: 3, scale: 1, simulatePressure: false)
    b.add(x: 10, y: 10, pressure: 0.5, timestamp: 0)
    let s = b.finish(x: 10, y: 10, pressure: 0.5, timestamp: 0.01)
    check(s != nil && s!.points.count == 1, "one-point stroke")
    let path = InkGeometry.outlinePath(for: s!)
    check(!path.isEmpty && path.boundingBox.width > 0, "dot has visible outline")
}

test("builder: ignores NaN samples, drops jitter, reaches pen-up point") {
    let b = StrokeBuilder(kind: .pen, color: RGBA(0, 0, 0), width: 3, scale: 2, simulatePressure: true)
    b.add(x: .nan, y: 0, pressure: 1, timestamp: 0)
    check(b.points.isEmpty, "NaN ignored")
    for i in 0..<100 { b.add(x: 0.01 * Double(i % 2), y: 0, pressure: 0.5, timestamp: Double(i) * 0.008) }
    check(b.points.count == 1, "sub-pixel jitter collapses to one point (got \(b.points.count))")
    for i in 0..<50 { b.add(x: Double(i) * 4, y: 0, pressure: 0.5, timestamp: 1 + Double(i) * 0.008) }
    let s = b.finish(x: 300, y: 40, pressure: 0.5, timestamp: 2)!
    check(s.points.last!.x == 300 && s.points.last!.y == 40, "stroke ends exactly at pen-up")
    check(s.points.allSatisfy { $0.pressure >= 0 && $0.pressure <= 1 }, "simulated pressure in range")
}

test("builder: zoom-independent smoothing") {
    // The same screen-space gesture at two zoom levels must produce the same shape, scaled.
    func run(scale: Double) -> [InkPoint] {
        let b = StrokeBuilder(kind: .pen, color: RGBA(0, 0, 0), width: 3, scale: scale, simulatePressure: false)
        for i in 0..<60 {
            let sx = Double(i) * 5, sy = sin(Double(i) / 6) * 40
            b.add(x: sx / scale, y: sy / scale, pressure: 0.6, timestamp: Double(i) * 0.008)
        }
        return b.points
    }
    let a = run(scale: 1), b = run(scale: 4)
    check(a.count == b.count, "same point count")
    let maxErr = zip(a, b).map { abs($0.x - $1.x * 4) + abs($0.y - $1.y * 4) }.max() ?? 0
    check(maxErr < 0.01, "shapes match after scaling (err \(maxErr))")
}

test("builder: stops accepting at the point cap") {
    let b = StrokeBuilder(kind: .pen, color: RGBA(0, 0, 0), width: 3, scale: 1, simulatePressure: false)
    var i = 0
    while !b.isFull && i < 20_000 { b.add(x: Double(i), y: 0, pressure: 0.5, timestamp: Double(i) * 0.001); i += 1 }
    check(b.isFull, "builder reports full")
    check(!b.add(x: 99_999, y: 0, pressure: 0.5, timestamp: 100), "no points after full")
    check(b.makeStroke() != nil, "full builder still yields a stroke")
}

test("prediction is bounded") {
    let b = StrokeBuilder(kind: .pen, color: RGBA(0, 0, 0), width: 3, scale: 1, simulatePressure: false)
    for i in 0..<10 { b.add(x: Double(i) * 200, y: 0, pressure: 0.5, timestamp: Double(i) * 0.004) }
    if let p = b.predictedPoint(), let last = b.points.last {
        check(abs(p.x - last.x) <= 12.01, "prediction capped at 12 px (got \(abs(p.x - last.x)))")
    } else { check(false, "expected a prediction") }
}

test("outline: duplicate points, hairpins, coincident knots") {
    let dup = Stroke(kind: .pen, color: RGBA(0, 0, 0), width: 4, points: [pt(5, 5), pt(5, 5), pt(5, 5)])!
    check(!InkGeometry.outlinePath(for: dup).boundingBox.isNull, "duplicates still draw")
    let hairpin = Stroke(kind: .pen, color: RGBA(0, 0, 0), width: 8, points: [pt(0, 0, 1), pt(100, 0, 1), pt(0, 0.5, 1)])!
    let box = InkGeometry.outlinePath(for: hairpin).boundingBox
    check(box.minX.isFinite && box.maxX < 120 && box.minX > -20, "hairpin outline sane: \(box)")
    let zeroPressure = Stroke(kind: .pen, color: RGBA(0, 0, 0), width: 4, points: [pt(0, 0, 0), pt(10, 0, 0)])!
    check(InkGeometry.outlinePath(for: zeroPressure).boundingBox.height > 0, "zero pressure still visible")
    let samples = InkGeometry.smoothSamples(hairpin.points, kind: .pen, width: 8)
    check(samples.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.r > 0 }, "samples finite")
}

test("outline: incremental samples equal full samples") {
    let pts = (0..<40).map { pt(Float($0) * 3, sin(Float($0) / 4) * 20, 0.3 + Float($0 % 7) / 10) }
    let full = InkGeometry.smoothSamples(pts, kind: .pen, width: 4)
    let part = InkGeometry.smoothSamples(pts, kind: .pen, width: 4, toSegment: 20)
        + InkGeometry.smoothSamples(pts, kind: .pen, width: 4, fromSegment: 20)
    check(full.count == part.count, "same count \(full.count) vs \(part.count)")
    let err = zip(full, part).map { abs($0.x - $1.x) + abs($0.y - $1.y) + abs($0.r - $1.r) }.max() ?? 0
    check(err < 1e-9, "same samples (err \(err))")
}

test("highlighter has constant width") {
    check(InkGeometry.radius(kind: .highlighter, width: 20, pressure: 0) == InkGeometry.radius(kind: .highlighter, width: 20, pressure: 1), "pressure ignored")
    check(InkGeometry.radius(kind: .pen, width: 20, pressure: 0) < InkGeometry.radius(kind: .pen, width: 20, pressure: 1), "pen responds to pressure")
}

// MARK: Hit testing

test("eraser sweep catches strokes between samples") {
    let s = Stroke(kind: .pen, color: RGBA(0, 0, 0), width: 2, points: [pt(50, 0), pt(50, 100)])!
    check(HitTest.eraser(from: CGPoint(x: 0, y: 50), to: CGPoint(x: 100, y: 50), radius: 1, hits: s), "fast sweep across the stroke hits")
    check(!HitTest.eraser(from: CGPoint(x: 0, y: 200), to: CGPoint(x: 100, y: 200), radius: 5, hits: s), "far sweep misses")
    check(HitTest.eraser(from: CGPoint(x: 53, y: 50), to: CGPoint(x: 53, y: 50), radius: 2.5, hits: s), "radius + nib counted")
    let dot = Stroke(kind: .pen, color: RGBA(0, 0, 0), width: 4, points: [pt(10, 10)])!
    check(HitTest.eraser(from: CGPoint(x: 12, y: 10), to: CGPoint(x: 12, y: 10), radius: 1, hits: dot), "dot erasable")
}

test("lasso needs most of the stroke inside") {
    let square = [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0), CGPoint(x: 100, y: 100), CGPoint(x: 0, y: 100)]
    let inside = Stroke(kind: .pen, color: RGBA(0, 0, 0), width: 2, points: (0..<10).map { pt(10 + Float($0) * 5, 50) })!
    let grazing = Stroke(kind: .pen, color: RGBA(0, 0, 0), width: 2, points: (0..<10).map { pt(90 + Float($0) * 10, 50) })!
    check(HitTest.lasso(square, contains: inside), "inside selected")
    check(!HitTest.lasso(square, contains: grazing), "grazing not selected")
    check(!HitTest.lasso([CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 1)], contains: inside), "degenerate lasso selects nothing")
}

// MARK: Storage

func sampleNotebook() -> Notebook {
    var nb = Notebook(title: "Physics ✏️ नोट्स")
    nb.pages[0].strokes = (0..<50).map { i in
        Stroke(kind: i % 5 == 0 ? .highlighter : .pen, color: RGBA(0.1, 0.2, 0.9, i % 5 == 0 ? 0.35 : 1), width: 2.5,
               points: (0..<30).map { pt(Float($0) * 3, Float(i) * 10, Float($0) / 30, Float($0) * 0.01) })!
    }
    nb.pages.append(Page(style: .grid, paper: .cream, size: .letter))
    return nb
}

test("codec round-trips exactly") {
    let nb = sampleNotebook()
    let back = try NotebookCodec.decode(NotebookCodec.encode(nb))
    check(back.pages == nb.pages, "pages equal")
    check(back.title == nb.title && back.id == nb.id, "title and id equal")
    let meta = try NotebookCodec.decodeMetadata(NotebookCodec.encode(nb))
    check(meta.pageCount == 2 && meta.title == nb.title, "metadata readable on its own")
}

test("codec rejects damage precisely") {
    let good = try NotebookCodec.encode(sampleNotebook())
    func err(_ d: Data) -> NotebookCodec.CodecError? {
        do { _ = try NotebookCodec.decode(d); return nil } catch { return error as? NotebookCodec.CodecError }
    }
    check(err(Data()) == .notANotebook, "empty file")
    check(err(Data("%PDF-1.7".utf8)) == .notANotebook, "foreign file")
    check(err(good.prefix(10)) == .truncated, "short header")
    check(err(good.prefix(good.count - 1)) == .truncated, "missing last byte")
    var flipped = good
    flipped[good.count - 5] ^= 0xFF
    check(err(flipped) == .checksumMismatch, "bit flip detected")
    var newer = good
    newer[4] = 9
    check(err(newer) == .newerVersion(9), "newer version refused")
    var hugeLen = good
    hugeLen.replaceSubrange(12..<16, with: [0xFF, 0xFF, 0xFF, 0xFF])
    check(err(hugeLen) == .truncated, "absurd length rejected without allocating")
    check(err(good.subdata(in: 0..<good.count)) == nil, "slice with non-zero start index ok")
}

test("tolerant decoding keeps good data") {
    // A notebook whose plist has an empty pages array still opens with one page.
    struct Bare: Encodable { var id = UUID(); var title = "x"; var pages: [Page] = [] }
    let plist = PropertyListEncoder(); plist.outputFormat = .binary
    let nb = try PropertyListDecoder().decode(Notebook.self, from: plist.encode(Bare()))
    check(nb.pages.count == 1, "empty notebook gets a page")
}

test("store: save, list, load, backup recovery, trash") {
    let store = try LibraryStore(folder: tmp)
    var nb = sampleNotebook()
    try store.save(nb)
    nb.title = "Second save"
    try store.save(nb) // first save becomes the .bak
    let listing = store.list()
    check(listing.notebooks.map(\.title) == ["Second save"], "listed by metadata")
    let latest = try store.load(id: nb.id)
    check(latest.notebook.title == "Second save", "loads latest")

    // Damage the main file: the backup must be used and flagged.
    var damaged = try Data(contentsOf: store.url(for: nb.id))
    damaged[damaged.count - 3] ^= 0x55
    try damaged.write(to: store.url(for: nb.id))
    let rec = try store.load(id: nb.id)
    check(rec.recoveredFromBackup && rec.notebook.title == "Physics ✏️ नोट्स", "recovered previous good save")
    check(store.list().notebooks.count == 1, "damaged notebook still listed")

    // Saving over a damaged file must not replace the good backup with the damaged one.
    try store.save(rec.notebook)
    let fresh = try store.load(id: nb.id)
    check(fresh.recoveredFromBackup == false, "fresh save loads cleanly")

    // Junk in the folder is reported, not fatal.
    try Data("junk".utf8).write(to: tmp.appendingPathComponent("\(UUID().uuidString).inkwell"))
    let l2 = store.list()
    check(l2.notebooks.count == 1 && l2.problems.count == 1, "junk reported as a problem")

    // Version from the future: never fall back to the backup.
    var future = try Data(contentsOf: store.url(for: nb.id))
    future[4] = 7
    try future.write(to: store.url(for: nb.id))
    do { _ = try store.load(id: nb.id); check(false, "newer file should not load") }
    catch { check((error as? NotebookCodec.CodecError) == .newerVersion(7), "newer version surfaced") }

    try store.trash(id: nb.id)
    check(!store.exists(id: nb.id), "trashed")
}

test("large notebook encodes quickly and compactly") {
    var nb = Notebook(title: "Big")
    nb.pages = (0..<40).map { _ in
        var p = Page()
        p.strokes = (0..<150).map { i in Stroke(kind: .pen, color: RGBA(0, 0, 0), width: 2, points: (0..<120).map { pt(Float($0), Float(i), 0.5, Float($0) / 100) })! }
        return p
    }
    let t = Date()
    let data = try NotebookCodec.encode(nb)
    let back = try NotebookCodec.decode(data)
    let secs = Date().timeIntervalSince(t)
    check(back.pages.count == 40, "decoded")
    check(secs < 3, "40 pages × 150 strokes round-trip in \(String(format: "%.2f", secs))s")
    print("info: 720k points → \(data.count / 1024) KB, round-trip \(String(format: "%.2f", secs))s")
}

// MARK: v2 features

func line(_ x0: Float, _ x1: Float, y: Float = 0, step: Float = 2, width: Float = 2) -> Stroke {
    Stroke(kind: .pen, color: RGBA(0, 0, 0), width: width,
           points: stride(from: x0, through: x1, by: step).map { pt($0, y, 0.6) })!
}

test("precise eraser splits, keeps id, cuts fast sweeps, ignores misses") {
    let s = line(0, 100)
    let parts = HitTest.eraseSplit(s, from: CGPoint(x: 50, y: -20), to: CGPoint(x: 50, y: 20), radius: 3)!
    check(parts.count == 2, "two pieces (got \(parts.count))")
    check(parts[0].id == s.id && parts[1].id != s.id, "first piece keeps id")
    check(parts.allSatisfy { $0.points.allSatisfy { abs($0.x - 50) > 3 } }, "no points left under the eraser")
    check(HitTest.eraseSplit(s, from: CGPoint(x: 50, y: 40), to: CGPoint(x: 60, y: 40), radius: 3) == nil, "miss → nil")
    check(HitTest.eraseSplit(s, from: CGPoint(x: -10, y: 0), to: CGPoint(x: 110, y: 0), radius: 3)?.isEmpty == true, "full sweep erases all")
    let sparse = line(0, 100, step: 20)
    let cut = HitTest.eraseSplit(sparse, from: CGPoint(x: 50, y: -20), to: CGPoint(x: 50, y: 20), radius: 1)!
    check(cut.count == 2 && cut.allSatisfy { $0.points.count >= 2 }, "sweep between samples still cuts (\(cut.map(\.points.count)))")
    let dot = Stroke(kind: .pen, color: RGBA(0, 0, 0), width: 4, points: [pt(5, 5)])!
    check(HitTest.eraseSplit(dot, from: CGPoint(x: 5, y: 5), to: CGPoint(x: 5, y: 5), radius: 2)?.isEmpty == true, "dot erased")
}

func noisy(_ f: (CGFloat) -> CGPoint, n: Int = 120, jitter: CGFloat = 1.5) -> [CGPoint] {
    var g = SystemRandomNumberGenerator()
    return (0..<n).map { i in
        let p = f(CGFloat(i) / CGFloat(n - 1))
        return CGPoint(x: p.x + .random(in: -jitter...jitter, using: &g), y: p.y + .random(in: -jitter...jitter, using: &g))
    }
}

test("shape recognition: line, ellipse, rectangle, triangle; freehand left alone") {
    check(ShapeRecognizer.recognize(noisy { CGPoint(x: 10 + $0 * 200, y: 50 + $0 * 30) })?.shape == .line, "line")
    check(ShapeRecognizer.recognize(noisy { CGPoint(x: 100 + cos($0 * 2 * .pi) * 80, y: 100 + sin($0 * 2 * .pi) * 50) })?.shape == .ellipse, "ellipse")
    let rect: (CGFloat) -> CGPoint = { u in
        let t = u * 4
        switch t {
        case ..<1: return CGPoint(x: 10 + t * 150, y: 10)
        case ..<2: return CGPoint(x: 160, y: 10 + (t - 1) * 90)
        case ..<3: return CGPoint(x: 160 - (t - 2) * 150, y: 100)
        default: return CGPoint(x: 10, y: 100 - (t - 3) * 90)
        }
    }
    let r = ShapeRecognizer.recognize(noisy(rect))
    check(r?.shape == .rectangle, "rectangle (got \(String(describing: r?.shape)))")
    let tri: (CGFloat) -> CGPoint = { u in
        let a = CGPoint(x: 100, y: 10), b = CGPoint(x: 180, y: 150), c = CGPoint(x: 20, y: 150)
        let t = u * 3
        func lerp(_ p: CGPoint, _ q: CGPoint, _ k: CGFloat) -> CGPoint { CGPoint(x: p.x + (q.x - p.x) * k, y: p.y + (q.y - p.y) * k) }
        return t < 1 ? lerp(a, b, t) : t < 2 ? lerp(b, c, t - 1) : lerp(c, a, t - 2)
    }
    check(ShapeRecognizer.recognize(noisy(tri))?.shape == .triangle, "triangle")
    let spiral = noisy({ CGPoint(x: 100 + cos($0 * 12) * $0 * 80, y: 100 + sin($0 * 12) * $0 * 80) }, jitter: 0.5)
    check(ShapeRecognizer.recognize(spiral) == nil, "spiral is not a shape")
    let wave = noisy({ CGPoint(x: $0 * 300, y: 50 + sin($0 * 20) * 20) }, jitter: 0.5)
    check(ShapeRecognizer.recognize(wave) == nil, "handwriting-like wave is not a shape")
    check(ShapeRecognizer.recognize([CGPoint(x: 1, y: 1)]) == nil && ShapeRecognizer.recognize([]) == nil, "degenerate input")
    if let res = ShapeRecognizer.recognize(noisy { CGPoint(x: 10 + $0 * 200, y: 50) }) {
        let st = ShapeRecognizer.stroke(for: res, like: line(0, 10))!
        check(st.points.count > 10, "recognised line is densified (\(st.points.count) points)")
    }
}

test("arrow recognition: one-stroke arrows snap, look-alikes don't") {
    // Shaft right, then head: up-back barb, return to tip, down-back barb.
    func arrowPath(_ dx: CGFloat, _ dy: CGFloat) -> [CGPoint] {
        let a = CGPoint(x: 100, y: 100), len: CGFloat = 200
        let n = CGVector(dx: dx / hypot(dx, dy), dy: dy / hypot(dx, dy))
        let tip = CGPoint(x: a.x + n.dx * len, y: a.y + n.dy * len)
        func back(_ s: CGFloat) -> CGPoint { CGPoint(x: tip.x - n.dx * 30 - n.dy * 22 * s, y: tip.y - n.dy * 30 + n.dx * 22 * s) }
        var pts: [CGPoint] = (0...40).map { i in CGPoint(x: a.x + n.dx * len * CGFloat(i) / 40, y: a.y + n.dy * len * CGFloat(i) / 40) }
        for (from, to) in [(tip, back(1)), (back(1), tip), (tip, back(-1))] {
            pts += (1...8).map { i in CGPoint(x: from.x + (to.x - from.x) * CGFloat(i) / 8, y: from.y + (to.y - from.y) * CGFloat(i) / 8) }
        }
        var g = SystemRandomNumberGenerator()
        return pts.map { CGPoint(x: $0.x + .random(in: -0.8...0.8, using: &g), y: $0.y + .random(in: -0.8...0.8, using: &g)) }
    }
    for (dx, dy) in [(1.0, 0.0), (0.0, 1.0), (-1.0, 0.4), (0.7, -0.7)] as [(CGFloat, CGFloat)] {
        let r = ShapeRecognizer.recognize(arrowPath(dx, dy))
        check(r?.shape == .arrow, "arrow towards (\(dx),\(dy)) recognised (got \(String(describing: r?.shape)))")
        if let r { check(r.points.count == 5 && r.points[1] == r.points[3], "clean head geometry") }
    }
    // A "check mark" (shaft then one short stroke to one side only) is not an arrow.
    var tick = (0...30).map { CGPoint(x: 100 + CGFloat($0) * 4, y: 100) }
    tick += (1...8).map { CGPoint(x: 220 - CGFloat($0) * 3, y: 100 - CGFloat($0) * 3) }
    check(ShapeRecognizer.recognize(tick)?.shape != .arrow, "one-sided hook isn't an arrow")
}

test("PDF/document text is searchable") {
    var p = Page()
    p.documentText = "Chapter 3: Thermodynamics"
    p.recognizedText = "my notes"
    check(p.searchableText.contains("Thermodynamics") && p.searchableText.contains("my notes"), "document + handwriting text searchable")
}

test("scribble-to-erase detection") {
    let zig = Stroke(kind: .pen, color: RGBA(0, 0, 0), width: 3, points: (0..<80).map { i in
        let u = Float(i) / 79
        return pt(100 + (Float(i % 10) < 5 ? Float(i % 5) * 16 : Float(4 - i % 5) * 16), 100 + u * 30, 0.6)
    })!
    check(ScribbleDetector.isScribble(zig), "zig-zag is a scribble")
    let circle = Stroke(kind: .pen, color: RGBA(0, 0, 0), width: 3, points: (0..<80).map { i in
        let a = Float(i) / 79 * 2 * .pi
        return pt(100 + cos(a) * 40, 100 + sin(a) * 40, 0.6)
    })!
    check(!ScribbleDetector.isScribble(circle), "circle is not a scribble")
    check(!ScribbleDetector.isScribble(line(0, 300)), "line is not a scribble")
    let word = line(110, 150, y: 115)
    let longLine = line(0, 600, y: 112)
    let far = line(400, 450, y: 400)
    let t = ScribbleDetector.targets(of: zig, in: [word, longLine, far])
    check(t == [word.id], "only the small word under the scribble is targeted (got \(t.count))")
}

test("links normalise safely") {
    check(LinkURL.normalize("example.com/a") == "https://example.com/a", "bare domain gets https")
    check(LinkURL.normalize("mailto:a@b.co") == "mailto:a@b.co", "mailto kept")
    check(LinkURL.normalize("javascript:alert(1)") == nil, "javascript rejected")
    check(LinkURL.normalize("not a link") == nil && LinkURL.normalize("") == nil, "junk rejected")
}

func v2Notebook() throws -> Notebook {
    var nb = Notebook(title: "v2")
    var st = TextStyle(); st.font = .serif; st.size = 20; st.bold = true; st.highlight = RGBA(1, 1, 0, 0.3)
    let w: CGFloat = 300
    let text = "Read https://apple.com and more"
    nb.pages[0].elements = [
        PageElement(frame: CGRect(x: 80, y: 120, width: w, height: PageRenderer.textHeight(text, style: st, width: w)), content: .text(text, st)),
        PageElement(frame: CGRect(x: 80, y: 300, width: 120, height: 80), content: .link, link: "example.org"),
    ]
    let png = try Importer.imageAsset(from: makePNG(w: 64, h: 32, alpha: true))
    let asset = UUID()
    nb.assets[asset] = png.data
    nb.pages[0].elements.append(PageElement(frame: CGRect(x: 300, y: 500, width: 128, height: 64), content: .image(asset: asset)))
    nb.pages[0].recognizedText = "handwritten words"
    return nb
}

func makePNG(w: Int, h: Int, alpha: Bool) -> Data {
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: (alpha ? CGImageAlphaInfo.premultipliedLast : CGImageAlphaInfo.noneSkipLast).rawValue)!
    ctx.setFillColor(CGColor(srgbRed: 0.2, green: 0.5, blue: 0.9, alpha: alpha ? 0.5 : 1))
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    let out = NSMutableData()
    let d = CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(d, ctx.makeImage()!, nil)
    CGImageDestinationFinalize(d)
    return out as Data
}

test("v2 codec: elements, assets, search text round-trip; v1 files still open") {
    let nb = try v2Notebook()
    let data = try NotebookCodec.encode(nb)
    let back = try NotebookCodec.decode(data)
    check(back.pages == nb.pages && back.assets == nb.assets, "elements and assets round-trip")
    let meta = try NotebookCodec.decodeMetadata(data)
    let text = meta.pageTexts?.first ?? ""
    check(text.contains("apple.com") && text.contains("handwritten"), "metadata carries typed + recognised text")
    var v1 = try NotebookCodec.encode(sampleNotebook())
    v1[4] = 1
    check((try? NotebookCodec.decode(v1)) != nil, "v1 file decodes")
}

test("element sanitising") {
    let e = PageElement(frame: CGRect(x: CGFloat.nan, y: 5, width: -50, height: CGFloat.infinity), content: .link)
    check(e.frame.origin.x.isFinite && e.frame.width >= 4 && e.frame.height.isFinite, "frame sanitised: \(e.frame)")
    let long = PageElement(frame: .init(x: 0, y: 0, width: 10, height: 10), content: .text(String(repeating: "a", count: 50_000), TextStyle()))
    check((long.text?.count ?? 0) == PageElement.maxTextLength, "text capped")
    check(PageElement(frame: .zero, content: .link, link: "javascript:x").link == nil, "unsafe link dropped")
}

test("text layout and link areas") {
    var st = TextStyle(); st.size = 16
    let h1 = PageRenderer.textHeight("one line", style: st, width: 300)
    let h3 = PageRenderer.textHeight("one\ntwo\nthree", style: st, width: 300)
    check(h3 > h1 * 2.2, "height grows with lines (\(h1) → \(h3))")
    check(PageRenderer.textHeight("", style: st, width: 300) > 10, "empty box still one line tall")
    let nb = try v2Notebook()
    let areas = PageRenderer.linkAreas(nb.pages[0])
    check(areas.count == 2, "text link + link element (got \(areas.count))")
    if let textLink = areas.first(where: { $0.1.host == "apple.com" }) {
        let box = nb.pages[0].elements[0].frame
        check(box.insetBy(dx: -1, dy: -1).contains(textLink.0), "link rect inside its text box: \(textLink.0) in \(box)")
        check(textLink.0.width > 20 && textLink.0.minX > box.minX + 10, "link rect sits after 'Read ' (\(textLink.0))")
    } else { check(false, "apple.com link found") }
}

test("PDF export: page subset, link annotations, re-import") {
    var nb = try v2Notebook()
    nb.pages.append(Page(style: .grid, paper: .cream, size: .letter))
    let url = tmp.appendingPathComponent("export.pdf")
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    try PageRenderer.exportPDF(nb, to: url)
    let doc = CGPDFDocument(url as CFURL)!
    check(doc.numberOfPages == 2, "two pages")
    var annots: CGPDFArrayRef?
    let hasAnnots = doc.page(at: 1)!.dictionary.map { CGPDFDictionaryGetArray($0, "Annots", &annots) } ?? false
    check(hasAnnots && annots.map { CGPDFArrayGetCount($0) } == 2, "two link annotations on page 1")
    let sz = PageRenderer.displaySize(of: doc.page(at: 2)!)
    check(abs(sz.width - 612) < 0.5 && abs(sz.height - 792) < 0.5, "letter page keeps its size: \(sz)")
    let one = tmp.appendingPathComponent("one.pdf")
    try PageRenderer.exportPDF(nb, pages: [1], to: one)
    check(CGPDFDocument(one as CFURL)!.numberOfPages == 1, "single-page export")
    check((try? PageRenderer.exportPDF(nb, pages: [99], to: one)) == nil, "invalid page selection rejected")

    let imported = try Importer.notebook(fromPDF: Data(contentsOf: url), title: "Imported")
    check(imported.pages.count == 2 && imported.assets.count == 1, "imported pages share one embedded PDF")
    check(abs(imported.pages[1].pageSize.width - 612) < 0.5, "imported page size kept")
    if case .pdf(_, let idx) = imported.pages[1].background { check(idx == 1, "page index") } else { check(false, "pdf background") }
    let thumb = PageRenderer.image(of: imported.pages[0], maxSide: 300, assets: AssetCache(assets: imported.assets))
    check(thumb != nil, "PDF page renders")
}

test("importer rejects junk and sizes images sensibly") {
    do { _ = try Importer.notebook(fromPDF: Data("junk".utf8), title: "x"); check(false, "junk pdf") }
    catch { check((error as? Importer.ImportError) == .unreadablePDF, "junk pdf → unreadablePDF") }
    do { _ = try Importer.imageAsset(from: Data("junk".utf8)); check(false, "junk image") }
    catch { check((error as? Importer.ImportError) == .unreadableImage, "junk image → unreadableImage") }
    let big = try Importer.imageAsset(from: makePNG(w: 5000, h: 2500, alpha: false), maxPixel: 2400)
    check(max(big.pixelSize.width, big.pixelSize.height) <= 2400, "downsampled to 2400 (\(big.pixelSize))")
    check(big.data.starts(with: [0xFF, 0xD8]), "opaque image re-encoded as JPEG")
    let clear = try Importer.imageAsset(from: makePNG(w: 40, h: 40, alpha: true))
    check(clear.data.starts(with: [0x89, 0x50, 0x4E, 0x47]), "transparent image stays PNG")
    let page = Page()
    let f = Importer.placement(for: CGSize(width: 4000, height: 1000), on: page, center: CGPoint(x: 590, y: 5))
    check(page.rect.contains(f), "placement stays on the page: \(f)")
}

test("asset pruning keeps only referenced assets") {
    var nb = try v2Notebook()
    nb.assets[UUID()] = Data([1, 2, 3])
    nb.pruneAssets()
    check(nb.assets.count == 1, "orphan dropped, used image kept")
}

// MARK: Pen Lab analysis

func samples(_ pts: [(Double, Double, Double)], t0: Double = 0, dt: Double = 1.0 / 266) -> [PenSample] {
    pts.enumerated().map { i, p in
        PenSample(t: t0 + Double(i) * dt, x: p.0, y: p.1, pressure: p.2, tiltX: 0, tiltY: 0, rotation: 0,
                  phase: i == 0 ? .down : i == pts.count - 1 ? .up : .drag, button: 0, isTablet: true)
    }
}

test("pen lab: report rate, pressure stats, jitter, circle fit") {
    let linePts: [(Double, Double, Double)] = (0..<200).map { i -> (Double, Double, Double) in
        let x = Double(i), wobble = (Double(i % 2) - 0.5) * 0.6
        return (x, 100 + wobble, 0.3 + x / 400)
    }
    let line = samples(linePts)
    check(abs((PenAnalysis.reportRate(line) ?? 0) - 266) < 2, "report rate ≈ 266 Hz")
    let ps = PenAnalysis.pressureStats(line)!
    check(ps.min > 0.29 && ps.max < 0.81 && ps.distinctLevels > 150, "pressure stats \(ps)")
    let j = PenAnalysis.lineJitter(line)!
    check(abs(j - 0.3) < 0.05, "line jitter ≈ 0.3 (got \(j))")
    let circPts: [(Double, Double, Double)] = (0..<120).map { i -> (Double, Double, Double) in
        let a = Double(i) / 120 * 2 * Double.pi
        return (200 + cos(a) * 50, 200 + sin(a) * 50, 0.5)
    }
    let circ = samples(circPts)
    check((PenAnalysis.circleJitter(circ) ?? 9) < 0.01, "perfect circle → ~0 jitter")
    let fit = PenAnalysis.fitCircle([(1, 0), (0, 1), (-1, 0), (0, -1)])!
    check(abs(fit.2 - 1) < 1e-9 && abs(fit.0) < 1e-9, "circle fit exact")
    check(PenAnalysis.fitCircle([(0, 0), (1, 1), (2, 2)]) == nil, "collinear points → no circle")
    // Pauses and duplicate timestamps don't distort the rate.
    var gap = line; for i in 100..<gap.count { gap[i].t += 5 }
    check(abs((PenAnalysis.reportRate(gap) ?? 0) - 266) < 2, "pause ignored")
    check(PenAnalysis.reportRate([]) == nil && PenAnalysis.pressureStats([]) == nil, "empty input")
    let two = samples([(0, 0, 0.5), (10, 0, 0.5)]) + samples([(0, 50, 0.5), (10, 50, 0.5)], t0: 1)
    check(PenAnalysis.strokes(two).count == 2, "strokes split on down/up")
}

test("pen lab: recommendations are personal and safe") {
    let r = PenAnalysis.recommend(light: [0.12, 0.15, 0.1], normal: [0.35, 0.4, 0.38], firm: [0.7, 0.75, 0.8], allContact: [],
                                  jitter: 0.4, reportRate: 266)
    let c = r.curve
    check(c.isSane, "curve sane: \(c)")
    check(abs(c.apply(0.38) - 0.55) < 0.02, "normal pressure maps to 55% (got \(c.apply(0.38)))")
    check(c.apply(0.0) == 0 && abs(c.apply(1.0) - 1) < 1e-9, "ends pinned")
    check(c.apply(0.79) > 0.97, "firm reaches ~full width")
    check(r.smoothing == 2.0, "medium jitter → 2.0 smoothing")
    let empty = PenAnalysis.recommend(light: [], normal: [], firm: [], allContact: [], jitter: nil, reportRate: nil)
    check(empty.curve.isSane && abs(empty.curve.gamma - 1) < 1e-9, "no data → identity-ish curve")
    let weird = PenAnalysis.recommend(light: [0.9], normal: [0.95], firm: [0.2], allContact: [], jitter: .nan, reportRate: .nan)
    check(weird.curve.isSane, "inconsistent data still yields a sane curve: \(weird.curve)")
    check(PressureCurve(floor: 0.2, ceiling: 0.6, gamma: 1).apply(.nan) == 0.5, "NaN pressure handled")
}

test("builder uses the personal curve") {
    let curve = PressureCurve(floor: 0.2, ceiling: 0.6, gamma: 1)
    let b = StrokeBuilder(kind: .pen, color: RGBA(0, 0, 0), width: 3, scale: 1, simulatePressure: false, curve: curve)
    b.add(x: 0, y: 0, pressure: 0.6, timestamp: 0)
    check(abs(b.points[0].pressure - 1) < 1e-6, "ceiling → full pressure")
    let bad = StrokeBuilder(kind: .pen, color: RGBA(0, 0, 0), width: 3, scale: 1, simulatePressure: false,
                            curve: PressureCurve(floor: 0.9, ceiling: 0.2, gamma: 9))
    bad.add(x: 0, y: 0, pressure: 0.6, timestamp: 0)
    check(abs(bad.points[0].pressure - 0.6) < 1e-6, "insane curve ignored")
}

// MARK: Password lock + folders

test("password lock: round-trip, wrong password, no leaks, backups, damage") {
    let folder = tmp.appendingPathComponent("locked-\(UUID().uuidString)")
    let store = try LibraryStore(folder: folder)
    var nb = try v2Notebook()
    nb.title = "Diary"
    let pw = "correct horse ✓ battery"
    let data = try NotebookCodec.encode(nb, password: pw)
    check(NotebookCodec.isEncrypted(data) && NotebookCodec.isIntact(data), "encrypted + intact")
    check(data[4] == 3 && data[6] == 1, "written as v3 with encrypted flag")
    let back = try NotebookCodec.decode(data, password: pw)
    check(back.pages == nb.pages && back.assets == nb.assets, "round-trips with the right password")
    do { _ = try NotebookCodec.decode(data); check(false, "no password should fail") }
    catch { check((error as? NotebookCodec.CodecError) == .locked, "no password → .locked") }
    do { _ = try NotebookCodec.decode(data, password: "nope"); check(false, "wrong password should fail") }
    catch { check((error as? NotebookCrypto.CryptoError) == .wrongPassword, "wrong password → .wrongPassword (\(error))") }
    let meta = try NotebookCodec.decodeMetadata(data)
    check(meta.locked == true && meta.pageTexts == nil && meta.title == "Diary", "metadata: title only, no search text")
    let needle = Data("apple.com".utf8), needle2 = Data("handwritten".utf8)
    check(data.range(of: needle) == nil && data.range(of: needle2) == nil, "no plaintext content in the file")
    // Two saves of the same notebook differ (fresh nonce) but both open.
    let again = try NotebookCodec.encode(nb, password: pw)
    check(again != data && (try? NotebookCodec.decode(again, password: pw)) != nil, "fresh nonce per save")
    // A flipped byte inside the ciphertext is caught by the checksum first.
    var bad = data; bad[bad.count - 10] ^= 0x01
    check(!NotebookCodec.isIntact(bad), "damage detected without the password")
    // Store: save locked twice (backup made from intact locked file), load needs the password.
    try store.save(nb, password: pw)
    try store.save(nb, password: pw)
    check(FileManager.default.fileExists(atPath: folder.appendingPathComponent("\(nb.id.uuidString).inkwell.bak").path), "backup kept for locked file")
    do { _ = try store.load(id: nb.id); check(false, "locked load needs password") }
    catch { check((error as? NotebookCodec.CodecError) == .locked, "store load → .locked (not backup fallback)") }
    do { _ = try store.load(id: nb.id, password: "x"); check(false, "wrong pw") }
    catch { check((error as? NotebookCrypto.CryptoError) == .wrongPassword, "store load wrong pw surfaced") }
    let opened = try store.load(id: nb.id, password: pw)
    check(opened.notebook.title == "Diary", "store load with password")
    let listed = store.list().notebooks.first { $0.id == nb.id }
    check(listed?.locked == true, "listing shows locked")
    // Removing the password: save plain again.
    try store.save(nb)
    let plain = try store.load(id: nb.id)
    check(plain.notebook.title == "Diary", "unlocked after saving without password")
}

test("folders: sanitise, move, persist, tolerate junk") {
    let folder = tmp.appendingPathComponent("folders-\(UUID().uuidString)")
    let store = try LibraryStore(folder: folder)
    check(store.loadFolders().folders.isEmpty, "no index → no folders")
    let a = UUID(), b = UUID(), gone = UUID()
    var f = LibraryFolders(folders: [LibraryFolder(name: "  School  ", notebooks: [a, b, a]), LibraryFolder(name: "", notebooks: [b, gone])])
    f.sanitize(existing: [a, b])
    check(f.folders[0].name == "School" && f.folders[0].notebooks == [a, b], "trimmed, de-duplicated")
    check(f.folders[1].name == "Untitled Folder" && f.folders[1].notebooks.isEmpty, "notebook kept in first folder only; missing dropped")
    f.move(a, to: f.folders[1].id)
    check(f.folder(of: a) == f.folders[1].id && !f.folders[0].notebooks.contains(a), "move")
    f.move(a, to: nil)
    check(f.folder(of: a) == nil, "move out")
    try store.saveFolders(f)
    check(store.loadFolders() == f, "persisted")
    try Data("{garbage".utf8).write(to: folder.appendingPathComponent("folders.json"))
    check(store.loadFolders().folders.isEmpty, "junk index → no folders, no crash")
}

// MARK: Study, maths, audio anchors

test("spaced repetition (SM-2)") {
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    var r = Review.new(now: t0)
    check(r.isDue(now: t0), "new card is due")
    r = r.answered(.good, now: t0)
    check(r.interval == 1 && abs(r.due.timeIntervalSince(t0) - 86_400) < 1, "first good → 1 day")
    r = r.answered(.good, now: r.due)
    check(r.interval == 6, "second good → 6 days")
    let before = r.interval
    r = r.answered(.good, now: r.due)
    check(r.interval > before * 2, "then grows by ease (\(r.interval))")
    let lapsed = r.answered(.again, now: r.due)
    check(lapsed.reps == 0 && lapsed.lapses == 1 && lapsed.due.timeIntervalSince(r.due) == 600, "again → relearn in 10 min")
    var hard = Review.new(now: t0)
    for _ in 0..<20 { hard = hard.answered(.hard, now: hard.due) }
    check(hard.ease >= 1.3, "ease never drops below 1.3")
    var easy = Review.new(now: t0)
    for _ in 0..<40 { easy = easy.answered(.easy, now: easy.due) }
    check(easy.interval <= 3650, "interval capped at 10 years")
}

test("math solving: arithmetic, OCR quirks, and refusals") {
    func v(_ s: String) -> String? { MathEval.solve(s)?.formatted }
    check(v("12 x (3+4) =") == "84", "12x(3+4) = 84 (got \(v("12 x (3+4) =") ?? "nil"))")
    check(v("7 ÷ 2") == "3.5", "division with ÷")
    check(v("2^10") == "1024", "power")
    check(v("2^3^2") == "512", "power is right-associative")
    check(v("−5 + 3") == "-2", "unicode minus")
    check(v("50% x 80") == "40", "percent")
    check(v("√16 + 2(3)") == "10", "root and implicit multiplication")
    check(v("0.1+0.2") == "0.3", "float tidy")
    check(v("1/0") == nil, "division by zero refused")
    check(v("42") == nil && v("-42") == nil, "a lone number isn't a sum")
    check(v("hello") == nil && v("") == nil && v("2+") == nil && v("((2)") == nil, "junk refused")
    check(v(String(repeating: "(", count: 100) + "1" + String(repeating: ")", count: 100)) == nil, "deep nesting refused safely")
    check(v("9^9^9") == nil, "overflow refused")
    check(v("1.2.3+1") == nil, "malformed number refused")
}

test("tape elements, audio anchors and transcripts round-trip and are searchable") {
    var nb = Notebook(title: "Study")
    let tape = PageElement(frame: CGRect(x: 50, y: 50, width: 200, height: 30), content: .tape(RGBA(1, 0.8, 0.3), Review.new()))
    nb.pages[0].elements = [tape]
    var s = line(0, 50)
    let rec = UUID()
    s.recording = rec
    s.recordingOffset = 12.5
    nb.pages[0].strokes = [s]
    let audio = UUID()
    nb.assets[audio] = Data([1, 2, 3])
    nb.recordings = [Recording(id: rec, asset: audio, started: Date(), duration: 30, page: nb.pages[0].id, transcript: "photosynthesis lecture")]
    let back = try NotebookCodec.decode(NotebookCodec.encode(nb))
    check(back.pages[0].elements[0].isTape && back.pages[0].elements[0].review != nil, "tape + review round-trip")
    check(back.pages[0].strokes[0].recording == rec && back.pages[0].strokes[0].recordingOffset == 12.5, "audio anchor round-trips")
    check(back.recordings == nb.recordings, "recordings round-trip")
    check(nb.metadata.pageTexts?.first?.contains("photosynthesis") == true, "transcript searchable on its page")
    var orphan = nb
    orphan.assets = [:]
    let o = try NotebookCodec.decode(NotebookCodec.encode(orphan))
    check(o.recordings.isEmpty, "recording without audio dropped")
    var pruned = nb
    pruned.pruneAssets()
    check(pruned.assets[audio] != nil, "recording audio kept by pruning")
}

test("library move (iCloud Drive switch): newer copy wins, nothing lost") {
    let src = tmp.appendingPathComponent("move-src-\(UUID().uuidString)")
    let dst = tmp.appendingPathComponent("move-dst-\(UUID().uuidString)/Inkwell")
    let a = try LibraryStore(folder: src)
    var only = Notebook(title: "Only here")
    var both = Notebook(title: "Old copy")
    both.modified = Date(timeIntervalSince1970: 1_000)
    try a.save(only)
    try a.save(both)
    try a.saveFolders(LibraryFolders(folders: [LibraryFolder(name: "School", notebooks: [only.id])]))
    // The destination already has a NEWER copy of `both`.
    let b = try LibraryStore(folder: dst)
    var newer = both
    newer.title = "New copy"
    newer.modified = Date(timeIntervalSince1970: 2_000)
    try b.save(newer)
    let r = LibraryStore.moveLibrary(from: src, to: dst)
    check(r.failed.isEmpty && r.moved == 1 && r.keptNewer >= 1, "moved 1, kept newer 1 (\(r))")
    let titles = Set(b.list().notebooks.map(\.title))
    check(titles == ["Only here", "New copy"], "destination has both, newest wins (\(titles))")
    check(b.loadFolders().folders.first?.name == "School", "folder index moved")
    check(FileManager.default.fileExists(atPath: src.appendingPathComponent("\(both.id.uuidString).inkwell").path), "older copy left in source, not deleted")
    only.title = "x"; _ = only
}

test("auto-answer: '=' detection and the sum before it") {
    func dash(_ x: Float, _ y: Float, _ w: Float) -> Stroke {
        Stroke(kind: .pen, color: RGBA(0, 0, 0), width: 2, points: (0...10).map { pt(x + w * Float($0) / 10, y + Float($0 % 2) * 0.4, 0.6) })!
    }
    let top = dash(300, 100, 24), bottom = dash(301, 110, 22)
    check(EqualsDetector.isEqualsSign(top, bottom), "two stacked dashes are '='")
    check(!EqualsDetector.isEqualsSign(top, dash(300, 160, 24)), "far apart: not '='")
    check(!EqualsDetector.isEqualsSign(top, dash(360, 110, 24)), "side by side: not '='")
    check(!EqualsDetector.isEqualsSign(top, dash(300, 110, 6)), "very different lengths: not '='")
    let vertical = Stroke(kind: .pen, color: RGBA(0, 0, 0), width: 2, points: (0...10).map { pt(320, 90 + Float($0) * 3, 0.6) })!
    check(!EqualsDetector.isEqualsSign(top, vertical), "a vertical stroke isn't half of '='")
    let wavy = Stroke(kind: .pen, color: RGBA(0, 0, 0), width: 2, points: (0...10).map { pt(300 + Float($0) * 2.4, 110 + ($0 % 2 == 0 ? 4 : -4), 0.6) })!
    check(!EqualsDetector.isEqualsSign(top, wavy), "a zig-zag isn't half of '='")
    // "12+3 =" written left of the sign, plus unrelated ink on another line and far to the left.
    let digits = [line(200, 215, y: 105), line(225, 245, y: 104), line(250, 265, y: 106), line(270, 290, y: 105)]
    let otherLine = line(200, 260, y: 200)
    let farLeft = line(20, 40, y: 105)
    let eq = top.bounds.union(bottom.bounds)
    let found = EqualsDetector.sum(before: eq, in: digits + [otherLine, farLeft, top, bottom], excluding: [top.id, bottom.id])
    check(Set(found.map(\.id)) == Set(digits.map(\.id)), "sum = the digits on that line only (\(found.count))")
}

// MARK: GoodNotes import

/// Protobuf encoding helpers for building synthetic GoodNotes exports.
func pbVarint(_ v: UInt64) -> Data { var v = v; var d = Data(); repeat { var b = UInt8(v & 0x7F); v >>= 7; if v > 0 { b |= 0x80 }; d.append(b) } while v > 0; return d }
func pbBytes(_ n: Int, _ d: Data) -> Data { pbVarint(UInt64(n << 3 | 2)) + pbVarint(UInt64(d.count)) + d }
func pbString(_ n: Int, _ s: String) -> Data { pbBytes(n, Data(s.utf8)) }
func pbFloat(_ n: Int, _ f: Float) -> Data { var d = pbVarint(UInt64(n << 3 | 5)); withUnsafeBytes(of: f.bitPattern.littleEndian) { d.append(contentsOf: $0) }; return d }
func pbInt(_ n: Int, _ v: UInt64) -> Data { pbVarint(UInt64(n << 3)) + pbVarint(v) }
func pbRecord(_ m: Data) -> Data { pbVarint(UInt64(m.count)) + m }
func lww(_ s: String) -> Data { pbString(1, s) + pbBytes(2, pbInt(1, 1) + pbInt(2, 7)) }

func tplStroke(start: (Float, Float, Float), quads: [(Float, Float, Float, Float, Float, Float)]) -> Data {
    var d = Data("tpl\0".utf8)
    let sig = Data("vA(v)A(u)A(u)A(v)A(v)A(u)A(u)A(u)A(u)A(v)\0".utf8)
    var body = Data()
    func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { body.append(contentsOf: $0) } }
    func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { body.append(contentsOf: $0) } }
    func f(_ v: Float) { withUnsafeBytes(of: v.bitPattern.littleEndian) { body.append(contentsOf: $0) } }
    u16(2)
    u32(UInt32(quads.count + 1)); u16(0); for _ in quads { u16(1) }
    u32(3); f(start.0); f(start.1); f(start.2)
    u32(UInt32(quads.count * 6)); for q in quads { [q.0, q.1, q.2, q.3, q.4, q.5].forEach(f) }
    for _ in 0..<7 { u32(0) } // outline arrays GoodNotes precomputes; Inkwell rebuilds its own
    let total = UInt32(8 + sig.count + body.count)
    withUnsafeBytes(of: total.littleEndian) { d.append(contentsOf: $0) }
    return d + sig + body
}

func makeGoodNotes(pages: Int, strokeOnPage: Int, extraItem: Bool = false) throws -> Data {
    let dir = tmp.appendingPathComponent("gn-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir.appendingPathComponent("notes"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: dir.appendingPathComponent("attachments"), withIntermediateDirectories: true)
    let doc = UUID().uuidString, tid = UUID().uuidString, att = UUID().uuidString
    var events = pbRecord(pbString(1, doc) + pbBytes(30, pbString(1, doc) + pbBytes(2, lww("Lecture 4"))))
    events += pbRecord(pbString(1, tid) + pbBytes(2, pbString(1, doc) + pbString(2, tid) + pbString(4, att) + pbBytes(8, pbFloat(1, 600) + pbFloat(2, 800))))
    // Pages are appended out of order on purpose: their position strings decide the order.
    let ids = (0..<pages).map { _ in UUID().uuidString }
    for (k, pid) in ids.enumerated().reversed() {
        events += pbRecord(pbString(1, doc) + pbBytes(54, pbString(1, doc) + pbString(2, pid) + pbBytes(3, lww(tid)) + pbBytes(4, lww("p\(k)"))))
    }
    try events.write(to: dir.appendingPathComponent("index.events.pb"))
    // A template PDF.
    var box = CGRect(x: 0, y: 0, width: 300, height: 400)
    let pdfURL = dir.appendingPathComponent("attachments/\(att)")
    let ctx = CGContext(pdfURL as CFURL, mediaBox: &box, nil)!
    ctx.beginPDFPage(nil); ctx.setFillColor(CGColor(srgbRed: 0.98, green: 0.95, blue: 0.85, alpha: 1)); ctx.fill(box); ctx.endPDFPage(); ctx.closePDF()
    for (k, pid) in ids.enumerated() {
        var notes = Data()
        if k == strokeOnPage {
            let blob = try (tplStroke(start: (100, 200, 1), quads: [(150, 180, 2, 200, 200, 3), (250, 220, 2, 300, 200, 1)]) as NSData).compressed(using: .lz4) as Data
            let color = pbFloat(1, 0.2) + pbFloat(2, 0.3) + pbFloat(3, 0.9) + pbFloat(4, 1)
            notes += pbRecord(pbString(1, UUID().uuidString) + pbBytes(2, pbInt(1, 3) + pbInt(2, 5)))
            notes += pbRecord(pbBytes(7, pbString(1, UUID().uuidString) + pbBytes(2, blob) + pbBytes(4, color)))
            if extraItem { notes += pbRecord(pbBytes(12, pbString(1, "unknown"))) }
        }
        try notes.write(to: dir.appendingPathComponent("notes/\(GoodNotesImporter.uuidPlusOne(pid)!)"))
    }
    let zipURL = tmp.appendingPathComponent("gn-\(UUID().uuidString).goodnotes")
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
    p.currentDirectoryURL = dir
    p.arguments = ["-q", "-r", zipURL.path, "."]
    try p.run(); p.waitUntilExit()
    return try Data(contentsOf: zipURL)
}

test("GoodNotes: UUID+1 carry, tpl parsing, protobuf safety") {
    check(GoodNotesImporter.uuidPlusOne("6C449A29-B91A-497C-9057-0E36BBCFA8B3") == "6C449A29-B91A-497C-9057-0E36BBCFA8B4", "+1")
    check(GoodNotesImporter.uuidPlusOne("6301CDBE-6EAC-4891-B64C-56699162669F") == "6301CDBE-6EAC-4891-B64C-5669916266A0", "+1 with carry")
    check(GoodNotesImporter.uuidPlusOne("FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF") == "00000000-0000-0000-0000-000000000000", "full wrap")
    check(GoodNotesImporter.uuidPlusOne("nope") == nil, "invalid id")
    let t = tplStroke(start: (1, 2, 3), quads: [(4, 5, 6, 7, 8, 9)])
    let parsed = Tpl.parse(t)
    check(parsed?.count == 11 && parsed?[2] == .floats([1, 2, 3]), "tpl parses")
    check(Tpl.parse(t.dropLast(3)) == nil, "truncated tpl rejected")
    check(Tpl.parse(t + Data([0])) == nil, "trailing bytes rejected")
    var badSig = t; badSig[10] = UInt8(ascii: "Z")
    check(Tpl.parse(badSig) == nil, "unknown type letter rejected")
    let structs = Data("tpl\0".utf8) + Data([22, 0, 0, 0]) + Data("vA(S(uu))\0".utf8) + Data([2, 0, 0, 0, 0, 0])
    check(Tpl.parse(structs).map(Tpl.isEmpty) == true, "struct arrays parse; empty item detected")
    check(ProtoReader.fields(Data([0x0A, 0xFF, 0x01])) == nil, "overlong length rejected")
    check(ProtoReader.records(Data([0x05, 0x01])).isEmpty, "truncated record stream yields nothing")
}

test("GoodNotes: full import of a synthetic export") {
    let data = try makeGoodNotes(pages: 3, strokeOnPage: 1, extraItem: true)
    let r = try GoodNotesImporter.importNotebook(data, fallbackTitle: "x")
    check(r.notebook.title == "Lecture 4", "title from the document event")
    check(r.notebook.pages.count == 3 && r.strokes == 1, "3 pages, 1 stroke (\(r.notebook.pages.count), \(r.strokes))")
    check(r.notebook.pages.map(\.strokes.count) == [0, 1, 0], "stroke on the right page (position order)")
    check(r.skipped == [12: 1], "unknown item reported, not dropped silently (\(r.skipped))")
    let p = r.notebook.pages[1]
    check(p.pageSize == CGSize(width: 600, height: 800), "page size from the template")
    check(p.background != nil && r.notebook.assets.count == 1, "template PDF shared as one asset")
    if let s = p.strokes.first {
        check(abs(s.points.first!.x - 100) < 0.01 && abs(s.points.last!.x - 300) < 0.01, "curve endpoints kept")
        check(s.width == 6 && s.points.contains { $0.pressure > 0.99 } && s.points.contains { $0.pressure < 0.2 }, "width + thick-thin shape kept")
        check(abs(s.color.b - 0.9) < 0.001, "colour kept")
    }
    let back = try NotebookCodec.decode(NotebookCodec.encode(r.notebook))
    check(back.pages == r.notebook.pages, "imported notebook round-trips")
    do { _ = try GoodNotesImporter.importNotebook(Data("PK\u{3}\u{4}junk".utf8), fallbackTitle: "x"); check(false, "junk zip") }
    catch { check(error is GoodNotesImporter.ImportError, "junk zip → clear error") }
    do { _ = try GoodNotesImporter.importNotebook(data.prefix(data.count / 2), fallbackTitle: "x"); check(false, "half file") }
    catch { check(error is GoodNotesImporter.ImportError, "truncated export → clear error") }
    do { _ = try GoodNotesImporter.importNotebook(Data("%PDF-1.7".utf8), fallbackTitle: "x"); check(false, "pdf") }
    catch { check((error as? GoodNotesImporter.ImportError) == .notGoodNotes, "non-zip → notGoodNotes") }
}

if let sample = ProcessInfo.processInfo.environment["GOODNOTES_SAMPLE"] {
    test("GoodNotes: the user's real export") {
        let r = try GoodNotesImporter.importNotebook(Data(contentsOf: URL(fileURLWithPath: sample)), fallbackTitle: "Sample")
        check(r.notebook.pages.count == 3 && r.strokes == 32 && r.skipped.isEmpty, "real export: 3 pages, 32 strokes, nothing unsupported (\(r.strokes), \(r.skipped))")
        check(r.notebook.pages[0].strokes.isEmpty && r.notebook.pages.allSatisfy { $0.background != nil }, "cover + templates")
    }
}

print("\(passes) checks passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)
