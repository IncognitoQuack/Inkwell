import AppKit
import QuartzCore
import Combine

/// The zoom window: a magnified writing strip docked under the page. You write large in the strip and
/// the ink lands small inside the box shown on the page, which moves along as you write. Built for
/// small tablets like the G640, where writing small text directly is hard.
final class ZoomWriter: NSView {
    static let height: CGFloat = 230
    static let controlsWidth: CGFloat = 132
    static let zoomRange: ClosedRange<CGFloat> = 1.5...6

    private unowned let canvas: CanvasView
    let paper = ZoomPaper()
    private let targetLayer = CAShapeLayer()
    private let controls: ZoomControlsView
    let model = ZoomModel()

    /// The box on the page (page coordinates) that the strip shows.
    private(set) var target = CGRect.zero
    private(set) weak var pageView: PageView?

    init(canvas: CanvasView) {
        self.canvas = canvas
        controls = ZoomControlsView(model: model)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        let border = NSBox()
        border.boxType = .separator
        for v in [paper, controls, border] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            border.topAnchor.constraint(equalTo: topAnchor),
            border.leadingAnchor.constraint(equalTo: leadingAnchor),
            border.trailingAnchor.constraint(equalTo: trailingAnchor),
            border.heightAnchor.constraint(equalToConstant: 1),
            paper.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            paper.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            paper.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            paper.trailingAnchor.constraint(equalTo: controls.leadingAnchor, constant: -10),
            controls.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            controls.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            controls.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            controls.widthAnchor.constraint(equalToConstant: Self.controlsWidth),
        ])
        paper.writer = self
        model.zoom = CGFloat(UserDefaults.standard.object(forKey: "zoomWindowZoom") as? Double ?? 2.5).clamped(Self.zoomRange.lowerBound, Self.zoomRange.upperBound)
        model.onAdvance = { [weak self] in self?.advance() }
        model.onBack = { [weak self] in self?.advance(back: true) }
        model.onNewLine = { [weak self] in self?.newLine() }
        model.onZoom = { [weak self] z in self?.setZoom(z) }
        model.onClose = { [weak self] in self?.canvas.toggleZoomWriter() }

        targetLayer.fillColor = NSColor.controlAccentColor.withAlphaComponent(0.08).cgColor
        targetLayer.strokeColor = NSColor.controlAccentColor.cgColor
        targetLayer.lineWidth = 1.5
        targetLayer.actions = ["path": NSNull(), "lineWidth": NSNull()]
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        // The strip's shape decides the box's shape: keep the box's top-left, refit its size.
        if let pv = pageView { place(CGRect(origin: target.origin, size: boxSize), on: pv, animated: false) }
    }

    var zoom: CGFloat { model.zoom }
    private var boxSize: CGSize {
        CGSize(width: max(40, paper.bounds.width / zoom), height: max(20, paper.bounds.height / zoom))
    }

    // MARK: Placement

    func attach(to pv: PageView, near p: CGPoint? = nil) {
        let page = pv.page
        let margin = Self.leftMargin(page)
        let start = p ?? CGPoint(x: margin, y: canvas.visibleCenter(of: pv).y - boxSize.height / 2)
        place(CGRect(origin: start, size: boxSize), on: pv, animated: false)
    }

    func moveTarget(to p: CGPoint, on pv: PageView) {
        // The click becomes the box's left edge, centred vertically on the clicked line.
        place(CGRect(x: p.x - 8, y: p.y - boxSize.height / 2, width: boxSize.width, height: boxSize.height), on: pv, animated: true)
    }

    /// Clamps the box onto the page, draws it, and scrolls the main view so it stays visible.
    private func place(_ r: CGRect, on pv: PageView, animated: Bool) {
        let page = pv.page.rect
        var box = r
        box.size.width = min(box.width, page.width)
        box.size.height = min(box.height, page.height)
        box.origin.x = box.minX.clamped(page.minX, page.maxX - box.width)
        box.origin.y = box.minY.clamped(page.minY, page.maxY - box.height)
        let oldPath = targetLayer.path
        if pageView !== pv {
            targetLayer.removeFromSuperlayer()
            pv.overlay.addSublayer(targetLayer)
            pageView = pv
        }
        target = box
        let path = CGPath(roundedRect: box, cornerWidth: 4, cornerHeight: 4, transform: nil)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        targetLayer.lineWidth = 1.5 / max(canvas.scrollView.magnification, 0.25)
        targetLayer.path = path
        CATransaction.commit()
        if animated, !Motion.reduced, let oldPath {
            let a = CABasicAnimation(keyPath: "path")
            a.fromValue = oldPath
            a.toValue = path
            a.duration = 0.2
            a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            targetLayer.add(a, forKey: "move")
        }
        paper.needsDisplay = true
        window?.invalidateCursorRects(for: paper)
        pv.scrollToVisible(box.insetBy(dx: -40, dy: -40))
    }

    static func leftMargin(_ page: Page) -> CGFloat { page.style == .ruled && page.background == nil ? 80 : 24 }

    /// Line step: one ruled line pair on ruled paper, half a box elsewhere.
    private func lineStep(_ page: Page) -> CGFloat {
        page.style == .ruled && page.background == nil ? max(28, (target.height * 0.55 / 28).rounded() * 28) : target.height * 0.55
    }

    func advance(back: Bool = false) {
        guard let pv = pageView else { return }
        let step = target.width * 0.5
        if back {
            place(target.offsetBy(dx: -step, dy: 0), on: pv, animated: true)
        } else if target.maxX + 1 >= pv.page.rect.maxX - 4 {
            newLine()
        } else {
            place(target.offsetBy(dx: step, dy: 0), on: pv, animated: true)
        }
    }

    func newLine() {
        guard let pv = pageView else { return }
        let page = pv.page
        let y = target.minY + lineStep(page)
        if y + target.height > page.rect.maxY + 1 {
            // End of this page: continue at the top of the next one, if there is one.
            if let i = canvas.pageViews.firstIndex(where: { $0 === pv }), i + 1 < canvas.pageViews.count {
                let next = canvas.pageViews[i + 1]
                place(CGRect(x: Self.leftMargin(next.page), y: next.page.style == .ruled ? 80 : 24, width: target.width, height: target.height), on: next, animated: false)
                canvas.showHUD("Next page", symbol: "arrow.down.doc")
            } else {
                canvas.showHUD("End of the last page", symbol: "exclamationmark.circle")
            }
            return
        }
        place(CGRect(x: Self.leftMargin(page), y: y, width: target.width, height: target.height), on: pv, animated: true)
    }

    private func setZoom(_ z: CGFloat) {
        model.zoom = z.clamped(Self.zoomRange.lowerBound, Self.zoomRange.upperBound)
        UserDefaults.standard.set(Double(model.zoom), forKey: "zoomWindowZoom")
        if let pv = pageView { place(CGRect(origin: target.origin, size: boxSize), on: pv, animated: true) }
    }

    /// After writing near the strip's right edge, slide on so there's always room for the next word.
    func strokeFinished() {
        guard let pv = pageView, let last = pv.page.strokes.last, last.bounds.intersects(target) else { return }
        if last.bounds.maxX > target.minX + target.width * 0.72 { advance() }
    }

    func pageChanged(_ id: UUID) {
        guard pageView?.page.id == id else { return }
        paper.needsDisplay = true
    }

    func detach() {
        targetLayer.removeFromSuperlayer()
        pageView = nil
    }

    // MARK: Input from the strip

    /// Page point for an event in the strip.
    func pagePoint(_ e: NSEvent) -> CGPoint {
        let p = paper.convert(e.locationInWindow, from: nil)
        return CGPoint(x: target.minX + p.x / zoom, y: target.minY + p.y / zoom)
    }

    func forwardDown(_ e: NSEvent) {
        guard let pv = pageView else { return }
        canvas.inputMapper = { [weak self] ev in self?.pagePoint(ev) ?? .zero }
        canvas.inputScale = zoom
        pv.live.mirror = paper.live
        pv.live.mirrorContentsScale = (window?.backingScaleFactor ?? 2) * zoom
        paper.syncLiveTransform()
        canvas.pointerDown(e, on: pv)
    }

    func forwardDragged(_ e: NSEvent) { canvas.pointerDragged(e) }

    func forwardUp(_ e: NSEvent) {
        let wasInk: Bool
        if case .ink = canvas.gesture { wasInk = true } else if case .shape = canvas.gesture { wasInk = true } else { wasInk = false }
        canvas.pointerUp(e)
        canvas.inputMapper = nil
        canvas.inputScale = nil
        pageView?.live.mirror = nil
        paper.live.reset()
        if wasInk { strokeFinished() }
    }

    /// Upper pen button in the strip: drag slides the box, a click undoes.
    private var panStart: (NSPoint, CGRect)?
    func panDown(_ e: NSEvent) { panStart = (e.locationInWindow, target) }
    func panDragged(_ e: NSEvent) {
        guard let (start, box) = panStart, let pv = pageView else { return }
        let d = CGPoint(x: (e.locationInWindow.x - start.x) / zoom, y: -(e.locationInWindow.y - start.y) / zoom)
        place(box.offsetBy(dx: -d.x, dy: -d.y), on: pv, animated: false)
    }
    func panUp(_ e: NSEvent) {
        if let (start, _) = panStart, hypot(e.locationInWindow.x - start.x, e.locationInWindow.y - start.y) < 4 {
            canvas.session.undoManager.undo()
        }
        panStart = nil
    }

    func cursor() -> NSCursor { canvas.currentCursor(magnification: zoom) }
}

