import AppKit
import UniformTypeIdentifiers

// MARK: - Text editing

/// Edits one text box in place with an NSTextView laid over the page. The page hides the element
/// while editing, and the result is committed as one undoable change.
final class TextEditor: NSObject, NSTextViewDelegate {
    let pageView: PageView
    let elementID: UUID
    let isNew: Bool
    let textView: NSTextView
    var style: TextStyle
    private weak var canvas: CanvasView?
    /// Typing has its own undo history while the box is open: the notebook's undo manager uses explicit
    /// groups (one step per action), and NSTextView registers per-keystroke undo outside any group, which
    /// AppKit rejects with an exception. Committing the box records a single notebook undo step.
    private let typingUndo = UndoManager()

    init(element: PageElement, isNew: Bool, on pv: PageView, canvas: CanvasView) {
        pageView = pv
        elementID = element.id
        self.isNew = isNew
        self.canvas = canvas
        style = element.textStyle ?? TextStyle()
        textView = NSTextView(frame: element.frame)
        super.init()
        textView.drawsBackground = false
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isContinuousSpellCheckingEnabled = true
        textView.isAutomaticSpellingCorrectionEnabled = false // never change words behind your back
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.delegate = self
        textView.focusRingType = .none
        textView.wantsLayer = true
        textView.layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.6).cgColor
        textView.layer?.borderWidth = 1
        applyStyle(style)
        textView.string = element.text ?? ""
        refit()
    }

    func applyStyle(_ st: TextStyle) {
        style = st
        let font = PageRenderer.font(for: st) as NSFont
        let para = NSMutableParagraphStyle()
        para.alignment = st.alignment == .center ? .center : st.alignment == .right ? .right : .left
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: st.color.nsColor, .paragraphStyle: para]
        textView.typingAttributes = attrs
        textView.textStorage?.setAttributes(attrs, range: NSRange(location: 0, length: textView.textStorage?.length ?? 0))
        textView.insertionPointColor = st.color.nsColor
        textView.backgroundColor = st.highlight?.nsColor ?? .clear
        textView.drawsBackground = st.highlight != nil
        refit()
    }

    func textDidChange(_ notification: Notification) { refit() }

    func undoManager(for view: NSTextView) -> UndoManager? { typingUndo }

    /// Grows the box to fit its text (CoreText measurement, same as rendering).
    private func refit() {
        var f = textView.frame
        f.size.height = PageRenderer.textHeight(textView.string, style: style, width: f.width)
        textView.frame = f
    }

    func textView(_ tv: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            canvas?.endTextEditing()
            return true
        }
        return false
    }

    var element: PageElement {
        PageElement(id: elementID, frame: textView.frame, content: .text(textView.string, style),
                    link: pageView.page.elements.first { $0.id == elementID }?.link)
    }
}

extension CanvasView {
    func createTextBox(at p: CGPoint, on pv: PageView) {
        let style = tools.textStyle
        // At least 160 pt wide where possible; slide left rather than hang off the page's right edge.
        let width = min(340, max(160, pv.bounds.width - p.x - 24), pv.bounds.width - 32)
        let x = min(p.x, pv.bounds.width - width - 16).clamped(8, max(8, pv.bounds.width - width - 8))
        let h = PageRenderer.textHeight("", style: style, width: width)
        let y = (p.y - h / 2).clamped(4, max(4, pv.bounds.height - h - 4))
        let el = PageElement(frame: CGRect(x: x, y: y, width: width, height: h), content: .text("", style))
        startEditor(TextEditor(element: el, isNew: true, on: pv, canvas: self))
    }

    func beginTextEditing(_ el: PageElement, on pv: PageView) {
        guard el.text != nil else { return }
        if let st = el.textStyle, st != tools.textStyle { tools.textStyle = st } // toolbar shows this box's style
        startEditor(TextEditor(element: el, isNew: false, on: pv, canvas: self))
    }

    private func startEditor(_ ed: TextEditor) {
        endTextEditing()
        textEditor = ed
        ed.pageView.hiddenElements.insert(ed.elementID)
        ed.pageView.addSubview(ed.textView)
        window?.makeFirstResponder(ed.textView)
        ed.textView.setSelectedRange(NSRange(location: (ed.textView.string as NSString).length, length: 0))
    }

