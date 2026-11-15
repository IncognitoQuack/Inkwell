import CoreGraphics
import Foundation

// Renders synthetic handwriting through the real pipeline (builder → outline → renderer) to a PNG,
// so stroke quality can be inspected without the UI. Usage: inkwell-demo out.png
let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "demo.png")

func gesture(_ kind: ToolKind, _ color: RGBA, _ width: Float, scale: Double, tablet: Bool, _ f: (Double) -> (Double, Double, Double)) -> Stroke? {
    let b = StrokeBuilder(kind: kind, color: color, width: width, scale: scale, simulatePressure: !tablet)
    var rng = SystemRandomNumberGenerator()
    let n = 160
    for i in 0..<n {
        let u = Double(i) / Double(n - 1)
        var (x, y, p) = f(u)
        // Simulated sensor jitter of ±0.6 screen px.
        x += Double.random(in: -0.6...0.6, using: &rng) / scale
        y += Double.random(in: -0.6...0.6, using: &rng) / scale
        if i == n - 1 { return b.finish(x: x, y: y, pressure: p, timestamp: u * 0.9) }
        b.add(x: x, y: y, pressure: p, timestamp: u * 0.9)
    }
    return nil
}

var page = Page(style: .ruled, paper: .white, size: .a4)
let ink = RGBA(0.11, 0.15, 0.32)
// Pressure-varying loops (tablet).
page.strokes.append(gesture(.pen, ink, 3.2, scale: 1, tablet: true) { u in
    (90 + u * 420, 150 + sin(u * .pi * 8) * 22 + cos(u * .pi * 3) * 4, 0.15 + 0.85 * sin(u * .pi))
}!)
// Spiral with mouse-simulated pressure.
page.strokes.append(gesture(.pen, RGBA(0.80, 0.18, 0.22), 2.4, scale: 2, tablet: false) { u in
    let a = u * .pi * 7, r = 8 + u * 60
    return (180 + cos(a) * r, 320 + sin(a) * r, 0.5)
}!)
// Sharp zig-zag: tests hairpin turns.
page.strokes.append(gesture(.pen, ink, 4, scale: 1, tablet: true) { u in
    let tooth = (u * 10).truncatingRemainder(dividingBy: 1)
    return (300 + u * 240, 290 + (tooth < 0.5 ? tooth : 1 - tooth) * 120, 0.9)
}!)
// Highlighter over a line of "text".
page.strokes.append(gesture(.pen, ink, 1.6, scale: 1, tablet: true) { u in
    (90 + u * 400, 488 + sin(u * .pi * 30) * 6, 0.7)
}!)
page.strokes.append(gesture(.highlighter, RGBA(1.0, 0.86, 0.10, 0.45), 18, scale: 1, tablet: true) { u in
    (80 + u * 420, 490 + u * 2, 0.5)
}!)
// Dots and a fast flick.
for i in 0..<5 {
    let b = StrokeBuilder(kind: .pen, color: ink, width: Float(2 + i), scale: 1, simulatePressure: false)
    page.strokes.append(b.finish(x: 100 + Double(i) * 30, y: 600, pressure: 0.6, timestamp: 0)!)
}
page.strokes.append(gesture(.pen, RGBA(0.10, 0.45, 0.30), 3, scale: 1, tablet: true) { u in
    (260 + u * 260, 640 - u * u * 90, 1 - u * 0.9)
}!)

guard let img = PageRenderer.image(of: page, maxSide: 2400) else { fatalError("render failed") }
try PageRenderer.writePNG(img, to: out)
var nb = Notebook(title: "Demo")
nb.pages = [page]
try PageRenderer.exportPDF(nb, to: out.deletingPathExtension().appendingPathExtension("pdf"))
print("wrote \(out.path) (+ .pdf)")
