import AppKit
import Combine
import SwiftUI

/// The Pen Lab: a guided test board that records exactly what the tablet reports (raw, unfiltered),
/// measures it, and recommends a personal pressure curve and smoothing. Every session is saved as JSON.
enum PenExercise: String, CaseIterable, Identifiable, Codable {
    case hover, ramp, light, normal, firm, taps, lines, circles, speed, handwriting, buttons

    var id: String { rawValue }

    var title: String {
        switch self {
        case .hover: return "Hover"
        case .ramp: return "Light → firm"
        case .light: return "Light lines"
        case .normal: return "Normal lines"
        case .firm: return "Firm lines"
        case .taps: return "Taps"
        case .lines: return "Straight lines"
        case .circles: return "Circles"
        case .speed: return "Speed"
        case .handwriting: return "Handwriting"
        case .buttons: return "Pen buttons"
        }
    }

    var instruction: String {
        switch self {
        case .hover: return "Hold the pen just above the tablet without touching, and move over each of the three circles until it turns green."
        case .ramp: return "Draw slowly along each guide from left to right: start as lightly as you can and press steadily harder until firm at the end."
        case .light: return "Draw along each guide with a LIGHT touch, like sketching."
        case .normal: return "Draw along each guide with your NORMAL writing pressure."
        case .firm: return "Draw along each guide pressing FIRMLY, like going over a bold heading."
        case .taps: return "Tap each dot once, quickly, the way you dot an i."
        case .lines: return "Trace each straight guide slowly and carefully."
        case .circles: return "Trace the circles: the first slowly, the second at normal speed, the third fast."
        case .speed: return "Scribble a zig-zag across the box as fast as you comfortably can."
        case .handwriting: return "Write the sentence below in your normal handwriting, then sign your name underneath."
        case .buttons: return "With the pen over the board, click the LOWER pen button once, then the UPPER pen button once."
        }
    }

    /// Strokes (or events) needed before the exercise counts as done.
    var required: Int {
        switch self {
        case .hover: return 3
        case .ramp, .circles: return 3
        case .light, .normal, .firm: return 2
        case .taps: return 8
        case .lines: return 4
        case .speed: return 1
        case .handwriting: return 10
        case .buttons: return 2
        }
    }
}

/// Everything the Pen Lab saves for later analysis.
struct PenLabReport: Codable {
    var date: Date
    var app: String
    var device: [String: String]
    var settingsAtCapture: [String: String]
    var samples: [String: [PenSample]]
    var summary: [String: String]
    var recommendation: PenAnalysis.Recommendation?
}

final class PenLabModel: ObservableObject {
    static let boardSize = CGSize(width: 860, height: 470)

    @Published var exercise: PenExercise = .hover
    @Published private(set) var samples: [PenExercise: [PenSample]] = [:]
    @Published private(set) var hoverHits: Set<Int> = []
    @Published private(set) var buttonsSeen: Set<Int> = []
    @Published var livePressure: Double = 0
    @Published var liveTilt = CGPoint.zero
    @Published var device: [String: String] = [:]
    @Published var showingSummary = false
    @Published private(set) var recommendation: PenAnalysis.Recommendation?
    @Published private(set) var savedURL: URL?
    @Published var applied = false
    var onChange: () -> Void = {}

    let tools: ToolState
    init(tools: ToolState) { self.tools = tools }

    var currentSamples: [PenSample] { samples[exercise] ?? [] }

    func progress(_ ex: PenExercise) -> Int {
        switch ex {
        case .hover: return hoverHits.count
        case .buttons: return buttonsSeen.count
        default: return PenAnalysis.strokes(samples[ex] ?? []).count
        }
    }

    func isDone(_ ex: PenExercise) -> Bool { progress(ex) >= ex.required }
    var allDone: Bool { PenExercise.allCases.allSatisfy(isDone) }

