import AppKit
import Combine

enum Tool: String, CaseIterable, Identifiable {
    case pen, highlighter, eraser, lasso, text, tape, laser
    var id: String { rawValue }
    var title: String { self == .laser ? "Laser Pointer" : rawValue.capitalized }
    var symbol: String {
        switch self {
        case .pen: return "pencil.tip"
        case .highlighter: return "highlighter"
        case .eraser: return "eraser"
        case .lasso: return "lasso"
        case .text: return "character.textbox"
        case .tape: return "rectangle.dashed"
        case .laser: return "rays"
        }
    }
    var shortcutKey: String {
        switch self {
        case .pen: return "p"
        case .highlighter: return "h"
        case .eraser: return "e"
        case .lasso: return "l"
        case .text: return "t"
        case .tape: return "u"
        case .laser: return "k"
        }
    }
}

enum EraserMode: String, CaseIterable, Identifiable {
    case stroke, precise
    var id: String { rawValue }
    var title: String { self == .stroke ? "Whole stroke" : "Precise" }
}

enum PressureFeel: String, CaseIterable, Identifiable {
    case soft, natural, firm, personal
    var id: String { rawValue }
    var title: String { self == .personal ? "Personal (Pen Lab)" : rawValue.capitalized }
    var gamma: Double {
        switch self {
        case .soft: return 0.6
        case .natural, .personal: return 1.0
        case .firm: return 1.6
        }
    }
}

/// App-wide tool and preference state, persisted in UserDefaults. Shared by every notebook window,
/// so picking a pen colour in one notebook carries over like a real pen case.
final class ToolState: ObservableObject {
    static let penPalette: [RGBA] = [
        RGBA(0.11, 0.13, 0.18), RGBA(0.13, 0.30, 0.78), RGBA(0.80, 0.18, 0.22),
        RGBA(0.10, 0.52, 0.32), RGBA(0.55, 0.25, 0.75), RGBA(0.93, 0.50, 0.10),
    ]
    static let highlighterPalette: [RGBA] = [
        RGBA(1.0, 0.86, 0.10, 0.45), RGBA(0.45, 0.90, 0.35, 0.40), RGBA(0.35, 0.80, 1.0, 0.40),
        RGBA(1.0, 0.50, 0.75, 0.40), RGBA(1.0, 0.62, 0.20, 0.40), RGBA(0.70, 0.60, 1.0, 0.40),
    ]
    static let penWidths: [Float] = [1.4, 2.4, 4.0]
    static let highlighterWidths: [Float] = [10, 16, 24]
    static let eraserRadii: [CGFloat] = [4, 10, 24]

    @Published var tool: Tool { didSet { if tool != oldValue { previousTool = oldValue }; save() } }
    @Published private(set) var previousTool: Tool = .eraser
    @Published var penColor: RGBA { didSet { save() } }
    @Published var penWidth: Float { didSet { save() } }
    @Published var highlighterColor: RGBA { didSet { save() } }
    @Published var highlighterWidth: Float { didSet { save() } }
    @Published var eraserRadius: CGFloat { didSet { save() } }
    @Published var eraserMode: EraserMode { didSet { save() } }
    @Published var textStyle: TextStyle { didSet { save() } }
    @Published var tapeColor: RGBA { didSet { save() } }
    static let tapePalette: [RGBA] = [RGBA(0.98, 0.78, 0.30), RGBA(0.55, 0.78, 0.98), RGBA(0.98, 0.58, 0.70), RGBA(0.62, 0.86, 0.58), RGBA(0.72, 0.66, 0.95)]
    /// Scribbling back and forth over ink deletes it.
    @Published var scribbleToErase: Bool { didSet { save() } }
    /// Write a sum ending in "=" and pause: the answer appears.
    @Published var autoSolve: Bool { didSet { save() } }
    /// Highlighter swipes over PDF text snap to the text lines.
    @Published var snapHighlights: Bool { didSet { save() } }

    @Published var pressureFeel: PressureFeel { didSet { save() } }
    /// Calibrated in the Pen Lab; used when `pressureFeel == .personal`.
    @Published var personalCurve: PressureCurve? { didSet { save() } }
    /// 1€ filter minimum cutoff: lower = smoother, higher = more immediate.
    @Published var smoothing: Double { didSet { save() } }
    @Published var holdToStraighten: Bool { didSet { save() } }
    @Published var prediction: Bool { didSet { save() } }
    /// When on, only the pen draws; mouse and trackpad drags scroll the page instead.
    @Published var penOnly: Bool { didSet { save() } }

