import AppKit
import QuartzCore

/// One notebook page. Committed content is drawn by `draw(_:)` (vector, sharp at any zoom); the stroke in
/// progress lives in `live`, and lasso/selection/laser visuals in `overlay`, so none of them forces a
/// page redraw.
final class PageView: NSView {
    var page: Page
    let cache = PageRenderer.PathCache()
    let live = LiveInk()
    let overlay = CALayer()
    weak var canvas: CanvasView?
    var assets: AssetCache?

    /// Strokes/elements temporarily not drawn: being erased, lifted into the selection, or being edited.
    var hiddenStrokes: Set<UUID> = [] { didSet { invalidate(strokes: hiddenStrokes.symmetricDifference(oldValue)) } }
    var hiddenElements: Set<UUID> = [] { didSet { invalidate(elements: hiddenElements.symmetricDifference(oldValue)) } }

    init(page: Page) {
        self.page = page
        super.init(frame: page.rect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.16
        layer?.shadowRadius = 6
        layer?.shadowOffset = CGSize(width: 0, height: -1.5)
        layer?.masksToBounds = false
        overlay.anchorPoint = .zero
        overlay.frame = bounds
        overlay.actions = ["sublayers": NSNull(), "position": NSNull(), "bounds": NSNull()]
        layer?.addSublayer(live.layer)
        layer?.addSublayer(overlay)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        overlay.frame = bounds
        layer?.shadowPath = CGPath(rect: bounds, transform: nil)
    }

    private func invalidate(strokes ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        canvas?.zoomWriter?.pageChanged(page.id)
        let area = page.strokes.lazy.filter { ids.contains($0.id) }.map(\.bounds).reduce(CGRect.null) { $0.union($1) }
        if !area.isNull { setNeedsDisplay(area.insetBy(dx: -2, dy: -2)) }
    }

    private func invalidate(elements ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        canvas?.zoomWriter?.pageChanged(page.id)
        let area = page.elements.lazy.filter { ids.contains($0.id) }.map(\.frame).reduce(CGRect.null) { $0.union($1) }
        if !area.isNull { setNeedsDisplay(area.insetBy(dx: -6, dy: -6)) }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        var o = PageRenderer.Options(clip: dirtyRect, cache: cache)
        o.hiddenStrokes = hiddenStrokes
        o.hiddenElements = hiddenElements
        o.linkHints = true
        o.revealedTapes = canvas?.revealedTapes ?? []
        o.replay = canvas?.replay
        if case .pdf = page.background, let img = pdfRaster() {
            // Imported PDF pages draw from a cached bitmap at screen resolution: complex PDFs would
            // otherwise re-render on every stroke.
            ctx.saveGState()
            ctx.setFillColor(.white)
            ctx.fill(bounds)
            ctx.translateBy(x: 0, y: bounds.height)
            ctx.scaleBy(x: 1, y: -1)
            ctx.interpolationQuality = .high
            ctx.draw(img, in: CGRect(origin: .zero, size: bounds.size))
            ctx.restoreGState()
            o.skipBackground = true
        }
        PageRenderer.draw(page, in: ctx, assets: assets, options: o)
    }

    // MARK: PDF raster cache

    private var raster: (image: CGImage, scale: CGFloat, key: PageBackground)?
    private var rasterInFlight: CGFloat?
    private static let rasterQueue = DispatchQueue(label: "inkwell.pdf.raster", qos: .userInitiated)
    private static var recent: [ObjectIdentifier] = []
    private static var live: [ObjectIdentifier: () -> Void] = [:]

    /// Returns the cached raster (possibly at an older scale while a sharper one renders).
    private func pdfRaster() -> CGImage? {
        guard case .pdf(let asset, let index) = page.background, let assets else { return nil }
        let mag = canvas?.scrollView.magnification ?? 1
        let want = ((window?.backingScaleFactor ?? 2) * mag * 2).rounded() / 2 // half-step buckets
        let target = want.clamped(1, 6)
        if let r = raster, r.key == page.background, r.scale >= target * 0.99 || rasterInFlight != nil {
            touchLRU()
            return r.image
        }
        if rasterInFlight != target {
            rasterInFlight = target
            let size = page.pageSize
            let key = page.background!
            Self.rasterQueue.async { [weak self] in
                guard let doc = assets.pdf(asset) else { return }
                let w = Int(size.width * target), h = Int(size.height * target)
                guard w > 0, h > 0, w * h < 40_000_000, // ≤160 MB; larger pages fall back to vector drawing
                      let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return }
                ctx.setFillColor(.white)
                ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
                ctx.translateBy(x: 0, y: CGFloat(h))
                ctx.scaleBy(x: target, y: -target)
                PageRenderer.drawPDFPage(doc, index: index, in: CGRect(origin: .zero, size: size), ctx: ctx)
                let img = ctx.makeImage()
                DispatchQueue.main.async {
                    guard let self, let img else { return }
                    self.rasterInFlight = nil
                    if self.page.background == key { self.raster = (img, target, key); self.touchLRU(); self.needsDisplay = true }
                }
            }
        }
        return raster?.key == page.background ? raster?.image : nil
    }

    /// Keeps at most a handful of page rasters in memory; the least recently drawn are dropped.
    private func touchLRU() {
        let me = ObjectIdentifier(self)
        Self.recent.removeAll { $0 == me }
        Self.recent.append(me)
        Self.live[me] = { [weak self] in self?.raster = nil }
        while Self.recent.count > 8 {
            let old = Self.recent.removeFirst()
            Self.live.removeValue(forKey: old)?()
        }
    }

    deinit {
        let me = ObjectIdentifier(self)
        DispatchQueue.main.async {
            PageView.recent.removeAll { $0 == me }
            PageView.live[me] = nil
        }
    }

    // Every pointer event is handled by the canvas, which owns gesture state across pages.
    override func mouseDown(with e: NSEvent) { canvas?.pointerDown(e, on: self) }
    override func mouseDragged(with e: NSEvent) { canvas?.pointerDragged(e) }
    override func mouseUp(with e: NSEvent) { canvas?.pointerUp(e) }
    override func rightMouseDown(with e: NSEvent) { canvas?.pointerDown(e, on: self) }
    override func rightMouseDragged(with e: NSEvent) { canvas?.pointerDragged(e) }
    override func rightMouseUp(with e: NSEvent) { canvas?.pointerUp(e) }
    override func otherMouseDown(with e: NSEvent) { canvas?.pointerDown(e, on: self) }
    override func otherMouseDragged(with e: NSEvent) { canvas?.pointerDragged(e) }
    override func otherMouseUp(with e: NSEvent) { canvas?.pointerUp(e) }

    override func resetCursorRects() {
        if let c = canvas?.currentCursor() { addCursorRect(visibleRect, cursor: c) }
    }
}