    func record(_ s: PenSample) {
        samples[exercise, default: []].append(s)
        if s.phase != .up { livePressure = s.pressure }
        liveTilt = CGPoint(x: s.tiltX, y: s.tiltY)
        if exercise == .hover, s.phase == .hover {
            for (i, c) in Self.hoverTargets.enumerated() where hypot(s.x - c.x, s.y - c.y) < 34 { hoverHits.insert(i) }
        }
        if exercise == .buttons, s.phase == .down, s.button > 0 { buttonsSeen.insert(s.button) }
        onChange()
    }

    func redo() {
        samples[exercise] = []
        if exercise == .hover { hoverHits = [] }
        if exercise == .buttons { buttonsSeen = [] }
        onChange()
    }

    func next() {
        save()
        if let i = PenExercise.allCases.firstIndex(of: exercise), i + 1 < PenExercise.allCases.count {
            exercise = PenExercise.allCases[i + 1]
        } else {
            finish()
        }
        onChange()
    }

    func back() {
        showingSummary = false
        if let i = PenExercise.allCases.firstIndex(of: exercise), i > 0 { exercise = PenExercise.allCases[i - 1] }
        onChange()
    }

    // MARK: Analysis

    var allContact: [PenSample] { PenExercise.allCases.filter { $0 != .hover && $0 != .buttons }.flatMap { samples[$0] ?? [] } }

    struct Summary {
        var reportRate: Double?
        var pressure: PenAnalysis.PressureStats?
        var light: Double?, normal: Double?, firm: Double?
        var tapPeak: Double?
        var lineJitter: Double?, circleJitter: Double?
        var peakSpeed: Double?
        var tiltReported: Bool
        var tabletEvents: Bool
    }

    func summary() -> Summary {
        let all = allContact
        let taps = PenAnalysis.strokes(samples[.taps] ?? []).compactMap { $0.map(\.pressure).max() }
        return Summary(
            reportRate: PenAnalysis.reportRate(all),
            pressure: PenAnalysis.pressureStats(all),
            light: PenAnalysis.median(PenAnalysis.strokePressures(samples[.light] ?? [])),
            normal: PenAnalysis.median(PenAnalysis.strokePressures(samples[.normal] ?? []) + PenAnalysis.strokePressures(samples[.handwriting] ?? [])),
            firm: PenAnalysis.median(PenAnalysis.strokePressures(samples[.firm] ?? [])),
            tapPeak: PenAnalysis.median(taps),
            lineJitter: PenAnalysis.lineJitter(samples[.lines] ?? []),
            circleJitter: PenAnalysis.circleJitter(samples[.circles] ?? []),
            peakSpeed: PenAnalysis.peakSpeed(samples[.speed] ?? []),
            tiltReported: all.contains { $0.tiltX != 0 || $0.tiltY != 0 },
            tabletEvents: all.contains { $0.isTablet })
    }

    func finish() {
        let s = summary()
        let jitter = [s.lineJitter, s.circleJitter].compactMap { $0 }.min()
        recommendation = PenAnalysis.recommend(
            light: PenAnalysis.strokePressures(samples[.light] ?? []),
            normal: PenAnalysis.strokePressures(samples[.normal] ?? []) + PenAnalysis.strokePressures(samples[.handwriting] ?? []),
            firm: PenAnalysis.strokePressures(samples[.firm] ?? []),
            allContact: allContact.filter { $0.phase == .drag }.map(\.pressure),
            jitter: jitter, reportRate: s.reportRate)
        showingSummary = true
        save()
    }

    func apply() {
        guard let r = recommendation else { return }
        tools.personalCurve = r.curve
        tools.smoothing = r.smoothing
        tools.pressureFeel = .personal
        applied = true
    }

    func revert() {
        tools.pressureFeel = .natural
        tools.smoothing = 2.0
        applied = false
    }

    // MARK: Saving

    /// Self-tests point this at their throwaway library so synthetic sessions never mix with real ones.
    static var folderOverride: URL?

