import AppKit
import QuartzCore

enum Motion {
    /// Honour System Settings › Accessibility › Display › Reduce motion.
    static var reduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
}

/// A small frosted message near the bottom of the canvas that confirms an action, then fades away.
final class HUDView: NSVisualEffectView {
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private var hideWork: DispatchWorkItem?

    init() {
        super.init(frame: .zero)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.masksToBounds = true
        alphaValue = 0
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = .labelColor
        icon.symbolConfiguration = .init(pointSize: 13, weight: .semibold)
        icon.contentTintColor = .labelColor
        let stack = NSStackView(views: [icon, label])
        stack.spacing = 7
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 14, bottom: 8, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setAccessibilityRole(.staticText)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil } // never blocks the pen

    func show(_ text: String, symbol: String, duration: TimeInterval = 1.1) {
        label.stringValue = text
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        setAccessibilityLabel(text)
        NSAccessibility.post(element: self, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.low.rawValue])
        hideWork?.cancel()
        if alphaValue < 1 {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = Motion.reduced ? 0 : 0.14
                animator().alphaValue = 1
            }
            if !Motion.reduced, let layer {
                let pop = CASpringAnimation(keyPath: "transform.scale")
                pop.fromValue = 0.92
                pop.toValue = 1
                pop.damping = 14
                pop.stiffness = 260
                pop.duration = pop.settlingDuration
                layer.add(pop, forKey: "pop")
            }
        }
        let work = DispatchWorkItem { [weak self] in
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = Motion.reduced ? 0 : 0.3
                self?.animator().alphaValue = 0
            }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }
}

extension CanvasView {
    func showHUD(_ text: String, symbol: String) {
        hud.show(text, symbol: symbol)
    }

    /// Erased strokes fade and shrink slightly instead of blinking out.
    func fadeOut(_ strokes: [Stroke], on pv: PageView) {
        guard !Motion.reduced, !strokes.isEmpty else { return }
        let container = CALayer()
        container.frame = pv.bounds
        for s in strokes.prefix(80) {
            let l = CAShapeLayer()
            l.path = pv.cache.path(for: s)
            l.fillColor = s.color.cgColor
            l.contentsScale = contentsScale
            container.addSublayer(l)
        }
        pv.overlay.addSublayer(container)
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.22)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        CATransaction.setCompletionBlock { container.removeFromSuperlayer() }
        container.opacity = 0
        CATransaction.commit()
    }

    /// Selection box fades in, then its dashes keep marching so it's clearly "live".
    func animateSelectionAppear() {
        guard !Motion.reduced else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = 0.15
        selectionLayer.add(fade, forKey: "appear")
    }

    func startMarchingAnts(_ box: CAShapeLayer) {
        guard !Motion.reduced, box.animation(forKey: "ants") == nil else { return }
        let ants = CABasicAnimation(keyPath: "lineDashPhase")
        ants.fromValue = 0
        ants.toValue = 20
        ants.duration = 0.8
        ants.repeatCount = .infinity
        box.add(ants, forKey: "ants")
    }

    /// Cross-fade used when a held stroke snaps to a clean shape.
    func crossFade(_ layer: CALayer, duration: CFTimeInterval = 0.16) {
        guard !Motion.reduced else { return }
        let t = CATransition()
        t.type = .fade
        t.duration = duration
        layer.add(t, forKey: "crossfade")
    }
}
