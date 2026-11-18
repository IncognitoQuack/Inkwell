import AppKit
import QuartzCore

/// Ruler, study tape and maths on the canvas.
extension CanvasView {
    // MARK: Ruler

    var isRulerShown: Bool { ruler != nil }

    func toggleRuler() {
        if ruler != nil {
            ruler = nil
            state.rulerShown = false
            if Motion.reduced { rulerLayer.removeFromSuperlayer() } else {
                CATransaction.begin()
                CATransaction.setCompletionBlock { [weak self] in if self?.ruler == nil { self?.rulerLayer.removeFromSuperlayer() } }
                rulerLayer.opacity = 0
                CATransaction.commit()
            }
            return
        }
        guard let pv = currentPageView else { return }
        ruler = Ruler(page: pv, center: visibleCenter(of: pv), angle: 0)
        state.rulerShown = true
        buildRulerLayer()
        rulerLayer.removeFromSuperlayer()
        pv.overlay.addSublayer(rulerLayer)
        layoutRuler()
        rulerLayer.opacity = 1
        showHUD("Ruler: draw along an edge · drag to move · knob rotates", symbol: "ruler")
    }

    private func buildRulerLayer() {
        guard let r = ruler else { return }
        rulerLayer.sublayers?.forEach { $0.removeFromSuperlayer() }
        rulerLayer.bounds = CGRect(x: -r.length / 2, y: -r.width / 2, width: r.length, height: r.width)
        rulerLayer.actions = ["position": NSNull(), "transform": NSNull(), "sublayers": NSNull(), "bounds": NSNull()]
        let body = CAShapeLayer()
        body.path = CGPath(roundedRect: rulerLayer.bounds, cornerWidth: 8, cornerHeight: 8, transform: nil)
        body.fillColor = NSColor(white: 0.97, alpha: 0.82).cgColor
        body.strokeColor = NSColor(white: 0.35, alpha: 0.5).cgColor
        body.lineWidth = 1
        body.shadowOpacity = 0.18
        body.shadowRadius = 4
        body.shadowOffset = .zero
        rulerLayer.addSublayer(body)
        // Ticks in millimetres (2.835 pt), longer every 5 mm and centimetre, along both long edges.
        let ticks = CGMutablePath()
        let mm: CGFloat = 2.835
        var i = 0
        var x = -r.length / 2 + 12
        while x <= r.length / 2 - 40 {
            let len: CGFloat = i % 10 == 0 ? 14 : i % 5 == 0 ? 9 : 5
            ticks.move(to: CGPoint(x: x, y: -r.width / 2)); ticks.addLine(to: CGPoint(x: x, y: -r.width / 2 + len))
            ticks.move(to: CGPoint(x: x, y: r.width / 2)); ticks.addLine(to: CGPoint(x: x, y: r.width / 2 - len))
            x += mm
            i += 1
        }
        let t = CAShapeLayer()
        t.path = ticks
        t.strokeColor = NSColor(white: 0.25, alpha: 0.7).cgColor
        t.lineWidth = 0.6
        t.fillColor = nil
        rulerLayer.addSublayer(t)
        // Rotation knob at the right end.
        let knob = CAShapeLayer()
        knob.path = CGPath(ellipseIn: CGRect(x: r.length / 2 - 26, y: -9, width: 18, height: 18), transform: nil)
        knob.fillColor = NSColor.controlAccentColor.withAlphaComponent(0.85).cgColor
        rulerLayer.addSublayer(knob)
        let label = CATextLayer()
        label.name = "angle"
        label.fontSize = 11
        label.alignmentMode = .center
        label.foregroundColor = NSColor(white: 0.2, alpha: 0.9).cgColor
        label.frame = CGRect(x: -40, y: -8, width: 80, height: 16)
        label.contentsScale = 4
        label.isGeometryFlipped = true
        label.actions = ["string": NSNull(), "contents": NSNull()]
        rulerLayer.addSublayer(label)
    }

    private func layoutRuler() {
        guard let r = ruler else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        rulerLayer.position = r.center
        rulerLayer.setAffineTransform(CGAffineTransform(rotationAngle: r.angle))
        var deg = (r.angle * 180 / .pi).truncatingRemainder(dividingBy: 360)
        if deg < 0 { deg += 360 }
        (rulerLayer.sublayers?.first { $0.name == "angle" } as? CATextLayer)?.string = String(format: "%.0f°", deg)
        CATransaction.commit()
    }

    /// Point in the ruler's own frame (x along it, y across it).
    private func rulerLocal(_ p: CGPoint) -> CGPoint? {
        guard let r = ruler else { return nil }
        let dx = p.x - r.center.x, dy = p.y - r.center.y
        return CGPoint(x: dx * cos(-r.angle) - dy * sin(-r.angle), y: dx * sin(-r.angle) + dy * cos(-r.angle))
    }