    private let defaults: UserDefaults
    private var loading = true

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        func color(_ key: String, _ fallback: RGBA) -> RGBA {
            guard let d = defaults.data(forKey: key), let c = try? JSONDecoder().decode(RGBA.self, from: d) else { return fallback }
            return c
        }
        func float(_ key: String, _ fallback: Float, _ range: ClosedRange<Float>) -> Float {
            guard defaults.object(forKey: key) != nil else { return fallback }
            let v = defaults.float(forKey: key)
            return v.isFinite ? v.clamped(range.lowerBound, range.upperBound) : fallback
        }
        tool = Tool(rawValue: defaults.string(forKey: "tool") ?? "") ?? .pen
        penColor = color("penColor", Self.penPalette[0])
        penWidth = float("penWidth", Self.penWidths[1], 0.5...20)
        highlighterColor = color("highlighterColor", Self.highlighterPalette[0])
        highlighterWidth = float("highlighterWidth", Self.highlighterWidths[1], 4...60)
        eraserRadius = CGFloat(float("eraserRadius", Float(Self.eraserRadii[1]), 2...80))
        eraserMode = EraserMode(rawValue: defaults.string(forKey: "eraserMode") ?? "") ?? .stroke
        textStyle = defaults.data(forKey: "textStyle").flatMap { try? JSONDecoder().decode(TextStyle.self, from: $0) } ?? TextStyle()
        tapeColor = defaults.data(forKey: "tapeColor").flatMap { try? JSONDecoder().decode(RGBA.self, from: $0) } ?? ToolState.tapePalette[0]
        scribbleToErase = defaults.object(forKey: "scribbleToErase") as? Bool ?? true
        autoSolve = defaults.object(forKey: "autoSolve") as? Bool ?? true
        snapHighlights = defaults.object(forKey: "snapHighlights") as? Bool ?? true
        pressureFeel = PressureFeel(rawValue: defaults.string(forKey: "pressureFeel") ?? "") ?? .natural
        personalCurve = defaults.data(forKey: "personalCurve").flatMap { try? JSONDecoder().decode(PressureCurve.self, from: $0) }.flatMap { $0.isSane ? $0 : nil }
        smoothing = (defaults.object(forKey: "smoothing") as? Double).flatMap { $0.isFinite ? $0.clamped(0.5, 6) : nil } ?? 2.0
        holdToStraighten = defaults.object(forKey: "holdToStraighten") as? Bool ?? true
        prediction = defaults.object(forKey: "prediction") as? Bool ?? true
        penOnly = defaults.object(forKey: "penOnly") as? Bool ?? false
        if pressureFeel == .personal && personalCurve == nil { pressureFeel = .natural } // calibration lost: fall back
        loading = false
    }

    /// The curve the engine should use right now (nil = plain gamma).
    var activeCurve: PressureCurve? { pressureFeel == .personal ? personalCurve : nil }

    /// Lower pen button click: flip between the current and previous tool (like a stylus double-tap).
    func swapToPreviousTool() {
        let p = previousTool
        tool = p
    }

    /// The colour the toolbar edits: highlighter, text, or pen colour depending on the tool.
    var activeColor: RGBA {
        get {
            switch tool {
            case .highlighter: return highlighterColor
            case .text: return textStyle.color
            case .tape: return tapeColor
            default: return penColor
            }
        }
        set {
            switch tool {
            case .highlighter: highlighterColor = RGBA(newValue.r, newValue.g, newValue.b, highlighterColor.a)
            case .text: textStyle.color = newValue.opaque
            case .tape: tapeColor = newValue.opaque
            default: penColor = RGBA(newValue.r, newValue.g, newValue.b, penColor.a)
            }
        }
    }

    /// Ink opacity ("darkness"), 0.1...1, for the pen or highlighter.
    var activeOpacity: Float {
        get { tool == .highlighter ? highlighterColor.a : penColor.a }
        set {
            let a = newValue.clamped(0.1, 1)
            if tool == .highlighter { highlighterColor.a = a } else { penColor.a = a }
        }
    }

    var activeWidth: Float {
        get { tool == .highlighter ? highlighterWidth : penWidth }
        set { if tool == .highlighter { highlighterWidth = newValue.clamped(4, 60) } else { penWidth = newValue.clamped(0.5, 20) } }
    }

    private func save() {
        guard !loading else { return }
        defaults.set(tool.rawValue, forKey: "tool")
        defaults.set(try? JSONEncoder().encode(penColor), forKey: "penColor")
        defaults.set(penWidth, forKey: "penWidth")
        defaults.set(try? JSONEncoder().encode(highlighterColor), forKey: "highlighterColor")
        defaults.set(highlighterWidth, forKey: "highlighterWidth")
        defaults.set(Float(eraserRadius), forKey: "eraserRadius")
        defaults.set(eraserMode.rawValue, forKey: "eraserMode")
        defaults.set(try? JSONEncoder().encode(textStyle), forKey: "textStyle")
        defaults.set(try? JSONEncoder().encode(tapeColor), forKey: "tapeColor")
        defaults.set(scribbleToErase, forKey: "scribbleToErase")
        defaults.set(autoSolve, forKey: "autoSolve")
        defaults.set(snapHighlights, forKey: "snapHighlights")
        defaults.set(pressureFeel.rawValue, forKey: "pressureFeel")
        defaults.set(personalCurve.flatMap { try? JSONEncoder().encode($0) }, forKey: "personalCurve")
        defaults.set(smoothing, forKey: "smoothing")
        defaults.set(holdToStraighten, forKey: "holdToStraighten")
        defaults.set(prediction, forKey: "prediction")
        defaults.set(penOnly, forKey: "penOnly")
    }
}

extension RGBA {
    var nsColor: NSColor { NSColor(srgbRed: CGFloat(r), green: CGFloat(g), blue: CGFloat(b), alpha: CGFloat(a)) }

    init(_ c: NSColor, alpha: Float? = nil) {
        let s = c.usingColorSpace(.sRGB) ?? NSColor.black
        self.init(Float(s.redComponent), Float(s.greenComponent), Float(s.blueComponent), alpha ?? Float(s.alphaComponent))
    }
}