    /// Commits (or, for an empty box, discards) the text being edited.
    func endTextEditing(commit: Bool = true) {
        guard let ed = textEditor else { return }
        textEditor = nil
        ed.textView.removeFromSuperview()
        ed.pageView.hiddenElements.remove(ed.elementID)
        window?.makeFirstResponder(self)
        guard commit else { return }
        let el = ed.element
        let empty = (el.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let pid = ed.pageView.page.id
        if empty {
            if !ed.isNew { session.deleteItems(strokes: [], elements: [el.id], on: pid) }
        } else {
            session.upsertElement(el, on: pid, actionName: ed.isNew ? "Add Text" : "Edit Text")
        }
    }

    /// Text style changes from the toolbar apply to the box being edited, or to a selected text box.
    func applyTextStyle(_ st: TextStyle) {
        if let ed = textEditor {
            ed.applyStyle(st)
            return
        }
        guard let sel = selection, let id = sel.singleElement,
              var el = sel.page.page.elements.first(where: { $0.id == id }), case .text(let t, let old) = el.content, old != st else { return }
        el.content = .text(t, st)
        el.frame.size.height = PageRenderer.textHeight(t, style: st, width: el.frame.width)
        session.upsertElement(el, on: sel.page.page.id, actionName: "Text Style")
        select(strokes: [], elements: [id], on: sel.page)
    }

    // MARK: Links

    /// Opens the link under `p`, if any. Returns true when something was opened.
    @discardableResult
    func openLink(at p: CGPoint, on pv: PageView) -> Bool {
        guard let hit = PageRenderer.linkAreas(pv.page).last(where: { $0.0.insetBy(dx: -3, dy: -3).contains(p) }) else { return false }
        NSWorkspace.shared.open(hit.1)
        return true
    }

    var selectionLink: String? {
        guard let sel = selection, sel.strokes.isEmpty, sel.elements.count == 1, let id = sel.elements.first else { return nil }
        return sel.page.page.elements.first { $0.id == id }?.link
    }

    /// Attaches a link to the selection: to the element itself when one element is selected, otherwise
    /// as a clickable area covering the selected ink.
    func addLink(_ raw: String) -> Bool {
        guard let sel = selection, let url = LinkURL.normalize(raw) else { return false }
        let pid = sel.page.page.id
        if let id = sel.singleElement, var el = sel.page.page.elements.first(where: { $0.id == id }) {
            el.link = url
            session.upsertElement(el, on: pid, actionName: "Add Link")
            select(strokes: [], elements: [id], on: sel.page)
        } else {
            let el = PageElement(frame: sel.bounds.insetBy(dx: -2, dy: -2), content: .link, link: url)
            session.upsertElement(el, on: pid, actionName: "Add Link")
            select(strokes: sel.strokes, elements: sel.elements.union([el.id]), on: sel.page)
        }
        showHUD("Link added", symbol: "link")
        return true
    }

    func removeLinks() {
        guard let sel = selection else { return }
        session.editPage(sel.page.page.id, "Remove Link") { p in
            p.elements.removeAll { sel.elements.contains($0.id) && $0.content == .link }
            for i in p.elements.indices where sel.elements.contains(p.elements[i].id) { p.elements[i].link = nil }
        }
        clearSelection()
    }

    // MARK: Images and PDFs

    /// Inserts an image (downsampled and compressed) centred at `point`, or the middle of the view.
    func insertImage(_ data: Data, on target: PageView? = nil, at point: CGPoint? = nil) throws {
        guard let pv = target ?? currentPageView else { return }
        let img = try Importer.imageAsset(from: data)
        let asset = session.addAsset(img.data)
        // Retina screenshots are 2× pixels; place at the size they look on screen.
        let pointSize = CGSize(width: img.pixelSize.width / 2, height: img.pixelSize.height / 2)
        let frame = Importer.placement(for: pointSize, on: pv.page, center: point ?? visibleCenter(of: pv))
        let el = PageElement(frame: frame, content: .image(asset: asset))
        session.upsertElement(el, on: pv.page.id, actionName: "Insert Image")
        if tools.tool != .lasso { tools.tool = .lasso }
        DispatchQueue.main.async { self.select(strokes: [], elements: [el.id], on: pv) }
    }

    /// Adds a PDF's pages after the current page, ready to annotate.
    func insertPDFPages(_ data: Data, title: String) throws {
        let imported = try Importer.notebook(fromPDF: data, title: title)
        guard let (oldAsset, pdf) = imported.assets.first else { return }
        let asset = session.addAsset(pdf)
        var pages = imported.pages.map { p -> Page in
            var q = p
            if case .pdf(let a, let i) = p.background, a == oldAsset { q.background = .pdf(asset: asset, index: i) }
            return q
        }
        PDFText.fill(&pages, pdfAsset: asset, data: pdf)
        let at = min(session.currentPageIndex + 1, session.notebook.pages.count)
        let room = max(0, Notebook.maxPages - session.notebook.pages.count)
        session.editPages("Insert PDF") { $0.insert(contentsOf: pages.prefix(room), at: at) }
        DispatchQueue.main.async { self.scrollToPage(at) }
    }

    func chooseImage() {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .pdf]
        panel.allowsMultipleSelection = true
        panel.beginSheetModal(for: window) { [weak self] r in
            guard r == .OK, let self else { return }
            self.importFiles(panel.urls, on: nil, at: nil)
        }
    }