    func rulerGesture(at p: CGPoint, on pv: PageView) -> Gesture? {
        guard let r = ruler, let l = rulerLocal(p), abs(l.x) <= r.length / 2, abs(l.y) <= r.width / 2 else { return nil }
        if l.x > r.length / 2 - 34 {
            return .rulerRotate(pv, center: r.center, startAngle: atan2(p.y - r.center.y, p.x - r.center.x), rulerAngle: r.angle)
        }
        return .rulerMove(pv, start: p, center: r.center)
    }

    func moveRuler(to c: CGPoint, on pv: PageView) {
        ruler?.center = CGPoint(x: c.x.clamped(0, pv.bounds.width), y: c.y.clamped(0, pv.bounds.height))
        layoutRuler()
    }

    func rotateRuler(to a: CGFloat) {
        ruler?.angle = a
        layoutRuler()
    }

    /// If `p` is just outside one of the ruler's long edges, the line that ink should follow.
    func rulerEdge(near p: CGPoint, on pv: PageView) -> (origin: CGPoint, dir: CGVector)? {
        guard let r = ruler, r.page === pv, let l = rulerLocal(p), abs(l.x) <= r.length / 2 + 20 else { return nil }
        let gap = abs(l.y) - r.width / 2
        guard gap >= -2, gap <= 20 / max(inputMagnification, 0.25) else { return nil }
        let side: CGFloat = l.y < 0 ? -1 : 1
        let dir = CGVector(dx: cos(r.angle), dy: sin(r.angle))
        let normal = CGVector(dx: -sin(r.angle), dy: cos(r.angle))
        // Ink rides on the edge, offset by half the nib so it touches without overlapping the ruler.
        let off = r.width / 2 + CGFloat(tools.tool == .highlighter ? tools.highlighterWidth : tools.penWidth) / 2 + 1
        return (CGPoint(x: r.center.x + normal.dx * off * side, y: r.center.y + normal.dy * off * side), dir)
    }

    func snapToRuler(_ p: CGPoint) -> CGPoint {
        guard let s = rulerSnap else { return p }
        let t = (p.x - s.origin.x) * s.dir.dx + (p.y - s.origin.y) * s.dir.dy
        return CGPoint(x: s.origin.x + s.dir.dx * t, y: s.origin.y + s.dir.dy * t)
    }

    // MARK: Study tape

    func toggleTape(_ id: UUID, on pv: PageView) {
        if revealedTapes.contains(id) { revealedTapes.remove(id) } else { revealedTapes.insert(id) }
        if let e = pv.page.elements.first(where: { $0.id == id }) { pv.setNeedsDisplay(e.frame.insetBy(dx: -4, dy: -4)) }
        zoomWriter?.pageChanged(pv.page.id)
    }

    /// Peels back every tape in the notebook, or covers them all again.
    func setAllTapes(revealed: Bool) {
        revealedTapes = revealed ? Set(session.notebook.pages.flatMap { $0.elements.filter(\.isTape).map(\.id) }) : []
        for pv in pageViews where pv.page.elements.contains(where: \.isTape) { pv.needsDisplay = true }
        showHUD(revealed ? "All tape peeled back" : "All tape covering", symbol: "rectangle.dashed")
    }

    var tapeCount: Int { session.notebook.pages.reduce(0) { $0 + $1.elements.filter(\.isTape).count } }

    // MARK: Maths