/// Draws the magnified page region and hosts the mirrored live stroke.
final class ZoomPaper: NSView {
    weak var writer: ZoomWriter?
    let live = LiveInk()
    private let pageSpace = CALayer()
    private let guide = CAShapeLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.borderWidth = 1
        pageSpace.anchorPoint = .zero
        pageSpace.actions = ["sublayerTransform": NSNull(), "bounds": NSNull(), "position": NSNull()]
        pageSpace.addSublayer(live.layer)
        layer?.addSublayer(pageSpace)
        guide.strokeColor = NSColor.controlAccentColor.withAlphaComponent(0.35).cgColor
        guide.lineDashPattern = [4, 4]
        guide.lineWidth = 1
        guide.actions = ["path": NSNull()]
        layer?.addSublayer(guide)
        setAccessibilityLabel("Zoom writing area")
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        pageSpace.frame = bounds
        // Where auto-advance kicks in.
        let x = bounds.width * 0.72
        guide.path = CGPath(rect: CGRect(x: x, y: 8, width: 0.01, height: bounds.height - 16), transform: nil)
        syncLiveTransform()
    }

    /// Page coordinates → strip coordinates for the mirrored live ink.
    func syncLiveTransform() {
        guard let w = writer, let pv = w.pageView else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        pageSpace.sublayerTransform = CATransform3DMakeAffineTransform(
            CGAffineTransform(scaleX: w.zoom, y: w.zoom).translatedBy(x: -w.target.minX, y: -w.target.minY))
        live.layer.frame = pv.bounds
        CATransaction.commit()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext, let w = writer, let pv = w.pageView else { return }
        ctx.setFillColor(pv.page.paper.rgba.cgColor)
        ctx.fill(bounds)
        ctx.saveGState()
        ctx.scaleBy(x: w.zoom, y: w.zoom)
        ctx.translateBy(x: -w.target.minX, y: -w.target.minY)
        var o = PageRenderer.Options(clip: w.target, cache: pv.cache)
        o.hiddenStrokes = pv.hiddenStrokes
        o.hiddenElements = pv.hiddenElements
        o.revealedTapes = pv.canvas?.revealedTapes ?? []
        o.replay = pv.canvas?.replay
        PageRenderer.draw(pv.page, in: ctx, assets: pv.assets, options: o)
        ctx.restoreGState()
        syncLiveTransform()
    }

    override func mouseDown(with e: NSEvent) { writer?.forwardDown(e) }
    override func mouseDragged(with e: NSEvent) { writer?.forwardDragged(e) }
    override func mouseUp(with e: NSEvent) { writer?.forwardUp(e) }
    override func rightMouseDown(with e: NSEvent) { writer?.forwardDown(e) }
    override func rightMouseDragged(with e: NSEvent) { writer?.forwardDragged(e) }
    override func rightMouseUp(with e: NSEvent) { writer?.forwardUp(e) }
    override func otherMouseDown(with e: NSEvent) { writer?.panDown(e) }
    override func otherMouseDragged(with e: NSEvent) { writer?.panDragged(e) }
    override func otherMouseUp(with e: NSEvent) { writer?.panUp(e) }

    override func resetCursorRects() {
        if let c = writer?.cursor() { addCursorRect(bounds, cursor: c) }
    }
}