    func importFiles(_ urls: [URL], on pv: PageView?, at point: CGPoint?) {
        var failures: [String] = []
        for (i, url) in urls.enumerated() {
            do {
                let data = try Data(contentsOf: url, options: .mappedIfSafe)
                if UTType(filenameExtension: url.pathExtension)?.conforms(to: .pdf) == true {
                    try insertPDFPages(data, title: url.deletingPathExtension().lastPathComponent)
                } else {
                    let offset = CGFloat(i) * 24
                    try insertImage(data, on: pv, at: point.map { CGPoint(x: $0.x + offset, y: $0.y + offset) })
                }
            } catch {
                failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        if !failures.isEmpty, let window {
            let alert = NSAlert()
            alert.messageText = "Some files couldn’t be added."
            alert.informativeText = failures.joined(separator: "\n")
            alert.beginSheetModal(for: window)
        }
    }

    // MARK: Drag and drop

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pb = sender.draggingPasteboard
        let windowPoint = sender.draggingLocation
        let pv = pageViews.first { $0.bounds.contains($0.convert(windowPoint, from: nil)) } ?? currentPageView
        let point = pv.map { $0.convert(windowPoint, from: nil) }
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            importFiles(urls, on: pv, at: point)
            return true
        }
        if let data = pb.data(forType: .png) ?? pb.data(forType: .tiff) {
            do { try insertImage(data, on: pv, at: point) } catch { NSSound.beep() }
            return true
        }
        return false
    }

    // MARK: Clipboard

    private static let pasteboardType = NSPasteboard.PasteboardType("local.inkwell.items")

    /// What Inkwell copies: strokes and elements plus any assets the elements need, so pasting into a
    /// different notebook keeps the images.
    struct ClipboardItems: Codable {
        var strokes: [Stroke]
        var elements: [PageElement]
        var assets: [UUID: Data]
    }

    @objc func copy(_ sender: Any?) {
        guard let sel = selection else { return }
        let page = sel.page.page
        let strokes = page.strokes.filter { sel.strokes.contains($0.id) }
        let elements = page.elements.filter { sel.elements.contains($0.id) }
        var assets: [UUID: Data] = [:]
        for e in elements { if let a = e.imageAsset { assets[a] = session.notebook.assets[a] } }
        let items = ClipboardItems(strokes: strokes, elements: elements, assets: assets)
        let pb = NSPasteboard.general
        pb.clearContents()
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        if let data = try? encoder.encode(items) { pb.setData(data, forType: Self.pasteboardType) }
        // Also offer a picture and plain text, so pasting into other apps works.
        var lifted = page.emptyCopy()
        lifted.strokes = strokes
        lifted.elements = elements
        let box = sel.bounds.insetBy(dx: -6, dy: -6)
        if let png = selectionPNG(lifted, box: box) { pb.setData(png, forType: .png) }
        let texts = elements.compactMap(\.text)
        if !texts.isEmpty { pb.setString(texts.joined(separator: "\n"), forType: .string) }
        showHUD("Copied", symbol: "doc.on.doc")
    }

    @objc func cut(_ sender: Any?) {
        copy(sender)
        deleteSelection()
    }

    @objc func paste(_ sender: Any?) {
        // Paste next to what's selected; otherwise onto the page in view.
        guard let pv = selection?.page ?? currentPageView else { return }
        let pb = NSPasteboard.general
        if let data = pb.data(forType: Self.pasteboardType), let items = try? PropertyListDecoder().decode(ClipboardItems.self, from: data) {
            pasteItems(items, on: pv)
        } else if let img = pb.data(forType: .png) ?? pb.data(forType: .tiff) {
            do { try insertImage(img, on: pv) } catch { NSSound.beep() }
        } else if let text = pb.string(forType: .string), !text.isEmpty {
            var st = tools.textStyle
            st.size = st.size.clamped(TextStyle.sizeRange.lowerBound, TextStyle.sizeRange.upperBound)
            let c = visibleCenter(of: pv)
            let w = min(420, pv.bounds.width - 48)
            let el = PageElement(frame: CGRect(x: max(24, c.x - w / 2), y: c.y, width: w, height: PageRenderer.textHeight(text, style: st, width: w)),
                                 content: .text(text, st))
            session.upsertElement(el, on: pv.page.id, actionName: "Paste")
        } else {
            NSSound.beep()
        }
    }

