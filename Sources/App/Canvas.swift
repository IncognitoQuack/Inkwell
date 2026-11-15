import AppKit
import Combine
import QuartzCore

// MARK: - Scroll infrastructure

/// Keeps pages centred when zoomed out narrower than the window.
final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposed: NSRect) -> NSRect {
        var r = super.constrainBoundsRect(proposed)
        guard let doc = documentView else { return r }
        if r.width > doc.frame.width { r.origin.x = (doc.frame.width - r.width) / 2 }
        if r.height > doc.frame.height { r.origin.y = (doc.frame.height - r.height) / 2 }
        return r
    }
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// ⌘-scroll zooms around the pointer, for mice without pinch.
final class ZoomScrollView: NSScrollView {
    /// Two-finger double-tap on a trackpad.
    var onSmartMagnify: ((NSEvent) -> Void)?
    override func smartMagnify(with event: NSEvent) {
        if let f = onSmartMagnify { f(event) } else { super.smartMagnify(with: event) }
    }

    override func scrollWheel(with e: NSEvent) {
        guard e.modifierFlags.contains(.command), allowsMagnification else { return super.scrollWheel(with: e) }
        let delta = e.hasPreciseScrollingDeltas ? e.scrollingDeltaY * 0.01 : e.scrollingDeltaY * 0.08
        guard delta.isFinite, delta != 0, let doc = documentView else { return }
        let point = doc.convert(e.locationInWindow, from: nil)
        setMagnification((magnification * (1 + delta)).clamped(minMagnification, maxMagnification), centeredAt: point)
    }
}

// MARK: - Canvas

/// Selection facts the toolbar shows actions for.
final class CanvasState: ObservableObject {
    @Published var hasSelection = false
    @Published var selectionHasInk = false
    @Published var selectionLink: String?
    @Published var zoomWindowOpen = false
    @Published var selectionHasAudio = false
    @Published var rulerShown = false
}

final class CanvasView: NSView {
    let session: NotebookSession
    let tools: ToolState
    let scrollView = ZoomScrollView()
    let docView = FlippedView()
    private(set) var pageViews: [PageView] = []
    var bag = Set<AnyCancellable>()

    static let pageGap: CGFloat = 32
    static let margin: CGFloat = 40

    // Gesture state
    enum Gesture {
        case none
        case ink(StrokeBuilder, PageView)
        case shape(ShapeRecognizer.Result, StrokeBuilder, PageView)
        case erase(PageView, last: CGPoint, hits: Set<UUID>, unarmed: Bool)
        case preciseErase(PageView, last: CGPoint, original: Page, unarmed: Bool)
        case lasso(PageView, [CGPoint])
        case moveSelection(PageView, start: CGPoint, offset: CGSize)
        case resizeElement(PageView, id: UUID, start: CGPoint, frame: CGRect)
        case pan(last: NSPoint, moved: Bool, clickAction: (() -> Void)?)
        case laser(PageView, [(CGPoint, TimeInterval)])
        case tapeRect(PageView, start: CGPoint)
        case rulerMove(PageView, start: CGPoint, center: CGPoint)
        case rulerRotate(PageView, center: CGPoint, startAngle: CGFloat, rulerAngle: CGFloat)
    }
    var gesture = Gesture.none
    var downWindowPoint = NSPoint.zero
    var downTime = Date()
    private var holdTimer: DispatchWorkItem?
    private var holdAnchor = CGPoint.zero
    var spaceHeld = false

    struct Selection {
        var page: PageView
        var strokes: Set<UUID>
        var elements: Set<UUID>
        var bounds: CGRect
        var singleElement: UUID? { strokes.isEmpty && elements.count == 1 ? elements.first : nil }
    }
    var selection: Selection?
    let lassoLayer = CAShapeLayer()
    let selectionLayer = CALayer()
    private let selectionContent = CALayer()
    private let selectionBox = CAShapeLayer()
    private let resizeHandle = CAShapeLayer()
    private let laserLayer = CAShapeLayer()
    var textEditor: TextEditor?
    let state = CanvasState()
    /// While the zoom window forwards a gesture: maps its events to page points, and its magnification.
    var inputMapper: ((NSEvent) -> CGPoint)?
    var inputScale: CGFloat?
    var zoomWriter: ZoomWriter?
    var zoomWriterHeight: NSLayoutConstraint?
    // Study tape, ruler and audio replay.
    var revealedTapes: Set<UUID> = []
    let tapePreview = CAShapeLayer()
    struct Ruler { weak var page: PageView?; var center: CGPoint; var angle: CGFloat; let length: CGFloat = 520; let width: CGFloat = 64 }
    var ruler: Ruler?
    let rulerLayer = CALayer()
    var rulerSnap: (origin: CGPoint, dir: CGVector)?
    var replay: (recording: UUID, time: Double)?
    weak var audio: AudioController?
    var textClickCandidate: UUID?
    var autoSolveWork: DispatchWorkItem?
    /// Sums already answered (by their strokes), so each is answered once.
    var answeredSums: Set<Set<UUID>> = []
    /// Replaces handwriting recognition for auto-answer (self-tests).
    var mathRecognizer: (([Stroke]) -> String)?
    lazy var pdfText = PDFTextLayer(assets: { [weak self] in self?.session.notebook.assets ?? [:] })
    var scrollBottom: NSLayoutConstraint?
    private var downPagePoint = CGPoint.zero
    /// Screen pixels per page point for the gesture in progress (zoom window or main view).
    var inputMagnification: CGFloat { inputScale ?? scrollView.magnification }
    let hud = HUDView()
    private var lastHUDPage = -1