    static var folder: URL {
        folderOverride ?? AppFolders.folder(in: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0])
            .appendingPathComponent("PenLab", isDirectory: true)
    }

    /// Saves after every exercise, so nothing is lost if the window is closed early. Also writes latest.json.
    func save() {
        let s = summary()
        func f(_ v: Double?, _ fmt: String = "%.3f") -> String { v.map { String(format: fmt, $0) } ?? "–" }
        var sum: [String: String] = [
            "reportRateHz": f(s.reportRate, "%.1f"), "pressureMin": f(s.pressure?.min), "pressureMax": f(s.pressure?.max),
            "pressureLevelsSeen": s.pressure.map { "\($0.distinctLevels)" } ?? "–", "pressureStep": f(s.pressure?.step, "%.6f"),
            "light": f(s.light), "normal": f(s.normal), "firm": f(s.firm), "tapPeak": f(s.tapPeak),
            "lineJitterPt": f(s.lineJitter), "circleJitterPt": f(s.circleJitter), "peakSpeedPtPerS": f(s.peakSpeed, "%.0f"),
            "tiltReported": "\(s.tiltReported)", "tabletEvents": "\(s.tabletEvents)",
            "buttonsSeen": buttonsSeen.sorted().map(String.init).joined(separator: ","),
        ]
        for ex in PenExercise.allCases { sum["done.\(ex.rawValue)"] = "\(progress(ex))/\(ex.required)" }
        let report = PenLabReport(
            date: Date(),
            app: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev",
            device: device,
            settingsAtCapture: ["pressureFeel": tools.pressureFeel.rawValue, "smoothing": "\(tools.smoothing)",
                                "penWidth": "\(tools.penWidth)", "penOnly": "\(tools.penOnly)"],
            samples: Dictionary(uniqueKeysWithValues: samples.map { ($0.key.rawValue, $0.value) }),
            summary: sum,
            recommendation: recommendation)
        do {
            try FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            enc.dateEncodingStrategy = .iso8601
            let data = try enc.encode(report)
            let stamp = ISO8601DateFormatter().string(from: sessionStart).replacingOccurrences(of: ":", with: "-")
            let url = Self.folder.appendingPathComponent("penlab-\(stamp).json")
            try data.write(to: url, options: .atomic)
            try data.write(to: Self.folder.appendingPathComponent("latest.json"), options: .atomic)
            savedURL = url
        } catch {
            NSLog("Pen Lab save failed: \(error)")
        }
    }

    private let sessionStart = Date()

    // MARK: Guides (board coordinates, y down)

    static let hoverTargets = [CGPoint(x: 180, y: 240), CGPoint(x: 430, y: 160), CGPoint(x: 680, y: 300)]
    static func guideLines(_ ex: PenExercise) -> [(CGPoint, CGPoint)] {
        switch ex {
        case .ramp: return [0, 1, 2].map { (CGPoint(x: 80, y: 120 + CGFloat($0) * 120), CGPoint(x: 780, y: 120 + CGFloat($0) * 120)) }
        case .light, .normal, .firm: return [0, 1].map { (CGPoint(x: 80, y: 160 + CGFloat($0) * 160), CGPoint(x: 780, y: 160 + CGFloat($0) * 160)) }
        case .lines: return [(CGPoint(x: 80, y: 90), CGPoint(x: 780, y: 90)), (CGPoint(x: 120, y: 140), CGPoint(x: 120, y: 420)),
                             (CGPoint(x: 220, y: 420), CGPoint(x: 520, y: 140)), (CGPoint(x: 560, y: 140), CGPoint(x: 800, y: 420))]
        case .handwriting: return [(CGPoint(x: 60, y: 210), CGPoint(x: 800, y: 210)), (CGPoint(x: 60, y: 380), CGPoint(x: 800, y: 380))]
        default: return []
        }
    }
    static let tapDots = (0..<8).map { CGPoint(x: 120 + CGFloat($0 % 4) * 200, y: 160 + CGFloat($0 / 4) * 160) }
    static let circles = [(CGPoint(x: 170, y: 240), CGFloat(100)), (CGPoint(x: 430, y: 240), CGFloat(100)), (CGPoint(x: 690, y: 240), CGFloat(100))]
}

