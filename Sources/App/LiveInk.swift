import AppKit
import QuartzCore

/// Renders the stroke being drawn right now with Core Animation, independent of the page's normal
/// drawing. Work per pen sample stays constant however long the stroke gets: finished segments are
/// frozen into chunk layers and only the last few segments (plus a predicted tip) are rebuilt.
final class LiveInk {
    let layer = CALayer()
    private var chunks: [CAShapeLayer] = []
    private var active: CAShapeLayer?
    private var activePath = CGMutablePath()
    private var activeCapsules = 0
    private let tail = CAShapeLayer()
    private var doneSegments = 0
    private var lastSample: NibSample?
    private var kind: ToolKind = .pen
    private var width: Float = 2
    private var fill: CGColor = .black
    private var contentsScale: CGFloat = 2

    private static let capsulesPerChunk = 300

    /// A second LiveInk that repeats everything this one draws (the zoom window's magnified copy).
    weak var mirror: LiveInk?
    /// Resolution the mirror renders at (its magnification × screen scale).
    var mirrorContentsScale: CGFloat = 2

    init() {
        layer.anchorPoint = .zero
        layer.masksToBounds = false
        layer.actions = ["sublayers": NSNull(), "contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        configure(tail)
        layer.addSublayer(tail)
    }

    func begin(kind: ToolKind, color: RGBA, width: Float, frame: CGRect, contentsScale: CGFloat) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        reset()
        self.kind = kind
        self.width = width
        self.contentsScale = contentsScale
        // Layers are filled opaque and the container carries the alpha, so overlapping chunks of a
        // translucent stroke never double up into darker seams.
        fill = color.opaque.cgColor
        layer.opacity = color.a
        layer.compositingFilter = kind == .highlighter ? "multiplyBlendMode" : nil
        layer.frame = frame
        tail.fillColor = fill
        tail.contentsScale = contentsScale
        layer.isHidden = false
        CATransaction.commit()
        mirror?.begin(kind: kind, color: color, width: width, frame: frame, contentsScale: mirrorContentsScale)
    }

    func update(points: [InkPoint], predicted: InkPoint?) {
        guard !points.isEmpty else { return }
        mirror?.update(points: points, predicted: predicted)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        // Segment i (points i → i+1) is final once point i+2 exists, since the spline looks one ahead.
        let finalSegments = max(0, points.count - 3)
        if finalSegments > doneSegments || (doneSegments == 0 && lastSample == nil) {
            var samples = InkGeometry.smoothSamples(points, kind: kind, width: width, fromSegment: doneSegments, toSegment: finalSegments)
            if let last = lastSample {
                samples.insert(last, at: 0)
                InkGeometry.appendOutline(of: samples, to: activePath, startingAt: 1)
            } else {
                InkGeometry.appendOutline(of: samples, to: activePath)
            }
            activeCapsules += samples.count
            lastSample = samples.last
            doneSegments = finalSegments
            if activeCapsules >= Self.capsulesPerChunk { freezeActive() } else { refreshActive() }
        }

        var tailPoints = points
        if let p = predicted { tailPoints.append(p) }
        var tailSamples = InkGeometry.smoothSamples(tailPoints, kind: kind, width: width, fromSegment: doneSegments)
        let tailPath = CGMutablePath()
        if let last = lastSample {
            tailSamples.insert(last, at: 0)
            InkGeometry.appendOutline(of: tailSamples, to: tailPath, startingAt: 1)
        } else {
            InkGeometry.appendOutline(of: tailSamples, to: tailPath)
        }
        tail.path = tailPath
    }

    /// Shows a finished geometry outright (used for straightened lines).
    func show(stroke: Stroke) {
        mirror?.show(stroke: stroke)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for c in chunks { c.removeFromSuperlayer() }
        chunks.removeAll()
        active = nil
        activePath = CGMutablePath()
        tail.path = InkGeometry.outlinePath(for: stroke)
        CATransaction.commit()
    }

    func reset() {
        mirror?.reset()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for c in chunks { c.removeFromSuperlayer() }
        chunks.removeAll()
        active = nil
        activePath = CGMutablePath()
        activeCapsules = 0
        doneSegments = 0
        lastSample = nil
        tail.path = nil
        layer.isHidden = true
        CATransaction.commit()
    }

    private func refreshActive() {
        activeChunk().path = activePath
    }

    /// Freezes the active chunk: its path never changes again, so Core Animation never re-renders it.
    private func freezeActive() {
        activeChunk().path = activePath
        active = nil
        activePath = CGMutablePath()
        activeCapsules = 0
    }

    private func activeChunk() -> CAShapeLayer {
        if let a = active { return a }
        let c = CAShapeLayer()
        configure(c)
        c.fillColor = fill
        c.contentsScale = contentsScale
        layer.insertSublayer(c, below: tail)
        chunks.append(c)
        active = c
        return c
    }

    private func configure(_ s: CAShapeLayer) {
        s.anchorPoint = .zero
        s.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
        s.fillRule = .nonZero
        s.strokeColor = nil
        s.actions = ["path": NSNull(), "fillColor": NSNull(), "contents": NSNull(), "position": NSNull(), "bounds": NSNull()]
    }
}
