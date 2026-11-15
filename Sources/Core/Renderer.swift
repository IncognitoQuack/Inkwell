import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Decoded images and PDF documents for a notebook's assets, shared across threads.
final class AssetCache {
    private var data: [UUID: Data]
    private var images: [UUID: CGImage] = [:]
    private var pdfs: [UUID: CGPDFDocument] = [:]
    private let lock = NSLock()

    init(assets: [UUID: Data] = [:]) { data = assets }

    func update(_ assets: [UUID: Data]) {
        lock.lock(); defer { lock.unlock() }
        for id in data.keys where assets[id] == nil { images[id] = nil; pdfs[id] = nil }
        data = assets
    }

    func image(_ id: UUID) -> CGImage? {
        lock.lock(); defer { lock.unlock() }
        if let i = images[id] { return i }
        guard let d = data[id], let src = CGImageSourceCreateWithData(d as CFData, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { return nil }
        images[id] = img
        return img
    }

    func pdf(_ id: UUID) -> CGPDFDocument? {
        lock.lock(); defer { lock.unlock() }
        if let p = pdfs[id] { return p }
        guard let d = data[id], let provider = CGDataProvider(data: d as CFData), let doc = CGPDFDocument(provider) else { return nil }
        if doc.isEncrypted && !doc.isUnlocked { _ = doc.unlockWithPassword("") }
        pdfs[id] = doc
        return doc
    }
}

/// Draws pages with Core Graphics. The canvas, thumbnails, search indexing and export all use this,
/// so what you see is exactly what you export. Contexts are expected to be top-left origin (y down).
///
/// Layer order: background → images → highlighter → typed text → pen ink. Pen ink sits on top so
/// you can annotate typed text and images; highlighter sits under text like on paper.
enum PageRenderer {
    /// Caches outline paths by stroke identity (id + position + point count).
    final class PathCache {
        private struct Key: Hashable { let id: UUID; let x: CGFloat; let y: CGFloat; let count: Int }
        private var paths: [Key: CGPath] = [:]

        func path(for s: Stroke) -> CGPath {
            let key = Key(id: s.id, x: s.bounds.minX, y: s.bounds.minY, count: s.points.count)
            if let p = paths[key] { return p }
            let p = InkGeometry.outlinePath(for: s)
            if paths.count > 20_000 { paths.removeAll(keepingCapacity: true) }
            paths[key] = p
            return p
        }

        func prune(keeping ids: Set<UUID>) {
            paths = paths.filter { ids.contains($0.key.id) }
        }
    }

    struct Options {
        var clip: CGRect?
        var cache: PathCache?
        var hiddenStrokes: Set<UUID> = []
        var hiddenElements: Set<UUID> = []
        /// Canvas only: draw subtle markers for link areas.
        var linkHints = false
        /// Skip the template/PDF background (used when the caller supplies its own).
        var skipBackground = false
        /// Study tapes currently peeled back (shown as an outline instead of covering).
        var revealedTapes: Set<UUID> = []
        /// Audio playback: strokes from this recording written after `time` are drawn faint.
        var replay: (recording: UUID, time: Double)?

        init(clip: CGRect? = nil, cache: PathCache? = nil) {
            self.clip = clip
            self.cache = cache
        }
    }

    // MARK: Whole page

    static func draw(_ page: Page, in ctx: CGContext, assets: AssetCache?, options o: Options = Options()) {
        ctx.saveGState()
        ctx.clip(to: page.rect)
        if !o.skipBackground { drawBackground(page, in: ctx, clip: o.clip, assets: assets) }
        drawImages(page, in: ctx, assets: assets, options: o)
        drawStrokes(page.strokes, kind: .highlighter, in: ctx, options: o)
        drawTexts(page, in: ctx, options: o)
        drawStrokes(page.strokes, kind: .pen, in: ctx, options: o)
        drawTapes(page, in: ctx, options: o)
        if o.linkHints { drawLinkHints(page, in: ctx, options: o) }
        ctx.restoreGState()
    }