/// The drawing surface: records raw events and shows the ink through the real engine.
final class PenLabBoard: NSView {
    let model: PenLabModel
    private var builder: StrokeBuilder?
    private var drawn: [PenExercise: [Stroke]] = [:]
    private var tracking: NSTrackingArea?
    private let live = LiveInk()

    init(model: PenLabModel) {
        self.model = model
        super.init(frame: CGRect(origin: .zero, size: PenLabModel.boardSize))
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = true
        layer?.addSublayer(live.layer)
        model.onChange = { [weak self] in self?.needsDisplay = true }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var intrinsicContentSize: NSSize { PenLabModel.boardSize }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect, .mouseEnteredAndExited], owner: self)
        addTrackingArea(t)
        tracking = t
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
    }

    func clearExercise(_ ex: PenExercise) { drawn[ex] = []; needsDisplay = true }

    private func sample(_ e: NSEvent, _ phase: PenSample.Phase, button: Int) -> PenSample {
        let p = convert(e.locationInWindow, from: nil)
        let tablet = e.subtype == .tabletPoint
        return PenSample(t: e.timestamp, x: Double(p.x), y: Double(p.y), pressure: Double(e.pressure),
                         tiltX: tablet ? Double(e.tilt.x) : 0, tiltY: tablet ? Double(e.tilt.y) : 0,
                         rotation: tablet ? Double(e.rotation) : 0, phase: phase, button: button, isTablet: tablet)
    }

    override func mouseDown(with e: NSEvent) {
        NSEvent.isMouseCoalescingEnabled = false
        let s = sample(e, .down, button: 0)
        model.record(s)
        let b = StrokeBuilder(kind: .pen, color: RGBA(0.11, 0.15, 0.32), width: 3, scale: 1, simulatePressure: !s.isTablet,
                              pressureGamma: model.tools.pressureFeel.gamma, curve: model.tools.activeCurve, smoothing: model.tools.smoothing)
        b.add(x: s.x, y: s.y, pressure: s.pressure, timestamp: s.t)
        builder = b
        live.begin(kind: .pen, color: b.color, width: b.width, frame: bounds, contentsScale: window?.backingScaleFactor ?? 2)
        live.update(points: b.points, predicted: nil)
    }

    override func mouseDragged(with e: NSEvent) {
        let s = sample(e, .drag, button: 0)
        model.record(s)
        if builder?.add(x: s.x, y: s.y, pressure: s.pressure, timestamp: s.t) == true, let b = builder {
            live.update(points: b.points, predicted: nil)
        }
    }

    override func mouseUp(with e: NSEvent) {
        let s = sample(e, .up, button: 0)
        model.record(s)
        if let st = builder?.finish(x: s.x, y: s.y, pressure: s.pressure, timestamp: s.t) { drawn[model.exercise, default: []].append(st) }
        builder = nil
        live.reset()
        NSEvent.isMouseCoalescingEnabled = true
        needsDisplay = true
    }

    override func rightMouseDown(with e: NSEvent) { model.record(sample(e, .down, button: 1)) }
    override func rightMouseUp(with e: NSEvent) { model.record(sample(e, .up, button: 1)) }
    override func otherMouseDown(with e: NSEvent) { model.record(sample(e, .down, button: 2)) }
    override func otherMouseUp(with e: NSEvent) { model.record(sample(e, .up, button: 2)) }
    override func mouseMoved(with e: NSEvent) { model.record(sample(e, .hover, button: 0)) }

    override func tabletProximity(with e: NSEvent) {
        guard e.isEnteringProximity else { return }
        model.device = [
            "vendorID": "\(e.vendorID)", "tabletID": "\(e.tabletID)", "systemTabletID": "\(e.systemTabletID)",
            "deviceID": "\(e.deviceID)", "pointingDeviceID": "\(e.pointingDeviceID)",
            "pointingDeviceSerial": "\(e.pointingDeviceSerialNumber)", "pointingDeviceType": "\(e.pointingDeviceType.rawValue)",
            "capabilityMask": String(format: "0x%lx", e.capabilityMask), "vendorPointingDeviceType": "\(e.vendorPointingDeviceType)",
        ]
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.setFillColor(.white)
        ctx.fill(bounds)
        let guide = CGColor(srgbRed: 0.35, green: 0.55, blue: 0.95, alpha: 0.35)
        ctx.setStrokeColor(guide)
        ctx.setLineWidth(2)
        ctx.setLineDash(phase: 0, lengths: [8, 6])
        for (a, b) in PenLabModel.guideLines(model.exercise) { ctx.move(to: a); ctx.addLine(to: b) }
        ctx.strokePath()
        ctx.setLineDash(phase: 0, lengths: [])
        switch model.exercise {
        case .hover:
            for (i, c) in PenLabModel.hoverTargets.enumerated() {
                let hit = model.hoverHits.contains(i)
                ctx.setFillColor(hit ? CGColor(srgbRed: 0.2, green: 0.75, blue: 0.4, alpha: 0.35) : guide.copy(alpha: 0.15)!)
                ctx.fillEllipse(in: CGRect(x: c.x - 34, y: c.y - 34, width: 68, height: 68))
            }
        case .taps:
            ctx.setFillColor(guide)
            for d in PenLabModel.tapDots { ctx.fillEllipse(in: CGRect(x: d.x - 7, y: d.y - 7, width: 14, height: 14)) }
        case .circles:
            ctx.setLineDash(phase: 0, lengths: [8, 6])
            for (c, r) in PenLabModel.circles { ctx.strokeEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)) }
            ctx.setLineDash(phase: 0, lengths: [])
        case .speed:
            ctx.stroke(CGRect(x: 60, y: 80, width: 740, height: 320))
        case .handwriting:
            let text = "The quick brown fox jumps over the lazy dog." as NSString
            text.draw(at: CGPoint(x: 60, y: 60), withAttributes: [.font: NSFont.systemFont(ofSize: 18), .foregroundColor: NSColor.secondaryLabelColor])
        case .buttons:
            for (i, label) in ["Lower button", "Upper button"].enumerated() {
                let on = model.buttonsSeen.contains(i + 1)
                let r = CGRect(x: 170 + CGFloat(i) * 300, y: 180, width: 220, height: 90)
                ctx.setFillColor(on ? CGColor(srgbRed: 0.2, green: 0.75, blue: 0.4, alpha: 0.3) : guide.copy(alpha: 0.12)!)
                ctx.addPath(CGPath(roundedRect: r, cornerWidth: 12, cornerHeight: 12, transform: nil))
                ctx.fillPath()
                (label as NSString).draw(at: CGPoint(x: r.minX + 52, y: r.midY - 10),
                                         withAttributes: [.font: NSFont.systemFont(ofSize: 16, weight: .semibold), .foregroundColor: NSColor.black])
            }
        default:
            break
        }
        var o = PageRenderer.Options()
        o.skipBackground = true
        PageRenderer.drawStrokes(drawn[model.exercise] ?? [], kind: .pen, in: ctx, options: o)
    }
}