    /// After a pen stroke: if the last two strokes form "=", read the sum before it once writing pauses.
    func scheduleAutoSolve(on pv: PageView) {
        autoSolveWork?.cancel()
        guard tools.autoSolve else { return }
        let strokes = pv.page.strokes
        guard strokes.count >= 3, EqualsDetector.isEqualsSign(strokes[strokes.count - 2], strokes[strokes.count - 1]) else { return }
        let work = DispatchWorkItem { [weak self, weak pv] in
            guard let self, let pv else { return }
            self.autoSolve(on: pv)
        }
        autoSolveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: work)
    }

    func autoSolve(on pv: PageView) {
        let strokes = pv.page.strokes
        guard strokes.count >= 3 else { return }
        let a = strokes[strokes.count - 2], b = strokes[strokes.count - 1]
        guard EqualsDetector.isEqualsSign(a, b) else { return }
        let eq = a.bounds.union(b.bounds).insetBy(dx: CGFloat(a.width) / 2, dy: CGFloat(a.width) / 2)
        let sum = EqualsDetector.sum(before: eq, in: strokes, excluding: [a.id, b.id])
        guard !sum.isEmpty else { return }
        let key = Set(sum.map(\.id)).union([a.id, b.id])
        guard !answeredSums.contains(key) else { return }
        answeredSums.insert(key)
        let recognizer = mathRecognizer
        let finish: (String) -> Void = { [weak self, weak pv] text in
            guard let self, let pv else { return }
            // Ignore if the sum was erased or changed meanwhile.
            let now = Set(pv.page.strokes.map(\.id))
            guard key.isSubset(of: now) else { return }
            guard let r = MathEval.solve(text.replacingOccurrences(of: "\n", with: "")) else {
                // "x = y" in ordinary notes isn't a failed sum: only speak up when it looked like arithmetic.
                let looksNumeric = text.contains(where: \.isNumber) && text.contains(where: { "+-*/×÷x^%".contains($0) })
                if looksNumeric {
                    self.showHUD("Couldn’t read “\(text.prefix(24))” as a sum", symbol: "questionmark.circle")
                }
                self.answeredSums.remove(key) // let a corrected sum try again
                return
            }
            var st = TextStyle()
            st.font = .hand
            st.color = RGBA(0.10, 0.42, 0.95)
            let lineH = max(eq.height * 3.2, 24)
            st.size = Double(lineH * 0.62).clamped(14, 72)
            let s = r.formatted
            let w = max(30, CGFloat(s.count) * CGFloat(st.size) * 0.62 + 10)
            let h = PageRenderer.textHeight(s, style: st, width: w)
            let el = PageElement(frame: CGRect(x: eq.maxX + 6, y: eq.midY - h / 2, width: w, height: h), content: .text(s, st))
            self.session.upsertElement(el, on: pv.page.id, actionName: "Answer")
            if !Motion.reduced { self.flash(el.frame, on: pv) }
        }
        if let recognizer {
            finish(recognizer(sum))
        } else {
            DispatchQueue.global(qos: .userInitiated).async {
                let text = HandwritingRecognizer.recognize(strokes: sum.sorted { $0.bounds.minX < $1.bounds.minX }, languageCorrection: false)
                DispatchQueue.main.async { finish(text) }
            }
        }
    }

    /// A soft glow where something just appeared.
    func flash(_ rect: CGRect, on pv: PageView) {
        let l = CAShapeLayer()
        l.path = CGPath(roundedRect: rect.insetBy(dx: -4, dy: -3), cornerWidth: 6, cornerHeight: 6, transform: nil)
        l.fillColor = NSColor.controlAccentColor.withAlphaComponent(0.18).cgColor
        pv.overlay.addSublayer(l)
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.9)
        CATransaction.setCompletionBlock { l.removeFromSuperlayer() }
        l.opacity = 0
        CATransaction.commit()
    }

    /// Reads the selected handwriting as a sum and writes "= result" to the right of it.
    func solveSelection() {
        guard let sel = selection, !sel.strokes.isEmpty else { NSSound.beep(); return }
        let strokes = sel.page.page.strokes.filter { sel.strokes.contains($0.id) }
        let pv = sel.page, bounds = sel.bounds
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let text = HandwritingRecognizer.recognize(strokes: strokes.sorted { $0.bounds.minX < $1.bounds.minX }, languageCorrection: false)
            DispatchQueue.main.async {
                guard let self else { return }
                guard let r = MathEval.solve(text.replacingOccurrences(of: "\n", with: "")) else {
                    let alert = NSAlert()
                    alert.messageText = text.isEmpty ? "No handwriting was recognised." : "“\(text)” isn’t a sum Strokebook can solve."
                    alert.informativeText = "Write arithmetic like 12 × (3 + 4), 2^10 or 15% × 80, then select it and choose Solve."
                    if let w = self.window { alert.beginSheetModal(for: w) }
                    return
                }
                self.insertResult(r, beside: bounds, strokes: strokes, on: pv)
            }
        }
    }

    func insertResult(_ r: MathEval.Result, beside bounds: CGRect, strokes: [Stroke], on pv: PageView) {
        var st = tools.textStyle
        st.size = (Double(bounds.height) * 0.6).clamped(12, 72)
        st.color = strokes.first.map { $0.color.opaque } ?? st.color
        let s = "= " + r.formatted
        let w = max(40, CGFloat(s.count) * CGFloat(st.size) * 0.62 + 12)
        let el = PageElement(frame: CGRect(x: bounds.maxX + 8, y: bounds.midY - CGFloat(st.size) * 0.7,
                                           width: w, height: PageRenderer.textHeight(s, style: st, width: w)),
                             content: .text(s, st))
        session.upsertElement(el, on: pv.page.id, actionName: "Solve")
        showHUD("\(r.expression) = \(r.formatted)", symbol: "function")
    }
}
