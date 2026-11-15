import AppKit

// Draws the 1024px app icon: a rounded paper tile with a single pressure-shaped ink stroke.
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
let size: CGFloat = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
let shape = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)
NSShadow().apply {
    $0.shadowColor = NSColor.black.withAlphaComponent(0.25)
    $0.shadowBlurRadius = 24
    $0.shadowOffset = NSSize(width: 0, height: -10)
}
NSGradient(colors: [NSColor(srgbRed: 1, green: 0.99, blue: 0.96, alpha: 1), NSColor(srgbRed: 0.95, green: 0.93, blue: 0.88, alpha: 1)])!
    .draw(in: shape, angle: -90)
NSGraphicsContext.current?.cgContext.setShadow(offset: .zero, blur: 0)

// Faint ruled lines.
NSColor(srgbRed: 0.55, green: 0.70, blue: 0.90, alpha: 0.35).setStroke()
for i in 0..<6 {
    let y = 300 + CGFloat(i) * 90
    let l = NSBezierPath(); l.move(to: NSPoint(x: 200, y: y)); l.line(to: NSPoint(x: 824, y: y)); l.lineWidth = 6; l.stroke()
}

// A swoosh stroke whose width follows a pressure curve, filled as overlapping discs.
let ink = NSColor(srgbRed: 0.13, green: 0.27, blue: 0.72, alpha: 1)
ink.setFill()
let path = NSBezierPath()
for i in 0...400 {
    let u = CGFloat(i) / 400
    let x = 230 + u * 560
    let y = 470 + sin(u * .pi * 2.2) * 150 * (1 - u * 0.35)
    let r = 10 + 34 * sin(u * .pi)
    path.appendOval(in: NSRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r))
}
path.windingRule = .nonZero
path.fill()
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))

extension NSShadow {
    func apply(_ f: (NSShadow) -> Void) { f(self); set() }
}