    private func pasteItems(_ items: ClipboardItems, on pv: PageView) {
        var remap: [UUID: UUID] = [:]
        for (id, data) in items.assets { remap[id] = session.addAsset(data) }
        // Pasted copies land offset from the originals, or centred in view when pasting elsewhere.
        let bounds = (items.strokes.map(\.bounds) + items.elements.map(\.frame)).reduce(CGRect.null) { $0.union($1) }
        let c = visibleCenter(of: pv)
        let onScreen = pv.convert(scrollView.contentView.bounds, from: docView).intersects(bounds)
        let dx = onScreen ? 24 : c.x - bounds.midX, dy = onScreen ? 24 : c.y - bounds.midY
        let strokes = items.strokes.compactMap { Stroke(kind: $0.kind, color: $0.color, width: $0.width, points: $0.points)?.translated(dx: dx, dy: dy) }
        let elements = items.elements.map { e -> PageElement in
            var c = e
            c.id = UUID()
            c.frame = e.frame.offsetBy(dx: dx, dy: dy)
            if case .image(let a) = e.content, let n = remap[a] { c.content = .image(asset: n) }
            return c
        }
        clearSelection()
        session.editPage(pv.page.id, "Paste") { p in p.strokes += strokes; p.elements += elements }
        if tools.tool != .lasso { tools.tool = .lasso }
        DispatchQueue.main.async { self.select(strokes: Set(strokes.map(\.id)), elements: Set(elements.map(\.id)), on: pv) }
    }

    private func selectionPNG(_ page: Page, box: CGRect) -> Data? {
        let scale: CGFloat = 2
        let w = Int(box.width * scale), h = Int(box.height * scale)
        guard w > 0, h > 0, w * h < 60_000_000,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: scale, y: -scale)
        ctx.translateBy(x: -box.minX, y: -box.minY)
        var o = PageRenderer.Options()
        o.skipBackground = true
        PageRenderer.drawImages(page, in: ctx, assets: session.assets, options: o)
        PageRenderer.drawStrokes(page.strokes, kind: .highlighter, in: ctx, options: o)
        PageRenderer.drawTexts(page, in: ctx, options: o)
        PageRenderer.drawStrokes(page.strokes, kind: .pen, in: ctx, options: o)
        guard let img = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])
    }

    // MARK: Handwriting → text

    /// Recognises the selected handwriting and replaces it with an editable text box (one undo step).
    func convertSelectionToText() {
        guard let sel = selection, !sel.strokes.isEmpty else { NSSound.beep(); return }
        let strokes = sel.page.page.strokes.filter { sel.strokes.contains($0.id) }
        let pv = sel.page
        let bounds = sel.bounds
        // Size the text roughly like the handwriting: average line height ≈ ink height per line.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let text = HandwritingRecognizer.recognize(strokes: strokes)
            DispatchQueue.main.async {
                guard let self else { return }
                guard !text.isEmpty else {
                    let alert = NSAlert()
                    alert.messageText = "No text was recognised in the selection."
                    alert.informativeText = "Try selecting complete words, written fairly clearly."
                    if let w = self.window { alert.beginSheetModal(for: w) }
                    return
                }
                var st = self.tools.textStyle
                let lines = max(1, text.split(separator: "\n").count)
                st.size = (Double(bounds.height) / Double(lines) * 0.62).clamped(10, 72)
                st.color = strokes.first.map { $0.color.opaque } ?? st.color
                let w = max(bounds.width, 60)
                let el = PageElement(frame: CGRect(x: bounds.minX, y: bounds.minY, width: w, height: PageRenderer.textHeight(text, style: st, width: w)),
                                     content: .text(text, st))
                self.clearSelection()
                self.session.editPage(pv.page.id, "Convert to Text") { p in
                    p.strokes.removeAll { sel.strokes.contains($0.id) }
                    p.elements.append(el)
                }
                self.select(strokes: [], elements: [el.id], on: pv)
                self.showHUD("Converted to text", symbol: "text.viewfinder")
            }
        }
    }
}