    init(session: NotebookSession, tools: ToolState) {
        self.session = session
        self.tools = tools
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.underPageBackgroundColor.cgColor

        let clip = CenteringClipView()
        clip.drawsBackground = false
        scrollView.contentView = clip
        scrollView.documentView = docView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.25
        scrollView.maxMagnification = 5
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)
        let bottom = scrollView.bottomAnchor.constraint(equalTo: bottomAnchor)
        scrollBottom = bottom
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            bottom,
        ])

        configureOverlayLayers()
        rebuildPages(animated: false)
        scrollView.onSmartMagnify = { [weak self] e in self?.smartZoom(at: e) }
        hud.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hud)
        NSLayoutConstraint.activate([
            hud.centerXAnchor.constraint(equalTo: centerXAnchor),
            hud.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: -26), // stays above the zoom strip
        ])
        registerForDraggedTypes([.fileURL, .png, .tiff])

        session.pageContentChanged = { [weak self] id, area in self?.pageContentChanged(id, area: area) }
        session.pagesChanged = { [weak self] in self?.rebuildPages(animated: true) }

        clip.postsBoundsChangedNotifications = true
        NotificationCenter.default.publisher(for: NSView.boundsDidChangeNotification, object: clip)
            .sink { [weak self] _ in self?.updateCurrentPage() }.store(in: &bag)
        NotificationCenter.default.publisher(for: NSScrollView.didEndLiveMagnifyNotification, object: scrollView)
            .sink { [weak self] _ in self?.magnificationChanged(announce: true) }.store(in: &bag)
        // Undo/redo can move or delete selected items behind the selection's back; drop it.
        for name in [Notification.Name.NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange] {
            NotificationCenter.default.publisher(for: name, object: session.undoManager)
                .sink { [weak self] _ in self?.clearSelection() }.store(in: &bag)
        }
        tools.$tool.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.endTextEditing(); self?.clearSelection(); self?.refreshCursor() }
        }.store(in: &bag)
        Publishers.Merge4(tools.$penWidth.map { _ in () }, tools.$highlighterWidth.map { _ in () },
                          tools.$eraserRadius.map { _ in () }, tools.$penColor.map { _ in () })
            .dropFirst(4).sink { [weak self] in DispatchQueue.main.async { self?.refreshCursor() } }.store(in: &bag)
        // Picking a colour while ink is selected recolours it.
        Publishers.Merge(tools.$penColor.dropFirst(), tools.$highlighterColor.dropFirst())
            .sink { [weak self] c in self?.recolorSelection(c) }.store(in: &bag)
        tools.$textStyle.dropFirst().removeDuplicates()
            .sink { [weak self] st in self?.applyTextStyle(st) }.store(in: &bag)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        window?.makeFirstResponder(self)
        DispatchQueue.main.async { self.zoomToFitWidth() }
    }

    // MARK: Pages

    func rebuildPages(animated: Bool = false) {
        let animate = animated && !Motion.reduced && window != nil
        let existing = Dictionary(uniqueKeysWithValues: pageViews.map { ($0.page.id, $0) })
        var views: [PageView] = []
        let maxWidth = session.notebook.pages.map { $0.pageSize.width }.max() ?? 595
        var y = Self.pageGap
        for page in session.notebook.pages {
            let pv = existing[page.id] ?? PageView(page: page)
            pv.canvas = self
            pv.assets = session.assets
            if pv.page != page { pv.page = page; pv.needsDisplay = true }
            let size = page.pageSize
            let frame = CGRect(x: Self.margin + (maxWidth - size.width) / 2, y: y, width: size.width, height: size.height)
            y += size.height + Self.pageGap
            if pv.superview == nil {
                pv.frame = frame
                docView.addSubview(pv)
                if animate {
                    // New pages fade and settle in.
                    pv.alphaValue = 0
                    pv.frame = frame.offsetBy(dx: 0, dy: 18)
                }
            }
            views.append(pv)
            if animate {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.28
                    ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    pv.animator().frame = frame
                    pv.animator().alphaValue = 1
                }
            } else {
                pv.frame = frame
            }
        }
        let keep = Set(session.notebook.pages.map(\.id))
        for pv in pageViews where !keep.contains(pv.page.id) {
            if selection?.page === pv { clearSelection() }
            if textEditor?.pageView === pv { endTextEditing(commit: false) }
            if animate {
                NSAnimationContext.runAnimationGroup({ ctx in
                    ctx.duration = 0.2
                    pv.animator().alphaValue = 0
                }, completionHandler: { pv.removeFromSuperview() })
            } else {
                pv.removeFromSuperview()
            }
        }
        pageViews = views
        docView.frame = CGRect(x: 0, y: 0, width: maxWidth + 2 * Self.margin, height: y)
        // The zoom box's page was deleted: move the box to the page in view.
        if let z = zoomWriter, !(z.pageView.map { pv in views.contains { $0 === pv } } ?? false), let pv = views.first {
            z.detach()
            z.attach(to: currentPageView ?? pv)
        }
        window?.invalidateCursorRects(for: docView)
        updateCurrentPage()
    }

    private func pageContentChanged(_ id: UUID, area: CGRect?) {
        zoomWriter?.pageChanged(id)
        guard let pv = pageViews.first(where: { $0.page.id == id }), let p = session.page(id) else { return }
        pv.page = p
        if let area { pv.setNeedsDisplay(area.insetBy(dx: -3, dy: -3)) } else { pv.needsDisplay = true }
        if p.strokes.count % 64 == 0 { pv.cache.prune(keeping: Set(p.strokes.map(\.id))) }
    }

    private func updateCurrentPage() {
        let visible = scrollView.contentView.bounds
        let probe = CGPoint(x: visible.midX, y: visible.minY + visible.height * 0.35)
        let best = pageViews.enumerated().min { a, b in
            abs(a.element.frame.midY - probe.y) - (a.element.frame.contains(probe) ? 1e6 : 0)
                < abs(b.element.frame.midY - probe.y) - (b.element.frame.contains(probe) ? 1e6 : 0)
        }
        if let i = best?.offset, i != session.currentPageIndex {
            session.currentPageIndex = i
            if pageViews.count > 1, i != lastHUDPage {
                lastHUDPage = i
                showHUD("Page \(i + 1) of \(pageViews.count)", symbol: "doc.text")
            }
        }
    }

    func scrollToPage(_ index: Int) {
        guard pageViews.indices.contains(index) else { return }
        let target = pageViews[index].frame
        let clip = scrollView.contentView
        clip.scroll(to: clip.constrainBoundsRect(NSRect(x: clip.bounds.origin.x, y: target.minY - Self.pageGap / 2,
                                                         width: clip.bounds.width, height: clip.bounds.height)).origin)
        scrollView.reflectScrolledClipView(clip)
        session.currentPageIndex = index
    }

    var currentPageView: PageView? {
        pageViews.indices.contains(session.currentPageIndex) ? pageViews[session.currentPageIndex] : pageViews.first
    }

    /// Centre of the visible part of a page, in that page's coordinates.
    func visibleCenter(of pv: PageView) -> CGPoint {
        let visible = pv.convert(scrollView.contentView.bounds, from: docView).intersection(pv.bounds)
        return visible.isNull ? CGPoint(x: pv.bounds.midX, y: pv.bounds.midY) : CGPoint(x: visible.midX, y: visible.midY)
    }

    // MARK: Zoom

    func zoomToFitWidth() {
        let available = scrollView.contentView.bounds.width * scrollView.magnification
        guard available > 50, docView.frame.width > 0 else { return }
        scrollView.magnification = (available / docView.frame.width).clamped(0.4, 1.6)
        scrollToPage(session.currentPageIndex)
        magnificationChanged()
    }

    func zoom(by factor: CGFloat) {
        let c = scrollView.contentView.bounds
        scrollView.setMagnification((scrollView.magnification * factor).clamped(scrollView.minMagnification, scrollView.maxMagnification),
                                    centeredAt: CGPoint(x: c.midX, y: c.midY))
        magnificationChanged(announce: true)
    }

    func zoomToActualSize() { zoom(by: 1 / scrollView.magnification) }

    private var fitMagnification: CGFloat {
        let available = scrollView.contentView.bounds.width * scrollView.magnification
        return docView.frame.width > 0 ? (available / docView.frame.width).clamped(0.4, 1.6) : 1
    }

    /// Two-finger double-tap: zoom in on that spot, or back out to fit the width.
    func smartZoom(at e: NSEvent) {
        let fit = fitMagnification
        let p = docView.convert(e.locationInWindow, from: nil)
        let target = scrollView.magnification > fit * 1.25 ? fit : min(fit * 2.2, scrollView.maxMagnification)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Motion.reduced ? 0 : 0.25
            scrollView.animator().setMagnification(target, centeredAt: p)
        } completionHandler: { [weak self] in self?.magnificationChanged(announce: true) }
    }

    func magnificationChanged(announce: Bool = false) {
        if announce { showHUD("\(Int((scrollView.magnification * 100).rounded()))%", symbol: "magnifyingglass") }
        refreshCursor()
        for pv in pageViews where pv.page.background != nil { pv.needsDisplay = true } // sharper PDF raster
        if let s = selection { select(strokes: s.strokes, elements: s.elements, on: s.page) }
    }

    func publishAudioSelection() {
        let has = selectionHasAudio
        if state.selectionHasAudio != has { state.selectionHasAudio = has }
    }

    // MARK: Cursor (hardware cursor = zero-lag nib preview while the pen hovers)

    private var cursorCache: [String: NSCursor] = [:]

    func currentCursor(magnification: CGFloat? = nil) -> NSCursor {
        if spaceHeld { return .openHand }
        let mag = magnification ?? scrollView.magnification
        switch tools.tool {
        case .pen:
            return nibCursor(diameter: CGFloat(tools.penWidth) * 0.8 * mag, color: tools.penColor.nsColor, hollow: false)
        case .highlighter:
            return nibCursor(diameter: CGFloat(tools.highlighterWidth) * mag, color: tools.highlighterColor.nsColor, hollow: false)
        case .eraser:
            return nibCursor(diameter: tools.eraserRadius * 2 * mag, color: .gray, hollow: true)
        case .lasso:
            return .crosshair
        case .text:
            return .iBeam
        case .laser:
            return nibCursor(diameter: 9, color: .systemRed, hollow: false)
        case .tape:
            return .crosshair
        }
    }

    private func nibCursor(diameter raw: CGFloat, color: NSColor, hollow: Bool) -> NSCursor {
        let d = raw.finiteOr(4).clamped(3, 120)
        let key = "\(Int(d * 4))-\(color.description)-\(hollow)"
        if let c = cursorCache[key] { return c }
        let side = ceil(d + 6)
        let img = NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            let r = NSRect(x: (side - d) / 2, y: (side - d) / 2, width: d, height: d)
            if hollow {
                NSColor.white.withAlphaComponent(0.9).setStroke()
                let o = NSBezierPath(ovalIn: r); o.lineWidth = 2.5; o.stroke()
                NSColor.black.withAlphaComponent(0.65).setStroke()
                let i = NSBezierPath(ovalIn: r); i.lineWidth = 1; i.stroke()
            } else {
                color.withAlphaComponent(max(color.alphaComponent, 0.55)).setFill()
                NSBezierPath(ovalIn: r).fill()
                // A light and a dark ring keep the nib visible on any paper and any ink colour.
                NSColor.white.withAlphaComponent(0.95).setStroke()
                let w = NSBezierPath(ovalIn: r.insetBy(dx: -1, dy: -1)); w.lineWidth = 1; w.stroke()
                NSColor.black.withAlphaComponent(0.35).setStroke()
                let b = NSBezierPath(ovalIn: r.insetBy(dx: -2, dy: -2)); b.lineWidth = 0.75; b.stroke()
            }
            return true
        }
        let c = NSCursor(image: img, hotSpot: NSPoint(x: side / 2, y: side / 2))
        if cursorCache.count > 64 { cursorCache.removeAll() }
        cursorCache[key] = c
        return c
    }

    func refreshCursor() {
        window?.invalidateCursorRects(for: docView)
        for pv in pageViews { window?.invalidateCursorRects(for: pv) }
    }

    // MARK: Pointer input

    func isPen(_ e: NSEvent) -> Bool { e.subtype == .tabletPoint }

    func location(_ e: NSEvent, in pv: PageView) -> CGPoint {
        if let m = inputMapper { return m(e) }
        return pv.convert(e.locationInWindow, from: nil)
    }

    var contentsScale: CGFloat { (window?.backingScaleFactor ?? 2) * scrollView.magnification }

    private var isQuickClick: Bool { Date().timeIntervalSince(downTime) < 0.35 }

    func pointerDown(_ e: NSEvent, on pv: PageView) {
        if textEditor != nil { endTextEditing() }
        window?.makeFirstResponder(self)
        endGesture()
        downWindowPoint = e.locationInWindow
        downTime = Date()
        let p = location(e, in: pv)
        downPagePoint = p

        // ⌥-click places the zoom window's writing box.
        if inputMapper == nil, e.type == .leftMouseDown, e.modifierFlags.contains(.option), let z = zoomWriter {
            z.moveTarget(to: p, on: pv)
            return
        }

        // ⌘-click follows a link with any tool.
        if e.type == .leftMouseDown, e.modifierFlags.contains(.command), openLink(at: p, on: pv) { return }

        switch e.type {
        case .rightMouseDown:
            // Lower pen button ("right click" in the XPPen driver): hold = erase, click = swap tool.
            // Not armed yet: a quick click must only swap tools, never erase what's under the nib.
            beginErase(on: pv, at: p, unarmed: true)
            return
        case .otherMouseDown where e.buttonNumber == 3 || e.buttonNumber == 4:
            // Mouse back / forward side buttons: previous / next page.
            scrollToPage((session.currentPageIndex + (e.buttonNumber == 3 ? -1 : 1)).clamped(0, pageViews.count - 1))
            return
        case .otherMouseDown:
            // Upper pen button ("middle click"): hold = pan, click = undo.
            gesture = .pan(last: e.locationInWindow, moved: false, clickAction: { [weak self] in self?.session.undoManager.undo() })
            NSCursor.closedHand.push()
            return
        default:
            break
        }

        // The ruler takes clicks on its body (move) and its end knob (rotate) with any tool.
        if e.type == .leftMouseDown, let r = ruler, r.page === pv, let g = rulerGesture(at: p, on: pv) {
            gesture = g
            return
        }

        // "Only the pen draws": a mouse or trackpad drag pans instead of inking, but still selects, types,
        // places tape, resizes and follows links normally.
        let inkingTool = tools.tool == .pen || tools.tool == .highlighter || tools.tool == .eraser
        if spaceHeld || (tools.penOnly && !isPen(e) && inkingTool) {
            gesture = .pan(last: e.locationInWindow, moved: false, clickAction: nil)
            NSCursor.closedHand.push()
            return
        }

        switch tools.tool {
        case .pen, .highlighter:
            beginInk(e, at: p, on: pv)
        case .eraser:
            beginErase(on: pv, at: p, unarmed: false)
        case .lasso:
            if let sel = selection, sel.page === pv {
                if let id = sel.singleElement, handleRect(for: sel).insetBy(dx: -4, dy: -4).contains(p),
                   let el = pv.page.elements.first(where: { $0.id == id }) {
                    gesture = .resizeElement(pv, id: id, start: p, frame: el.frame)
                    return
                }
                if sel.bounds.insetBy(dx: -8, dy: -8).contains(p) {
                    if e.clickCount == 2, let id = sel.singleElement, let el = pv.page.elements.first(where: { $0.id == id }), el.text != nil {
                        clearSelection()
                        beginTextEditing(el, on: pv)
                        return
                    }
                    gesture = .moveSelection(pv, start: p, offset: .zero)
                    return
                }
            }
            clearSelection()
            // A click on an element selects it directly (no need to lasso a single picture).
            if let el = pv.page.elements.last(where: { $0.frame.contains(p) }) {
                select(strokes: [], elements: [el.id], on: pv)
                gesture = .moveSelection(pv, start: p, offset: .zero)
                return
            }
            gesture = .lasso(pv, [p])
            pv.overlay.addSublayer(lassoLayer)
            lassoLayer.path = nil
        case .text:
            clearSelection()
            if let el = pv.page.elements.last(where: { $0.text != nil && $0.frame.insetBy(dx: -4, dy: -4).contains(p) }) {
                // Drag moves the box; a plain click edits it (decided on release).
                select(strokes: [], elements: [el.id], on: pv)
                gesture = .moveSelection(pv, start: p, offset: .zero)
                textClickCandidate = el.id
            } else {
                createTextBox(at: p, on: pv)
            }
        case .tape:
            clearSelection()
            gesture = .tapeRect(pv, start: p)
            tapePreview.path = nil
            pv.overlay.addSublayer(tapePreview)
        case .laser:
            NSEvent.isMouseCoalescingEnabled = false
            gesture = .laser(pv, [(p, e.timestamp)])
            laserLayer.removeAllAnimations()
            laserLayer.opacity = 1
            laserLayer.lineWidth = 5 / max(scrollView.magnification, 0.25)
            laserLayer.shadowRadius = 6 / max(scrollView.magnification, 0.25)
            pv.overlay.addSublayer(laserLayer)
            updateLaser(pv, [(p, e.timestamp)])
        }
    }

    func pointerDragged(_ e: NSEvent) {
        switch gesture {
        case .none:
            return
        case .ink(let builder, let pv):
            let p = snapToRuler(location(e, in: pv))
            guard builder.add(x: Double(p.x), y: Double(p.y), pressure: Double(e.pressure), timestamp: e.timestamp) else { return }
            if builder.isFull {
                // Very long stroke: commit what we have and continue seamlessly in a new one.
                if let s = builder.makeStroke() { commitStroke(s, on: pv, allowGestures: false) }
                let next = makeBuilder(e)
                next.add(x: Double(p.x), y: Double(p.y), pressure: Double(e.pressure), timestamp: e.timestamp)
                gesture = .ink(next, pv)
                pv.live.begin(kind: next.kind, color: next.color, width: next.width, frame: pv.bounds, contentsScale: contentsScale)
                pv.live.update(points: next.points, predicted: nil)
                return
            }
            if e.modifierFlags.contains(.shift), let first = builder.points.first {
                // Shift: a straight line, snapped to 15° steps.
                let r = ShapeRecognizer.Result(shape: .line, points: [first.cgPoint, Self.snapAngle(from: first.cgPoint, to: p)])
                gesture = .shape(r, builder, pv)
                if let s = shapeStroke(r, builder) { pv.live.show(stroke: s) }
                return
            }
            pv.live.update(points: builder.points, predicted: tools.prediction ? builder.predictedPoint() : nil)
            if hypot(p.x - holdAnchor.x, p.y - holdAnchor.y) * inputMagnification > 3 {
                holdAnchor = p
                scheduleShapeSnap()
            }
        case .shape(let result, let builder, let pv):
            // A snapped line keeps following the pen so it can be aimed; closed shapes stay put.
            guard result.shape == .line, let a = result.points.first else { return }
            let p = location(e, in: pv)
            let r = ShapeRecognizer.Result(shape: .line, points: [a, e.modifierFlags.contains(.shift) ? Self.snapAngle(from: a, to: p) : p])
            gesture = .shape(r, builder, pv)
            if let s = shapeStroke(r, builder) { pv.live.show(stroke: s) }
        case .erase(let pv, let last, let hits, let unarmed):
            let p = location(e, in: pv)
            if unarmed, !armIfMoved(e) { return }
            gesture = .erase(pv, last: p, hits: hits, unarmed: false)
            eraseSweep(pv, from: unarmed ? downLocation(in: pv) : last, to: p)
        case .preciseErase(let pv, let last, let original, let unarmed):
            let p = location(e, in: pv)
            if unarmed, !armIfMoved(e) { return }
            gesture = .preciseErase(pv, last: p, original: original, unarmed: false)
            preciseSweep(pv, from: unarmed ? downLocation(in: pv) : last, to: p)
        case .lasso(let pv, var pts):
            let p = location(e, in: pv)
            if let l = pts.last, hypot(p.x - l.x, p.y - l.y) < 1.5 { return }
            pts.append(p)
            gesture = .lasso(pv, pts)
            let path = CGMutablePath()
            path.addLines(between: pts)
            CATransaction.begin(); CATransaction.setDisableActions(true)
            lassoLayer.path = path
            CATransaction.commit()
        case .moveSelection(let pv, let start, _):
            let p = location(e, in: pv)
            let offset = CGSize(width: p.x - start.x, height: p.y - start.y)
            gesture = .moveSelection(pv, start: start, offset: offset)
            CATransaction.begin(); CATransaction.setDisableActions(true)
            selectionLayer.setAffineTransform(CGAffineTransform(translationX: offset.width, y: offset.height))
            CATransaction.commit()
        case .resizeElement(let pv, let id, let start, let frame):
            let p = location(e, in: pv)
            guard let el = pv.page.elements.first(where: { $0.id == id }) else { return }
            let nf = resizedFrame(el, from: frame, by: CGSize(width: p.x - start.x, height: p.y - start.y))
            let sx = nf.width / frame.width, sy = nf.height / frame.height
            CATransaction.begin(); CATransaction.setDisableActions(true)
            // Scale about the element's top-left corner.
            selectionLayer.setAffineTransform(CGAffineTransform(a: sx, b: 0, c: 0, d: sy, tx: frame.minX * (1 - sx), ty: frame.minY * (1 - sy)))
            CATransaction.commit()
        case .pan(let last, var moved, let click):
            let now = e.locationInWindow
            if hypot(now.x - downWindowPoint.x, now.y - downWindowPoint.y) > 4 { moved = true }
            let clip = scrollView.contentView
            let mag = scrollView.magnification
            var origin = clip.bounds.origin
            origin.x -= (now.x - last.x) / mag
            origin.y += (now.y - last.y) / mag // window y is up, document y is down
            clip.scroll(to: clip.constrainBoundsRect(NSRect(origin: origin, size: clip.bounds.size)).origin)
            scrollView.reflectScrolledClipView(clip)
            gesture = .pan(last: now, moved: moved, clickAction: click)
        case .tapeRect(let pv, let start):
            let r = CGRect(x: min(start.x, location(e, in: pv).x), y: min(start.y, location(e, in: pv).y),
                           width: abs(location(e, in: pv).x - start.x), height: abs(location(e, in: pv).y - start.y))
            CATransaction.begin(); CATransaction.setDisableActions(true)
            tapePreview.path = CGPath(roundedRect: r, cornerWidth: 3, cornerHeight: 3, transform: nil)
            CATransaction.commit()
        case .rulerMove(let pv, let start, let center):
            let p = location(e, in: pv)
            moveRuler(to: CGPoint(x: center.x + p.x - start.x, y: center.y + p.y - start.y), on: pv)
        case .rulerRotate(let pv, let center, let startAngle, let rulerAngle):
            let p = location(e, in: pv)
            var a = rulerAngle + atan2(p.y - center.y, p.x - center.x) - startAngle
            // Snap to every 15° when close, like a protractor detent.
            let step = CGFloat.pi / 12
            if abs(a - (a / step).rounded() * step) < 0.035 { a = (a / step).rounded() * step }
            rotateRuler(to: a)
        case .laser(let pv, var trail):
            trail.append((location(e, in: pv), e.timestamp))
            // Keep the last ~0.6 s: a comet tail that follows the pen.
            if let t = trail.last?.1 { trail.removeAll { t - $0.1 > 0.6 } }
            gesture = .laser(pv, trail)
            updateLaser(pv, trail)
        }
    }

    func pointerUp(_ e: NSEvent) {
        holdTimer?.cancel()
        switch gesture {
        case .none:
            break
        case .ink(let builder, let pv):
            let p = snapToRuler(location(e, in: pv))
            if let s = builder.finish(x: Double(p.x), y: Double(p.y), pressure: Double(e.pressure), timestamp: e.timestamp) {
                commitStroke(s, on: pv, allowGestures: true)
            } else {
                pv.live.reset()
            }
        case .shape(let result, let builder, let pv):
            if let s = shapeStroke(result, builder) { commitStroke(s, on: pv, allowGestures: false, name: "Shape") } else { pv.live.reset() }
        case .erase(let pv, _, let hits, let unarmed):
            if !hits.isEmpty { fadeOut(pv.page.strokes.filter { hits.contains($0.id) }, on: pv) }
            pv.hiddenStrokes = []
            if !hits.isEmpty { session.removeStrokes(hits, from: pv.page.id) }
            if unarmed && isQuickClick { tools.swapToPreviousTool() }
        case .preciseErase(let pv, _, let original, let unarmed):
            session.commitLiveEdit(pv.page.id, original: original, name: "Erase")
            if unarmed && isQuickClick { tools.swapToPreviousTool() }
        case .lasso(let pv, let pts):
            lassoLayer.removeFromSuperlayer()
            if ShapeRecognizer.pathLength(pts) * inputMagnification < 6, let first = pts.first {
                // A click, not a lasso: follow a link if there is one.
                _ = openLink(at: first, on: pv)
                break
            }
            let strokes = Set(pv.page.strokes.filter { HitTest.lasso(pts, contains: $0) }.map(\.id))
            let elements = Set(pv.page.elements.filter { HitTest.pointInPolygon(CGPoint(x: $0.frame.midX, y: $0.frame.midY), pts) }.map(\.id))
            if !strokes.isEmpty || !elements.isEmpty { select(strokes: strokes, elements: elements, on: pv) }
        case .moveSelection(let pv, _, let offset) where textClickCandidate != nil && hypot(offset.width, offset.height) * inputMagnification < 4:
            // Text tool click on a box: edit it.
            selectionLayer.setAffineTransform(.identity)
            let id = textClickCandidate!
            clearSelection()
            if let el = pv.page.elements.first(where: { $0.id == id }) { beginTextEditing(el, on: pv) }
        case .moveSelection(let pv, _, let offset):
            selectionLayer.setAffineTransform(.identity)
            if let sel = selection, offset != .zero {
                session.moveItems(strokes: sel.strokes, elements: sel.elements, on: pv.page.id, dx: offset.width, dy: offset.height)
                // With the text tool the box was only picked up to move it; don't leave it selected.
                if tools.tool == .text { clearSelection() } else { select(strokes: sel.strokes, elements: sel.elements, on: pv) }
            } else if tools.tool == .text {
                clearSelection()
            }
        case .resizeElement(let pv, let id, let start, let frame):
            let p = location(e, in: pv)
            selectionLayer.setAffineTransform(.identity)
            if var el = pv.page.elements.first(where: { $0.id == id }) {
                el.frame = resizedFrame(el, from: frame, by: CGSize(width: p.x - start.x, height: p.y - start.y))
                session.upsertElement(el, on: pv.page.id, actionName: "Resize")
                select(strokes: [], elements: [id], on: pv)
            }
        case .pan(_, let moved, let click):
            NSCursor.pop()
            if !moved && isQuickClick { click?() }
        case .tapeRect(let pv, let start):
            tapePreview.removeFromSuperlayer()
            let p = location(e, in: pv)
            let r = CGRect(x: min(start.x, p.x), y: min(start.y, p.y), width: abs(p.x - start.x), height: abs(p.y - start.y))
            if r.width * inputMagnification < 6 && r.height * inputMagnification < 6 {
                // A click: peel back (or re-cover) the tape under the pen.
                if let t = pv.page.elements.last(where: { $0.isTape && $0.frame.insetBy(dx: -3, dy: -3).contains(p) }) { toggleTape(t.id, on: pv) }
            } else if r.width >= 12, r.height >= 8 {
                let el = PageElement(frame: r, content: .tape(tools.tapeColor, Review.new()))
                session.upsertElement(el, on: pv.page.id, actionName: "Add Tape")
            }
        case .rulerMove, .rulerRotate:
            break
        case .laser:
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1
            fade.toValue = 0
            fade.duration = 0.7
            fade.isRemovedOnCompletion = false
            fade.fillMode = .forwards
            laserLayer.add(fade, forKey: "fade")
        }
        gesture = .none
        rulerSnap = nil
        textClickCandidate = nil
        NSEvent.isMouseCoalescingEnabled = true
    }

    static func snapAngle(from a: CGPoint, to b: CGPoint) -> CGPoint {
        let len = hypot(b.x - a.x, b.y - a.y)
        let step = CGFloat.pi / 12
        let ang = (atan2(b.y - a.y, b.x - a.x) / step).rounded() * step
        return CGPoint(x: a.x + cos(ang) * len, y: a.y + sin(ang) * len)
    }

    private func downLocation(in pv: PageView) -> CGPoint { downPagePoint }

    /// Button-erase arms once the pen actually moves (4 px), so a click stays a click.
    private func armIfMoved(_ e: NSEvent) -> Bool {
        guard hypot(e.locationInWindow.x - downWindowPoint.x, e.locationInWindow.y - downWindowPoint.y) > 4 else { return false }
        NSEvent.isMouseCoalescingEnabled = false
        return true
    }

    func makeBuilder(_ e: NSEvent) -> StrokeBuilder {
        let hl = tools.tool == .highlighter
        return StrokeBuilder(kind: hl ? .highlighter : .pen,
                             color: hl ? tools.highlighterColor : tools.penColor,
                             width: hl ? tools.highlighterWidth : tools.penWidth,
                             scale: Double(inputMagnification),
                             simulatePressure: !isPen(e),
                             pressureGamma: tools.pressureFeel.gamma,
                             curve: tools.activeCurve,
                             smoothing: tools.smoothing)
    }

    private func beginInk(_ e: NSEvent, at raw: CGPoint, on pv: PageView) {
        // Every tablet sample matters (the G640 reports ~266/s); don't let AppKit merge them.
        NSEvent.isMouseCoalescingEnabled = false
        autoSolveWork?.cancel() // still writing: wait for the pause
        rulerSnap = rulerEdge(near: raw, on: pv)
        let p = snapToRuler(raw)
        let b = makeBuilder(e)
        b.add(x: Double(p.x), y: Double(p.y), pressure: Double(e.pressure), timestamp: e.timestamp)
        gesture = .ink(b, pv)
        pv.live.begin(kind: b.kind, color: b.color, width: b.width, frame: pv.bounds, contentsScale: contentsScale)
        pv.live.update(points: b.points, predicted: nil)
        holdAnchor = p
        scheduleShapeSnap()
    }

    /// Adds the stroke to the model, then draws the page synchronously before removing the live layer,
    /// all in one transaction, so there is never a frame where the stroke flickers or disappears.
    private func commitStroke(_ stroke: Stroke, on pv: PageView, allowGestures: Bool, name: String? = nil) {
        var s = stroke
        // Link ink written during a recording to the moment it was written.
        if let (rec, offset) = audio?.anchor(forStrokeLasting: Double(s.points.last?.time ?? 0)) {
            s.recording = rec
            s.recordingOffset = offset
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        if allowGestures, tools.scribbleToErase, s.kind == .pen, ScribbleDetector.isScribble(s) {
            let targets = ScribbleDetector.targets(of: s, in: pv.page.strokes)
            if !targets.isEmpty {
                fadeOut(pv.page.strokes.filter { targets.contains($0.id) }, on: pv)
                session.removeStrokes(targets, from: pv.page.id, actionName: "Scratch Out")
                showHUD("Scratched out", symbol: "scribble")
                pv.displayIfNeeded()
                pv.live.reset()
                return
            }
        }
        // Highlighting printed PDF text: land exactly on the lines, like a real highlighter.
        if allowGestures, tools.snapHighlights, s.kind == .highlighter, pv.page.background != nil,
           let snapped = pdfText.snapHighlight(s, on: pv.page) {
            session.addStrokes(snapped, to: pv.page.id, actionName: "Highlight")
            pv.displayIfNeeded()
            pv.live.reset()
            return
        }
        session.addStrokes([s], to: pv.page.id, actionName: name ?? (s.kind == .highlighter ? "Highlight" : "Ink"))
        if s.kind == .pen { scheduleAutoSolve(on: pv) }
        pv.displayIfNeeded()
        zoomWriter?.paper.displayIfNeeded() // same transaction: the strip never shows a frame without the stroke
        pv.live.reset()
    }

    // MARK: Draw-and-hold shape snapping

    private func scheduleShapeSnap() {
        holdTimer?.cancel()
        guard tools.holdToStraighten else { return }
        let work = DispatchWorkItem { [weak self] in self?.snapIfHeld() }
        holdTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55, execute: work)
    }

    func snapIfHeld() {
        guard rulerSnap == nil, case .ink(let builder, let pv) = gesture, builder.points.count >= 4 else { return }
        let pts = builder.points.map(\.cgPoint)
        guard ShapeRecognizer.pathLength(pts) * inputMagnification > 24,
              let result = ShapeRecognizer.recognize(pts) else { return }
        gesture = .shape(result, builder, pv)
        crossFade(pv.live.layer)
        if let s = shapeStroke(result, builder) { pv.live.show(stroke: s) }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }

    private func shapeStroke(_ r: ShapeRecognizer.Result, _ builder: StrokeBuilder) -> Stroke? {
        guard let model = builder.makeStroke() else { return nil }
        return ShapeRecognizer.stroke(for: r, like: model)
    }

    // MARK: Eraser

    private func beginErase(on pv: PageView, at p: CGPoint, unarmed: Bool) {
        if tools.eraserMode == .precise {
            gesture = .preciseErase(pv, last: p, original: pv.page, unarmed: unarmed)
            if !unarmed { NSEvent.isMouseCoalescingEnabled = false; preciseSweep(pv, from: p, to: p) }
        } else {
            gesture = .erase(pv, last: p, hits: [], unarmed: unarmed)
            if !unarmed { NSEvent.isMouseCoalescingEnabled = false; eraseSweep(pv, from: p, to: p) }
        }
    }

    private func eraseSweep(_ pv: PageView, from a: CGPoint, to b: CGPoint) {
        guard case .erase(let gpv, let last, var hits, let unarmed) = gesture, gpv === pv else { return }
        let r = tools.eraserRadius
        let newHits = pv.page.strokes.filter { !hits.contains($0.id) && HitTest.eraser(from: a, to: b, radius: r, hits: $0) }.map(\.id)
        guard !newHits.isEmpty else { return }
        hits.formUnion(newHits)
        gesture = .erase(pv, last: last, hits: hits, unarmed: unarmed)
        pv.hiddenStrokes = hits // vanish immediately; committed as one undo step on release
    }

    private func preciseSweep(_ pv: PageView, from a: CGPoint, to b: CGPoint) {
        let r = tools.eraserRadius
        var area = CGRect.null
        session.liveEdit(pv.page.id, area: CGRect.null) { page in
            var out: [Stroke] = []
            out.reserveCapacity(page.strokes.count)
            for s in page.strokes {
                if let pieces = HitTest.eraseSplit(s, from: a, to: b, radius: r) {
                    area = area.union(s.bounds)
                    out.append(contentsOf: pieces)
                } else {
                    out.append(s)
                }
            }
            page.strokes = out
        }
        if !area.isNull { pv.setNeedsDisplay(area.insetBy(dx: -3, dy: -3)) }
    }

    // MARK: Laser pointer

    private func updateLaser(_ pv: PageView, _ trail: [(CGPoint, TimeInterval)]) {
        let path = CGMutablePath()
        if let f = trail.first {
            path.move(to: f.0)
            if trail.count == 1 { path.addLine(to: CGPoint(x: f.0.x + 0.1, y: f.0.y)) }
            for p in trail.dropFirst() { path.addLine(to: p.0) }
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        laserLayer.path = path
        CATransaction.commit()
    }

    // MARK: Selection

    private func configureOverlayLayers() {
        lassoLayer.fillColor = NSColor.controlAccentColor.withAlphaComponent(0.06).cgColor
        lassoLayer.strokeColor = NSColor.controlAccentColor.cgColor
        lassoLayer.lineWidth = 1.2
        lassoLayer.lineDashPattern = [5, 4]
        lassoLayer.actions = ["path": NSNull()]
        selectionLayer.anchorPoint = .zero
        selectionLayer.actions = ["transform": NSNull(), "sublayers": NSNull(), "position": NSNull(), "bounds": NSNull()]
        selectionContent.anchorPoint = .zero
        selectionContent.actions = ["contents": NSNull(), "position": NSNull(), "bounds": NSNull()]
        selectionBox.fillColor = NSColor.controlAccentColor.withAlphaComponent(0.05).cgColor
        selectionBox.strokeColor = NSColor.controlAccentColor.cgColor
        selectionBox.lineDashPattern = [6, 4]
        selectionBox.actions = ["path": NSNull(), "lineWidth": NSNull()]
        resizeHandle.fillColor = NSColor.white.cgColor
        resizeHandle.strokeColor = NSColor.controlAccentColor.cgColor
        resizeHandle.lineWidth = 1.5
        resizeHandle.actions = ["path": NSNull(), "hidden": NSNull()]
        selectionLayer.addSublayer(selectionContent)
        selectionLayer.addSublayer(selectionBox)
        selectionLayer.addSublayer(resizeHandle)
        laserLayer.fillColor = nil
        laserLayer.strokeColor = NSColor.systemRed.withAlphaComponent(0.9).cgColor
        laserLayer.lineCap = .round
        laserLayer.lineJoin = .round
        laserLayer.shadowColor = NSColor.systemRed.cgColor
        laserLayer.shadowOpacity = 0.9
        laserLayer.shadowOffset = .zero
        laserLayer.actions = ["path": NSNull(), "opacity": NSNull(), "lineWidth": NSNull(), "shadowRadius": NSNull()]
        tapePreview.fillColor = NSColor.systemYellow.withAlphaComponent(0.35).cgColor
        tapePreview.strokeColor = NSColor.systemOrange.cgColor
        tapePreview.lineWidth = 1
        tapePreview.lineDashPattern = [4, 3]
        tapePreview.actions = ["path": NSNull()]
    }

    func handleRect(for sel: Selection) -> CGRect {
        let s = 14 / max(scrollView.magnification, 0.25)
        return CGRect(x: sel.bounds.maxX + 6 - s / 2, y: sel.bounds.maxY + 6 - s / 2, width: s, height: s)
    }

    /// Selects strokes and elements, lifting them into one bitmap layer so they move without redrawing the page.
    func select(strokes: Set<UUID>, elements: Set<UUID>, on pv: PageView) {
        let ss = pv.page.strokes.filter { strokes.contains($0.id) }
        let es = pv.page.elements.filter { elements.contains($0.id) }
        guard !ss.isEmpty || !es.isEmpty else { clearSelection(); return }
        if let old = selection, old.page !== pv { clearSelection() }
        let appearing = selection == nil
        let bounds = (ss.map(\.bounds) + es.map(\.frame)).reduce(CGRect.null) { $0.union($1) }
        let sel = Selection(page: pv, strokes: Set(ss.map(\.id)), elements: Set(es.map(\.id)), bounds: bounds)
        selection = sel

        // Render the lifted items at screen resolution.
        let scale = contentsScale.clamped(1, 8)
        let box = bounds.insetBy(dx: -2, dy: -2).integral
        let w = Int(box.width * scale), h = Int(box.height * scale)
        var image: CGImage?
        if w > 0, h > 0, w * h < 80_000_000,
           let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                               space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
            ctx.translateBy(x: 0, y: CGFloat(h))
            ctx.scaleBy(x: scale, y: -scale)
            ctx.translateBy(x: -box.minX, y: -box.minY)
            var lifted = pv.page.emptyCopy()
            lifted.strokes = ss
            lifted.elements = es
            var o = PageRenderer.Options(cache: pv.cache)
            o.skipBackground = true
            PageRenderer.drawImages(lifted, in: ctx, assets: pv.assets, options: o)
            PageRenderer.drawStrokes(lifted.strokes, kind: .highlighter, in: ctx, options: o)
            PageRenderer.drawTexts(lifted, in: ctx, options: o)
            PageRenderer.drawStrokes(lifted.strokes, kind: .pen, in: ctx, options: o)
            o.revealedTapes = revealedTapes
            PageRenderer.drawTapes(lifted, in: ctx, options: o)
            image = ctx.makeImage()
        }

        CATransaction.begin(); CATransaction.setDisableActions(true)
        selectionLayer.setAffineTransform(.identity)
        selectionLayer.frame = pv.bounds
        selectionContent.frame = box
        selectionContent.contents = image
        let pad = 6 / max(scrollView.magnification, 0.25)
        selectionBox.path = CGPath(roundedRect: bounds.insetBy(dx: -pad, dy: -pad), cornerWidth: pad, cornerHeight: pad, transform: nil)
        selectionBox.lineWidth = 1.2 / max(scrollView.magnification, 0.25)
        resizeHandle.isHidden = sel.singleElement == nil
        resizeHandle.path = CGPath(ellipseIn: handleRect(for: sel), transform: nil)
        if selectionLayer.superlayer !== pv.overlay { pv.overlay.addSublayer(selectionLayer) }
        CATransaction.commit()
        if appearing { animateSelectionAppear() }
        startMarchingAnts(selectionBox)
        pv.hiddenStrokes = sel.strokes
        pv.hiddenElements = sel.elements
        publishSelection()
    }

    private func publishSelection() {
        let has = selection != nil, ink = !(selection?.strokes.isEmpty ?? true), link = selectionLink
        if state.hasSelection != has { state.hasSelection = has }
        if state.selectionHasInk != ink { state.selectionHasInk = ink }
        if state.selectionLink != link { state.selectionLink = link }
        publishAudioSelection()
    }

    func clearSelection() {
        guard let sel = selection else { return }
        selection = nil
        sel.page.hiddenStrokes = []
        sel.page.hiddenElements = []
        CATransaction.begin(); CATransaction.setDisableActions(true)
        selectionContent.contents = nil
        selectionLayer.removeFromSuperlayer()
        CATransaction.commit()
        publishSelection()
    }

    var hasSelection: Bool { selection != nil }

    func deleteSelection() {
        guard let sel = selection else { return }
        clearSelection()
        session.deleteItems(strokes: sel.strokes, elements: sel.elements, on: sel.page.page.id)
    }

    func duplicateSelection() {
        guard let sel = selection else { return }
        let pid = sel.page.page.id
        let strokes = sel.page.page.strokes.filter { sel.strokes.contains($0.id) }.compactMap {
            Stroke(kind: $0.kind, color: $0.color, width: $0.width, points: $0.points)?.translated(dx: 24, dy: 24)
        }
        let elements = sel.page.page.elements.filter { sel.elements.contains($0.id) }.map { e -> PageElement in
            var c = e; c.id = UUID(); c.frame = e.frame.offsetBy(dx: 24, dy: 24); return c
        }
        clearSelection()
        session.editPage(pid, "Duplicate") { p in p.strokes += strokes; p.elements += elements }
        select(strokes: Set(strokes.map(\.id)), elements: Set(elements.map(\.id)), on: sel.page)
    }

    func selectAllOnCurrentPage() {
        guard let pv = currentPageView else { return }
        if tools.tool != .lasso { tools.tool = .lasso }
        DispatchQueue.main.async { self.select(strokes: Set(pv.page.strokes.map(\.id)), elements: Set(pv.page.elements.map(\.id)), on: pv) }
    }

    private func nudgeSelection(dx: CGFloat, dy: CGFloat) {
        guard let sel = selection else { return }
        session.moveItems(strokes: sel.strokes, elements: sel.elements, on: sel.page.page.id, dx: dx, dy: dy)
        select(strokes: sel.strokes, elements: sel.elements, on: sel.page)
    }

    private func recolorSelection(_ color: RGBA) {
        guard let sel = selection, !sel.strokes.isEmpty else { return }
        session.recolorStrokes(sel.strokes, on: sel.page.page.id, to: color)
        select(strokes: sel.strokes, elements: sel.elements, on: sel.page)
    }

    /// Images keep their aspect ratio; text boxes change width and re-flow their height.
    private func resizedFrame(_ el: PageElement, from f: CGRect, by d: CGSize) -> CGRect {
        switch el.content {
        case .image:
            let scale = max((f.width + d.width) / f.width, (f.height + d.height) / f.height, 24 / min(f.width, f.height))
            return PageElement.sanitize(CGRect(x: f.minX, y: f.minY, width: f.width * scale, height: f.height * scale))
        case .text(let t, let st):
            let w = max(40, f.width + d.width)
            return PageElement.sanitize(CGRect(x: f.minX, y: f.minY, width: w, height: PageRenderer.textHeight(t, style: st, width: w)))
        case .link, .tape:
            return PageElement.sanitize(CGRect(x: f.minX, y: f.minY, width: max(12, f.width + d.width), height: max(8, f.height + d.height)))
        }
    }

    func endGesture() {
        holdTimer?.cancel()
        switch gesture {
        case .ink(_, let pv), .shape(_, _, let pv): pv.live.reset()
        case .erase(let pv, _, _, _): pv.hiddenStrokes = []
        case .preciseErase(let pv, _, let original, _): session.commitLiveEdit(pv.page.id, original: original, name: "Erase")
        case .lasso: lassoLayer.removeFromSuperlayer()
        case .moveSelection, .resizeElement: selectionLayer.setAffineTransform(.identity)
        case .pan: NSCursor.pop()
        case .laser: laserLayer.removeFromSuperlayer()
        case .tapeRect: tapePreview.removeFromSuperlayer()
        case .rulerMove, .rulerRotate: break
        case .none: break
        }
        rulerSnap = nil
        gesture = .none
        NSEvent.isMouseCoalescingEnabled = true
    }

    // MARK: Keyboard

    override func keyDown(with e: NSEvent) {
        let plain = e.modifierFlags.intersection([.command, .control, .option]).isEmpty
        let key = e.charactersIgnoringModifiers?.lowercased() ?? ""
        if plain, key == " " {
            if !e.isARepeat { spaceHeld = true; refreshCursor() }
            return
        }
        if plain, let t = Tool.allCases.first(where: { $0.shortcutKey == key }) { tools.tool = t; return }
        let step: CGFloat = e.modifierFlags.contains(.shift) ? 10 : 1
        switch e.keyCode {
        case 51, 117: if selection != nil { deleteSelection(); return }      // delete / forward delete
        case 53:                                                              // escape: cancel, then deselect
            if case .none = gesture {} else { endGesture(); return }
            if selection != nil { clearSelection(); return }
        case 116: scrollToPage(max(0, session.currentPageIndex - 1)); return           // page up
        case 121: scrollToPage(min(pageViews.count - 1, session.currentPageIndex + 1)); return // page down
        case 115: scrollToPage(0); return                                              // home
        case 119: scrollToPage(pageViews.count - 1); return                            // end
        case 36:                                                              // return: edit selected text
            if let sel = selection, let id = sel.singleElement,
               let el = sel.page.page.elements.first(where: { $0.id == id }), el.text != nil {
                clearSelection()
                beginTextEditing(el, on: sel.page)
                return
            }
        case 123: if selection != nil { nudgeSelection(dx: -step, dy: 0); return }
        case 124: if selection != nil { nudgeSelection(dx: step, dy: 0); return }
        case 125: if selection != nil { nudgeSelection(dx: 0, dy: step); return }
        case 126: if selection != nil { nudgeSelection(dx: 0, dy: -step); return }
        default: break
        }
        super.keyDown(with: e)
    }

    override func keyUp(with e: NSEvent) {
        if e.charactersIgnoringModifiers == " " { spaceHeld = false; refreshCursor(); return }
        super.keyUp(with: e)
    }

    override func resignFirstResponder() -> Bool {
        // Losing focus mid-gesture (e.g. a dialog) must never leave a half-drawn stroke on screen.
        if textEditor == nil { endGesture() }
        spaceHeld = false
        return super.resignFirstResponder()
    }
}