struct PenLabBoardView: NSViewRepresentable {
    let board: PenLabBoard
    func makeNSView(context: Context) -> PenLabBoard { board }
    func updateNSView(_ nsView: PenLabBoard, context: Context) { nsView.needsDisplay = true }
}

/// Handwriting from the session drawn with a given curve, for the before/after preview.
struct CurvePreview: View {
    let samples: [PenSample]
    let curve: PressureCurve?
    let smoothing: Double

    var body: some View {
        Canvas { ctx, size in
            let strokes = PenAnalysis.strokes(samples)
            let all = strokes.flatMap { $0 }
            guard let minX = all.map(\.x).min(), let maxX = all.map(\.x).max(), let minY = all.map(\.y).min(), let maxY = all.map(\.y).max() else { return }
            let s = min(size.width / max(maxX - minX, 1), size.height / max(maxY - minY, 1)) * 0.9
            for st in strokes {
                let b = StrokeBuilder(kind: .pen, color: RGBA(0.11, 0.15, 0.32), width: Float(3 * s), scale: 1, simulatePressure: false,
                                      curve: curve, smoothing: smoothing)
                for p in st { b.add(x: (p.x - minX) * s + 6, y: (p.y - minY) * s + 6, pressure: p.pressure, timestamp: p.t) }
                if let stroke = b.makeStroke() {
                    ctx.fill(Path(InkGeometry.outlinePath(for: stroke)), with: .color(Color(nsColor: stroke.color.nsColor)))
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white))
    }
}

struct PenLabView: View {
    @ObservedObject var model: PenLabModel
    let board: PenLabBoard
    /// For offscreen rendering in tests (ImageRenderer can't draw ScrollView contents).
    var unscrolled = false