    /// Tapes cover everything below them; revealed ones show only a dashed outline.
    static func drawTapes(_ page: Page, in ctx: CGContext, options o: Options) {
        for e in page.elements where !o.hiddenElements.contains(e.id) {
            guard case .tape(let color, _) = e.content else { continue }
            if let clip = o.clip, !clip.intersects(e.frame.insetBy(dx: -2, dy: -2)) { continue }
            ctx.saveGState()
            let path = CGPath(roundedRect: e.frame, cornerWidth: 3, cornerHeight: 3, transform: nil)
            if o.revealedTapes.contains(e.id) {
                ctx.setStrokeColor(color.opaque.cgColor)
                ctx.setLineWidth(1.5)
                ctx.setLineDash(phase: 0, lengths: [5, 4])
                ctx.addPath(path)
                ctx.strokePath()
            } else {
                ctx.setFillColor(color.opaque.cgColor)
                ctx.addPath(path)
                ctx.fillPath()
                // Paper-tape texture: faint diagonal stripes.
                ctx.addPath(path)
                ctx.clip()
                ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.18))
                ctx.setLineWidth(3)
                var x = e.frame.minX - e.frame.height
                while x < e.frame.maxX {
                    ctx.move(to: CGPoint(x: x, y: e.frame.maxY))
                    ctx.addLine(to: CGPoint(x: x + e.frame.height, y: e.frame.minY))
                    x += 10
                }
                ctx.strokePath()
            }
            ctx.restoreGState()
        }
    }

    // MARK: Background

    static func drawBackground(_ page: Page, in ctx: CGContext, clip: CGRect? = nil, assets: AssetCache?) {
        let rect = page.rect
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setFillColor(page.paper.rgba.cgColor)
        ctx.fill(rect)
        if case .pdf(let asset, let index) = page.background {
            if let doc = assets?.pdf(asset) { drawPDFPage(doc, index: index, in: rect, ctx: ctx) }
            return
        }
        let area = (clip ?? rect).intersection(rect)
        guard !area.isNull else { return }
        switch page.style {
        case .blank:
            break
        case .ruled:
            let spacing: CGFloat = 28, top: CGFloat = 96
            ctx.setStrokeColor(CGColor(srgbRed: 0.60, green: 0.74, blue: 0.90, alpha: 0.55))
            ctx.setLineWidth(0.6)
            var y = top
            while y < rect.maxY - 24 {
                if y >= area.minY - 1 && y <= area.maxY + 1 {
                    ctx.move(to: CGPoint(x: rect.minX, y: y)); ctx.addLine(to: CGPoint(x: rect.maxX, y: y))
                }
                y += spacing
            }
            ctx.strokePath()
            ctx.setStrokeColor(CGColor(srgbRed: 0.93, green: 0.45, blue: 0.45, alpha: 0.45))
            ctx.move(to: CGPoint(x: 72, y: rect.minY)); ctx.addLine(to: CGPoint(x: 72, y: rect.maxY))
            ctx.strokePath()
        case .grid:
            let spacing: CGFloat = 20
            ctx.setStrokeColor(CGColor(srgbRed: 0.55, green: 0.62, blue: 0.72, alpha: 0.28))
            ctx.setLineWidth(0.5)
            var x = rect.minX + spacing
            while x < rect.maxX { if x >= area.minX - 1 && x <= area.maxX + 1 { ctx.move(to: CGPoint(x: x, y: rect.minY)); ctx.addLine(to: CGPoint(x: x, y: rect.maxY)) }; x += spacing }
            var y = rect.minY + spacing
            while y < rect.maxY { if y >= area.minY - 1 && y <= area.maxY + 1 { ctx.move(to: CGPoint(x: rect.minX, y: y)); ctx.addLine(to: CGPoint(x: rect.maxX, y: y)) }; y += spacing }
            ctx.strokePath()
        case .dotted:
            let spacing: CGFloat = 20, r: CGFloat = 0.9
            ctx.setFillColor(CGColor(srgbRed: 0.45, green: 0.50, blue: 0.58, alpha: 0.45))
            var y = rect.minY + spacing
            while y < rect.maxY {
                if y >= area.minY - r && y <= area.maxY + r {
                    var x = rect.minX + spacing
                    while x < rect.maxX {
                        if x >= area.minX - r && x <= area.maxX + r { ctx.addEllipse(in: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r)) }
                        x += spacing
                    }
                }
                y += spacing
            }
            ctx.fillPath()
        }
    }

    /// Draws a PDF page (vector) into `rect` of a y-down context, honouring the page's rotation.
    static func drawPDFPage(_ doc: CGPDFDocument, index: Int, in rect: CGRect, ctx: CGContext) {
        guard index >= 0, index < doc.numberOfPages, let pg = doc.page(at: index + 1) else { return }
        ctx.saveGState()
        ctx.clip(to: rect)
        ctx.translateBy(x: rect.minX, y: rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        // CGPDFPage's drawing transform only ever scales DOWN, so place the page at its own size
        // (handling /Rotate) and then scale it to fill the target, centred, aspect kept.
        let natural = displaySize(of: pg)
        if natural.width > 0, natural.height > 0 {
            let s = min(rect.width / natural.width, rect.height / natural.height)
            ctx.translateBy(x: (rect.width - natural.width * s) / 2, y: (rect.height - natural.height * s) / 2)
            ctx.scaleBy(x: s, y: s)
        }
        ctx.concatenate(pg.getDrawingTransform(.cropBox, rect: CGRect(origin: .zero, size: natural), rotate: 0, preserveAspectRatio: true))
        ctx.interpolationQuality = .high
        ctx.drawPDFPage(pg)
        ctx.restoreGState()
    }

    /// Display size of a PDF page (crop box, with /Rotate applied).
    static func displaySize(of pg: CGPDFPage) -> CGSize {
        let box = pg.getBoxRect(.cropBox)
        let quarter = ((pg.rotationAngle % 360) + 360) % 360
        return (quarter == 90 || quarter == 270) ? CGSize(width: box.height, height: box.width) : box.size
    }

    // MARK: Ink

    static func drawStrokes(_ strokes: [Stroke], kind: ToolKind, in ctx: CGContext, options o: Options) {
        ctx.saveGState()
        ctx.setBlendMode(kind == .highlighter ? .multiply : .normal)
        for s in strokes where s.kind == kind && !o.hiddenStrokes.contains(s.id) {
            if let clip = o.clip, !clip.intersects(s.bounds) { continue }
            ctx.addPath(o.cache?.path(for: s) ?? InkGeometry.outlinePath(for: s))
            var color = s.color
            // Replaying a recording: ink that comes later in the audio is shown faint until it's "written".
            if let r = o.replay, s.recording == r.recording, let off = s.recordingOffset, off > r.time { color.a *= 0.18 }
            ctx.setFillColor(color.cgColor)
            ctx.fillPath(using: .winding)
        }
        ctx.restoreGState()
    }

    /// Back-compat helper: both ink layers in order.
    static func drawStrokes(_ strokes: [Stroke], in ctx: CGContext, clip: CGRect? = nil, cache: PathCache? = nil, hidden: Set<UUID> = []) {
        var o = Options(clip: clip, cache: cache)
        o.hiddenStrokes = hidden
        drawStrokes(strokes, kind: .highlighter, in: ctx, options: o)
        drawStrokes(strokes, kind: .pen, in: ctx, options: o)
    }

    // MARK: Images

    static func drawImages(_ page: Page, in ctx: CGContext, assets: AssetCache?, options o: Options) {
        for e in page.elements where !o.hiddenElements.contains(e.id) {
            guard let asset = e.imageAsset else { continue }
            if let clip = o.clip, !clip.intersects(e.frame) { continue }
            ctx.saveGState()
            if let img = assets?.image(asset) {
                ctx.translateBy(x: e.frame.minX, y: e.frame.maxY)
                ctx.scaleBy(x: 1, y: -1)
                ctx.interpolationQuality = .high
                ctx.draw(img, in: CGRect(origin: .zero, size: e.frame.size))
            } else {
                // Missing asset: a neutral placeholder rather than nothing, so the element can still be found and removed.
                ctx.setFillColor(CGColor(gray: 0.9, alpha: 1))
                ctx.fill(e.frame)
                ctx.setStrokeColor(CGColor(gray: 0.6, alpha: 1))
                ctx.stroke(e.frame.insetBy(dx: 0.5, dy: 0.5))
            }
            ctx.restoreGState()
        }
    }

    // MARK: Text

    static func font(for style: TextStyle) -> CTFont {
        let size = CGFloat(style.size)
        let base: CTFont
        switch style.font {
        case .sans: base = CTFontCreateUIFontForLanguage(.system, size, nil) ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
        case .serif: base = CTFontCreateWithName("Georgia" as CFString, size, nil)
        case .mono: base = CTFontCreateWithName("Menlo-Regular" as CFString, size, nil)
        case .hand: base = CTFontCreateWithName("Noteworthy-Light" as CFString, size, nil)
        }
        var traits: CTFontSymbolicTraits = []
        if style.bold { traits.insert(.traitBold) }
        if style.italic { traits.insert(.traitItalic) }
        guard !traits.isEmpty else { return base }
        return CTFontCreateCopyWithSymbolicTraits(base, size, nil, traits, traits) ?? base
    }

    static let linkColor = CGColor(srgbRed: 0.10, green: 0.42, blue: 0.95, alpha: 1)

    /// URLs found in typed text, with their ranges.
    static func detectLinks(in text: String) -> [(NSRange, URL)] {
        guard !text.isEmpty, let det = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return [] }
        return det.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { m in m.url.map { (m.range, $0) } }
    }

    static func attributedText(_ text: String, style: TextStyle) -> NSAttributedString {
        let font = font(for: style)
        var align: CTTextAlignment
        switch style.alignment {
        case .left: align = .left
        case .center: align = .center
        case .right: align = .right
        }
        let para = withUnsafeBytes(of: &align) { raw in
            var setting = CTParagraphStyleSetting(spec: .alignment, valueSize: MemoryLayout<CTTextAlignment>.size, value: raw.baseAddress!)
            return CTParagraphStyleCreate(&setting, 1)
        }
        let s = NSMutableAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): style.color.cgColor,
            NSAttributedString.Key(kCTParagraphStyleAttributeName as String): para,
        ])
        for (range, _) in detectLinks(in: text) {
            s.addAttribute(NSAttributedString.Key(kCTForegroundColorAttributeName as String), value: linkColor, range: range)
            s.addAttribute(NSAttributedString.Key(kCTUnderlineStyleAttributeName as String), value: CTUnderlineStyle.single.rawValue, range: range)
        }
        return s
    }

    /// Height a text box needs at a given width (at least one line, even when empty).
    static func textHeight(_ text: String, style: TextStyle, width: CGFloat) -> CGFloat {
        let sample = text.isEmpty || text.hasSuffix("\n") ? text + "Ag" : text
        let fs = CTFramesetterCreateWithAttributedString(attributedText(sample, style: style))
        let size = CTFramesetterSuggestFrameSizeWithConstraints(fs, CFRange(location: 0, length: 0), nil,
                                                                CGSize(width: max(width, 4), height: .greatestFiniteMagnitude), nil)
        return ceil(size.height) + 2
    }

    static func drawTexts(_ page: Page, in ctx: CGContext, options o: Options) {
        for e in page.elements where !o.hiddenElements.contains(e.id) {
            guard case .text(let text, let style) = e.content else { continue }
            if let clip = o.clip, !clip.intersects(e.frame.insetBy(dx: -4, dy: -4)) { continue }
            drawText(text, style: style, in: e.frame, ctx: ctx)
        }
    }

    static func drawText(_ text: String, style: TextStyle, in frame: CGRect, ctx: CGContext) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        if let hl = style.highlight {
            ctx.setFillColor(hl.cgColor)
            ctx.addPath(CGPath(roundedRect: frame.insetBy(dx: -4, dy: -2), cornerWidth: 4, cornerHeight: 4, transform: nil))
            ctx.fillPath()
        }
        guard !text.isEmpty, let frameRef = ctFrame(text, style: style, frame: frame) else { return }
        ctx.textMatrix = .identity
        ctx.translateBy(x: frame.minX, y: frame.maxY)
        ctx.scaleBy(x: 1, y: -1)
        CTFrameDraw(frameRef, ctx)
    }

    /// CoreText frame laid out in a y-up box whose origin is the text box's bottom-left.
    private static func ctFrame(_ text: String, style: TextStyle, frame: CGRect) -> CTFrame? {
        let fs = CTFramesetterCreateWithAttributedString(attributedText(text, style: style))
        let h = max(frame.height, textHeight(text, style: style, width: frame.width))
        let path = CGPath(rect: CGRect(x: 0, y: frame.height - h, width: frame.width, height: h), transform: nil)
        return CTFramesetterCreateFrame(fs, CFRange(location: 0, length: 0), path, nil)
    }

    /// Clickable areas of a page, in page coordinates: links inside typed text (per line of the link),
    /// plus whole elements that carry a link.
    static func linkAreas(_ page: Page) -> [(CGRect, URL)] {
        var out: [(CGRect, URL)] = []
        for e in page.elements {
            if let l = e.link, let u = URL(string: l) { out.append((e.frame, u)) }
            guard case .text(let text, let style) = e.content else { continue }
            let links = detectLinks(in: text)
            guard !links.isEmpty, let f = ctFrame(text, style: style, frame: e.frame) else { continue }
            let lines = CTFrameGetLines(f) as? [CTLine] ?? []
            var origins = [CGPoint](repeating: .zero, count: lines.count)
            CTFrameGetLineOrigins(f, CFRange(location: 0, length: 0), &origins)
            for (range, url) in links {
                for (i, line) in lines.enumerated() {
                    let lr = CTLineGetStringRange(line)
                    let start = max(range.location, lr.location), end = min(range.location + range.length, lr.location + lr.length)
                    guard end > start else { continue }
                    let x1 = CTLineGetOffsetForStringIndex(line, start, nil), x2 = CTLineGetOffsetForStringIndex(line, end, nil)
                    var ascent: CGFloat = 0, descent: CGFloat = 0
                    CTLineGetTypographicBounds(line, &ascent, &descent, nil)
                    // Convert from the y-up frame space back to page space.
                    let pathOriginY = e.frame.height - max(e.frame.height, textHeight(text, style: style, width: e.frame.width))
                    let baselineUp = origins[i].y + pathOriginY
                    let top = e.frame.maxY - (baselineUp + ascent)
                    out.append((CGRect(x: e.frame.minX + x1, y: top, width: x2 - x1, height: ascent + descent), url))
                }
            }
        }
        return out
    }

    private static func drawLinkHints(_ page: Page, in ctx: CGContext, options o: Options) {
        ctx.saveGState()
        ctx.setStrokeColor(linkColor.copy(alpha: 0.7)!)
        ctx.setLineWidth(1.2)
        ctx.setLineDash(phase: 0, lengths: [3, 3])
        for e in page.elements where e.link != nil && !o.hiddenElements.contains(e.id) {
            let f = e.frame
            ctx.move(to: CGPoint(x: f.minX, y: f.maxY + 2))
            ctx.addLine(to: CGPoint(x: f.maxX, y: f.maxY + 2))
        }
        ctx.strokePath()
        ctx.restoreGState()
    }

    // MARK: Bitmaps

    static func image(of page: Page, maxSide: CGFloat, assets: AssetCache? = nil, inkOnly: Bool = false,
                      revealedTapes: Set<UUID> = []) -> CGImage? {
        let size = page.pageSize
        let scale = maxSide / max(size.width, size.height)
        let w = Int((size.width * scale).rounded()), h = Int((size.height * scale).rounded())
        guard w > 0, h > 0, w < 20_000, h < 20_000,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: scale, y: -scale) // top-left origin
        ctx.interpolationQuality = .high
        if inkOnly {
            // For handwriting recognition: ink alone on white, no ruled lines or backgrounds to confuse it.
            ctx.setFillColor(.white)
            ctx.fill(page.rect)
            var o = Options()
            o.hiddenElements = Set(page.elements.map(\.id))
            drawStrokes(page.strokes, kind: .pen, in: ctx, options: o)
        } else {
            var o = Options()
            o.revealedTapes = revealedTapes
            draw(page, in: ctx, assets: assets, options: o)
        }
        return ctx.makeImage()
    }

    static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
    }

    // MARK: PDF export

    /// Vector PDF, one PDF page per notebook page at its own size, with clickable links.
    /// `pages` limits the export to those indices (e.g. the current page).
    static func exportPDF(_ notebook: Notebook, pages: [Int]? = nil, to url: URL) throws {
        let assets = AssetCache(assets: notebook.assets)
        let chosen = (pages ?? Array(notebook.pages.indices)).filter { notebook.pages.indices.contains($0) }
        guard !chosen.isEmpty else { throw CocoaError(.fileWriteUnknown) }
        var box = notebook.pages[chosen[0]].rect
        let info: [CFString: Any] = [kCGPDFContextTitle: notebook.title, kCGPDFContextCreator: "Inkwell"]
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, info as CFDictionary) else {
            throw CocoaError(.fileWriteNoPermission)
        }
        for i in chosen {
            let page = notebook.pages[i]
            var media = page.rect
            let pageInfo = [kCGPDFContextMediaBox: Data(bytes: &media, count: MemoryLayout<CGRect>.size)] as CFDictionary
            ctx.beginPDFPage(pageInfo)
            ctx.saveGState()
            ctx.translateBy(x: 0, y: page.rect.height)
            ctx.scaleBy(x: 1, y: -1)
            draw(page, in: ctx, assets: assets)
            ctx.restoreGState()
            // Link annotations use PDF space (y up).
            for (r, link) in linkAreas(page) {
                let pdfRect = CGRect(x: r.minX, y: page.rect.height - r.maxY, width: r.width, height: r.height)
                ctx.setURL(link as CFURL, for: pdfRect)
            }
            ctx.endPDFPage()
        }
        ctx.closePDF()
    }
}