final class ZoomModel: ObservableObject {
    @Published var zoom: CGFloat = 2.5
    var onAdvance: () -> Void = {}
    var onBack: () -> Void = {}
    var onNewLine: () -> Void = {}
    var onZoom: (CGFloat) -> Void = { _ in }
    var onClose: () -> Void = {}
}

/// The strip's control column, in AppKit so it lays out immediately and deterministically.
final class ZoomControlsView: NSView {
    private let model: ZoomModel
    private let zoomLabel = NSTextField(labelWithString: "")
    private var bag: AnyCancellable?

    init(model: ZoomModel) {
        self.model = model
        super.init(frame: .zero)
        zoomLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        zoomLabel.alignment = .center
        zoomLabel.widthAnchor.constraint(equalToConstant: 34).isActive = true
        let zoomRow = row([button("minus.magnifyingglass", "Less zoom (bigger box)", #selector(zoomOut)), zoomLabel,
                           button("plus.magnifyingglass", "More zoom (bigger writing)", #selector(zoomIn))])
        let moveRow = row([button("arrow.left", "Move box left", #selector(back)),
                           button("arrow.right", "Move box right", #selector(advance)),
                           button("return", "Next line", #selector(newLine))])
        let hint = NSTextField(wrappingLabelWithString: "⌥-click the page to move the box")
        hint.font = .systemFont(ofSize: 10)
        hint.textColor = .secondaryLabelColor
        hint.alignment = .center
        hint.preferredMaxLayoutWidth = ZoomWriter.controlsWidth - 8
        let close = NSButton(title: "Close", image: NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)!,
                             target: self, action: #selector(closeStrip))
        close.imagePosition = .imageLeading
        close.bezelStyle = .rounded
        close.toolTip = "Close zoom window (⌥⌘Z)"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .vertical)
        let stack = NSStackView(views: [zoomRow, moveRow, hint, spacer, close])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            hint.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor),
        ])
        bag = model.$zoom.sink { [weak self] z in self?.zoomLabel.stringValue = String(format: "%.1f×", z) }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private func row(_ views: [NSView]) -> NSStackView {
        let r = NSStackView(views: views)
        r.orientation = .horizontal
        r.spacing = 4
        return r
    }

    private func button(_ symbol: String, _ help: String, _ action: Selector) -> NSButton {
        let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: help)!, target: self, action: action)
        b.bezelStyle = .rounded
        b.toolTip = help
        b.setAccessibilityLabel(help)
        b.widthAnchor.constraint(equalToConstant: 38).isActive = true
        return b
    }

    @objc private func zoomOut() { model.onZoom(model.zoom - 0.5) }
    @objc private func zoomIn() { model.onZoom(model.zoom + 0.5) }
    @objc private func back() { model.onBack() }
    @objc private func advance() { model.onAdvance() }
    @objc private func newLine() { model.onNewLine() }
    @objc private func closeStrip() { model.onClose() }
}

extension CanvasView {
    var isZoomWriterOpen: Bool { zoomWriter != nil }

    /// Opens or closes the zoom window under the pages.
    func toggleZoomWriter() {
        if let z = zoomWriter {
            z.detach()
            zoomWriterHeight?.constant = 0
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = Motion.reduced ? 0 : 0.22
                ctx.allowsImplicitAnimation = true
                layoutSubtreeIfNeeded()
            }, completionHandler: { [weak self] in
                z.removeFromSuperview()
                // Reopened during the closing animation: the new strip owns the layout now.
                guard let self, self.zoomWriter == nil else { return }
                // Re-pin the pages to the bottom before the strip (and its constraint) goes away.
                self.scrollBottom?.isActive = false
                let c = self.scrollView.bottomAnchor.constraint(equalTo: self.bottomAnchor)
                c.isActive = true
                self.scrollBottom = c
            })
            zoomWriter = nil
            state.zoomWindowOpen = false
            return
        }
        guard let pv = currentPageView else { return }
        endTextEditing()
        let z = ZoomWriter(canvas: self)
        z.translatesAutoresizingMaskIntoConstraints = false
        addSubview(z, positioned: .below, relativeTo: hud)
        let h = z.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            z.leadingAnchor.constraint(equalTo: leadingAnchor),
            z.trailingAnchor.constraint(equalTo: trailingAnchor),
            z.bottomAnchor.constraint(equalTo: bottomAnchor),
            h,
        ])
        scrollBottom?.isActive = false
        let attach = scrollView.bottomAnchor.constraint(equalTo: z.topAnchor)
        attach.isActive = true
        scrollBottom = attach
        zoomWriter = z
        zoomWriterHeight = h
        state.zoomWindowOpen = true
        layoutSubtreeIfNeeded()
        h.constant = ZoomWriter.height
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Motion.reduced ? 0 : 0.25
            ctx.allowsImplicitAnimation = true
            layoutSubtreeIfNeeded()
        }
        if tools.tool != .pen && tools.tool != .highlighter && tools.tool != .eraser { tools.tool = .pen }
        z.attach(to: pv)
    }
}