    var body: some View {
        HStack(spacing: 0) {
            exerciseList
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                if model.showingSummary { summaryView } else { exerciseView }
            }
            .padding(18)
            .frame(minWidth: 900)
        }
        .frame(minHeight: 640)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var exerciseList: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Pen Lab").font(.title2.weight(.semibold)).padding(.bottom, 8)
            ForEach(PenExercise.allCases) { ex in
                Button {
                    model.showingSummary = false
                    model.exercise = ex
                    model.onChange()
                } label: {
                    HStack {
                        Image(systemName: model.isDone(ex) ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(model.isDone(ex) ? Color.green : .secondary)
                        Text(ex.title)
                        Spacer()
                        Text("\(min(model.progress(ex), ex.required))/\(ex.required)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 6).fill(model.exercise == ex && !model.showingSummary ? Color.accentColor.opacity(0.15) : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Divider().padding(.vertical, 6)
            Button { model.finish() } label: { Label("Results", systemImage: "chart.bar.doc.horizontal") }
                .buttonStyle(.plain).padding(.horizontal, 8)
            Spacer()
            Text("Recordings are saved in \(PenLabModel.folder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")).")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 220)
    }

    private var exerciseView: some View {
        let ex = model.exercise
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(ex.title).font(.title3.weight(.semibold))
                Spacer()
                pressureMeter
            }
            Text(ex.instruction).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            PenLabBoardView(board: board)
                .frame(width: PenLabModel.boardSize.width, height: PenLabModel.boardSize.height)
                .shadow(color: .black.opacity(0.15), radius: 4, y: 1)
            HStack {
                Button("Back") { model.back() }.disabled(ex == PenExercise.allCases.first)
                Button("Redo") { board.clearExercise(ex); model.redo() }
                Spacer()
                if model.isDone(ex) { Label("Done", systemImage: "checkmark").foregroundStyle(.green) }
                Button(ex == PenExercise.allCases.last ? "See Results" : "Next") { model.next() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private var pressureMeter: some View {
        HStack(spacing: 8) {
            Text("Pressure").font(.caption).foregroundStyle(.secondary)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.1)).frame(width: 160, height: 8)
                Capsule().fill(Color.accentColor).frame(width: max(2, 160 * CGFloat(model.livePressure)), height: 8)
            }
            Text(String(format: "%.3f", model.livePressure)).font(.caption.monospacedDigit()).frame(width: 44)
            if model.liveTilt != .zero {
                Text(String(format: "tilt %.2f, %.2f", model.liveTilt.x, model.liveTilt.y)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
    }

    private var summaryView: some View {
        let s = model.summary()
        func f(_ v: Double?, _ fmt: String) -> String { v.map { String(format: fmt, $0) } ?? "not measured" }
        let content = VStack(alignment: .leading, spacing: 14) {
                Text("Results").font(.title3.weight(.semibold))
                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 6) {
                    row("Pen events", s.tabletEvents ? "Tablet (pressure-sensitive)" : "Mouse-like: check the XPPen driver is running")
                    row("Report rate", f(s.reportRate, "%.0f samples/s"))
                    row("Pressure range seen", s.pressure.map { String(format: "%.3f – %.3f", $0.min, $0.max) } ?? "not measured")
                    row("Pressure resolution", s.pressure.map { "\($0.distinctLevels) levels seen" + ($0.step.map { String(format: ", finest step %.5f", $0) } ?? "") } ?? "not measured")
                    row("Your light / normal / firm", "\(f(s.light, "%.2f")) / \(f(s.normal, "%.2f")) / \(f(s.firm, "%.2f"))")
                    row("Tap peak pressure", f(s.tapPeak, "%.2f"))
                    row("Line / circle jitter", "\(f(s.lineJitter, "%.2f pt")) / \(f(s.circleJitter, "%.2f pt"))")
                    row("Fastest stroke", f(s.peakSpeed, "%.0f pt/s"))
                    row("Tilt", s.tiltReported ? "Reported" : "Not reported (normal for the G640)")
                    row("Pen buttons", model.buttonsSeen.isEmpty ? "None detected: set them in the XPPen driver" :
                            model.buttonsSeen.sorted().map { $0 == 1 ? "lower ✓" : "upper ✓" }.joined(separator: ", "))
                }
                if let r = model.recommendation {
                    Divider()
                    Text("Recommended for you").font(.headline)
                    ForEach(r.notes, id: \.self) { Text("• " + $0).font(.callout) }
                    HStack(spacing: 16) {
                        VStack(alignment: .leading) {
                            Text("Before").font(.caption).foregroundStyle(.secondary)
                            CurvePreview(samples: model.samples[.handwriting] ?? [], curve: nil, smoothing: 2.0).frame(width: 400, height: 150)
                        }
                        VStack(alignment: .leading) {
                            Text("With your settings").font(.caption).foregroundStyle(.secondary)
                            CurvePreview(samples: model.samples[.handwriting] ?? [], curve: r.curve, smoothing: r.smoothing).frame(width: 400, height: 150)
                        }
                    }
                    HStack {
                        Button(model.applied ? "Applied ✓" : "Apply My Settings") { model.apply() }
                            .buttonStyle(.borderedProminent).disabled(model.applied)
                        if model.applied { Button("Undo") { model.revert() } }
                        Spacer()
                        if let url = model.savedURL {
                            Button("Show Recording in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                        }
                    }
                }
                if !model.allDone {
                    Text("Some exercises aren’t finished: the results use what was recorded.").font(.caption).foregroundStyle(.orange)
                }
            }
        return Group {
            if unscrolled { content } else { ScrollView { content } }
        }
    }

    private func row(_ k: String, _ v: String) -> some View {
        GridRow {
            Text(k).foregroundStyle(.secondary)
            Text(v).textSelection(.enabled)
        }
    }
}

final class PenLabWindowController: NSWindowController, NSWindowDelegate {
    let model: PenLabModel
    let board: PenLabBoard

    init(tools: ToolState) {
        model = PenLabModel(tools: tools)
        board = PenLabBoard(model: model)
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1160, height: 680), styleMask: [.titled, .closable, .miniaturizable],
                         backing: .buffered, defer: false)
        w.title = "Pen Lab"
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: PenLabView(model: model, board: board))
        w.center()
        super.init(window: w)
        w.delegate = self
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func windowWillClose(_ notification: Notification) {
        model.save()
        NSEvent.isMouseCoalescingEnabled = true
    }
}
