import Foundation
import PDFKit

enum PDFText {
    /// Copies each PDF page's own text into the matching notebook page (so imported documents are
    /// searchable) and turns the PDF's table of contents into page bookmarks. Scanned PDFs without a
    /// text layer simply contribute no text.
    static func fill(_ pages: inout [Page], pdfAsset asset: UUID, data: Data) {
        guard let doc = PDFDocument(data: data) else { return }
        var byIndex: [Int: Int] = [:] // PDF page index → notebook page index
        for i in pages.indices {
            guard case .pdf(let a, let index) = pages[i].background, a == asset else { continue }
            byIndex[index] = i
            if let text = doc.page(at: index)?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                pages[i].documentText = String(text.prefix(50_000))
            }
        }
        // Table of contents → bookmarks (first entry per page wins; nesting is flattened).
        var stack: [PDFOutline] = doc.outlineRoot.map { [$0] } ?? []
        var visited = 0
        while let node = stack.popLast(), visited < 5_000 {
            visited += 1
            if let label = node.label?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty,
               let page = node.destination?.page, let idx = byIndex[doc.index(for: page)], pages[idx].bookmark == nil || pages[idx].bookmark == "" {
                pages[idx].bookmark = String(label.prefix(200))
            }
            for c in (0..<node.numberOfChildren).reversed() { if let child = node.child(at: c) { stack.append(child) } }
        }
    }
}

/// Text-aware tools for imported PDF pages, using the PDF's own text layer.
final class PDFTextLayer {
    private var docs: [UUID: PDFDocument] = [:]
    private let assets: () -> [UUID: Data]

    init(assets: @escaping () -> [UUID: Data]) { self.assets = assets }

    private func document(_ asset: UUID) -> PDFDocument? {
        if let d = docs[asset] { return d }
        guard let data = assets()[asset], let d = PDFDocument(data: data) else { return nil }
        docs[asset] = d
        return d
    }

    /// Text lines on a notebook page, in page coordinates (y down). Empty for non-PDF or rotated pages.
    func lines(on page: Page, in area: CGRect) -> [CGRect] {
        guard case .pdf(let asset, let index) = page.background, let doc = document(asset), let pg = doc.page(at: index),
              pg.rotation % 360 == 0 else { return [] }
        let crop = pg.bounds(for: .cropBox)
        guard crop.width > 0, crop.height > 0 else { return [] }
        let s = page.pageSize.width / crop.width
        // Page area → PDF space (y up).
        let pdfArea = CGRect(x: crop.minX + area.minX / s, y: crop.minY + (page.pageSize.height - area.maxY) / s,
                             width: area.width / s, height: area.height / s)
        guard let sel = pg.selection(for: pdfArea) else { return [] }
        return sel.selectionsByLine().compactMap { line -> CGRect? in
            let b = line.bounds(for: pg)
            guard b.width > 1, b.height > 1, !(line.string ?? "").trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            return CGRect(x: (b.minX - crop.minX) * s, y: page.pageSize.height - (b.maxY - crop.minY) * s,
                          width: b.width * s, height: b.height * s)
        }
    }

    /// Bounds of the word at a page point (page coordinates), or nil between words.
    func word(at p: CGPoint, on page: Page) -> CGRect? {
        guard case .pdf(let asset, let index) = page.background, let doc = document(asset), let pg = doc.page(at: index),
              pg.rotation % 360 == 0 else { return nil }
        let crop = pg.bounds(for: .cropBox)
        let s = page.pageSize.width / max(crop.width, 1)
        let pdfPoint = CGPoint(x: crop.minX + p.x / s, y: crop.minY + (page.pageSize.height - p.y) / s)
        guard let sel = pg.selectionForWord(at: pdfPoint), let str = sel.string,
              str.rangeOfCharacter(from: .alphanumerics) != nil else { return nil }
        let b = sel.bounds(for: pg)
        guard b.width > 0, b.width < crop.width * 0.6 else { return nil } // not a whole line or column
        return CGRect(x: (b.minX - crop.minX) * s, y: page.pageSize.height - (b.maxY - crop.minY) * s, width: b.width * s, height: b.height * s)
    }

    /// Turns a roughly drawn highlighter stroke over PDF text into clean highlights on the lines it
    /// covers. Returns nil when the stroke isn't over text (it stays as drawn).
    func snapHighlight(_ stroke: Stroke, on page: Page) -> [Stroke]? {
        guard stroke.kind == .highlighter, stroke.points.count >= 2 else { return nil }
        let b = stroke.bounds
        // Only mostly-horizontal swipes: a scribbled highlight over a figure stays freehand.
        guard b.width > b.height * 1.5 else { return nil }
        let candidates = lines(on: page, in: b)
        // A line counts when the swipe passes through its middle band.
        let core = b.insetBy(dx: 0, dy: CGFloat(stroke.width) * 0.3)
        let hits = candidates.filter { l in l.midY >= core.minY - l.height * 0.3 && l.midY <= core.maxY + l.height * 0.3 }
        guard !hits.isEmpty else { return nil }
        let first = stroke.points.first!, last = stroke.points.last!
        let x0 = CGFloat(min(first.x, last.x)), x1 = CGFloat(max(first.x, last.x))
        return hits.compactMap { l in
            // Cover the part of the line under the swipe, widened to whole words at both ends.
            var a = max(l.minX, x0), z = min(l.maxX, x1)
            if let w = word(at: CGPoint(x: a + 1, y: l.midY), on: page) { a = min(a, w.minX) }
            if let w = word(at: CGPoint(x: z - 1, y: l.midY), on: page) { z = max(z, w.maxX) }
            // The stroke's round caps reach half its width past each end: pull the ends in so the
            // highlight starts and stops at the words, not over the neighbouring ones.
            let w = Float(max(l.height * 1.05, 6))
            let cap = CGFloat(w) / 2 - 1.5
            a += cap
            z -= cap
            if z < a { let m = (a + z) / 2; a = m; z = m } // a single short word: a dot-length highlight
            let y = Float(l.midY)
            return Stroke(kind: .highlighter, color: stroke.color, width: w,
                          points: [InkPoint(x: Float(a), y: y, pressure: 0.5, time: 0), InkPoint(x: Float(z), y: y, pressure: 0.5, time: 0.1)])
        }
    }
}
