import CoreGraphics
import Foundation

// MARK: - Ink primitives

/// One sampled point of a stroke, in page coordinates (points, origin top-left).
struct InkPoint: Equatable {
    var x: Float
    var y: Float
    /// Normalised pen pressure, always within 0...1.
    var pressure: Float
    /// Seconds since the first point of the stroke.
    var time: Float

    var cgPoint: CGPoint { CGPoint(x: CGFloat(x), y: CGFloat(y)) }
    var isFinite: Bool { x.isFinite && y.isFinite && pressure.isFinite && time.isFinite }
}

enum ToolKind: UInt8, Codable, CaseIterable {
    case pen = 0
    case highlighter = 1
}

struct RGBA: Codable, Hashable {
    var r: Float
    var g: Float
    var b: Float
    var a: Float

    init(_ r: Float, _ g: Float, _ b: Float, _ a: Float = 1) {
        self.r = r.clamped(0, 1)
        self.g = g.clamped(0, 1)
        self.b = b.clamped(0, 1)
        self.a = a.clamped(0, 1)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(try c.decode(Float.self, forKey: .r).finiteOr(0),
                  try c.decode(Float.self, forKey: .g).finiteOr(0),
                  try c.decode(Float.self, forKey: .b).finiteOr(0),
                  try c.decode(Float.self, forKey: .a).finiteOr(1))
    }

    var cgColor: CGColor { CGColor(srgbRed: CGFloat(r), green: CGFloat(g), blue: CGFloat(b), alpha: CGFloat(a)) }
    var opaque: RGBA { RGBA(r, g, b, 1) }
}

// MARK: - Stroke

struct Stroke: Identifiable, Equatable {
    static let widthRange: ClosedRange<Float> = 0.25...120
    /// Strokes longer than this are split while drawing so no single stroke gets slow to render or hit-test.
    static let maxPoints = 8_000

    let id: UUID
    var kind: ToolKind
    var color: RGBA
    var width: Float
    private(set) var points: [InkPoint]
    private(set) var bounds: CGRect
    /// Set when the stroke was written during an audio recording: which one, and when (s into it).
    var recording: UUID?
    var recordingOffset: Double?

    /// Builds a stroke, dropping non-finite samples and clamping every value into range.
    /// Returns nil when no usable point remains.
    init?(id: UUID = UUID(), kind: ToolKind, color: RGBA, width: Float, points: [InkPoint]) {
        let clean = points.compactMap { p -> InkPoint? in
            guard p.isFinite else { return nil }
            return InkPoint(x: p.x.clamped(-1e6, 1e6), y: p.y.clamped(-1e6, 1e6),
                            pressure: p.pressure.clamped(0, 1), time: max(0, p.time))
        }
        guard !clean.isEmpty else { return nil }
        self.id = id
        self.kind = kind
        self.color = color
        self.width = width.finiteOr(2).clamped(Stroke.widthRange.lowerBound, Stroke.widthRange.upperBound)
        self.points = Array(clean.prefix(Stroke.maxPoints))
        self.bounds = .null
        self.bounds = Stroke.computeBounds(self.points, padding: CGFloat(self.width))
    }

    func translated(dx: CGFloat, dy: CGFloat) -> Stroke {
        var s = self
        let fx = Float(dx), fy = Float(dy)
        s.points = points.map { InkPoint(x: ($0.x + fx).clamped(-1e6, 1e6), y: ($0.y + fy).clamped(-1e6, 1e6), pressure: $0.pressure, time: $0.time) }
        // Recomputed, not offset: bounds must match exactly what a reload computes from the points.
        s.bounds = Stroke.computeBounds(s.points, padding: CGFloat(width))
        return s
    }

    private static func computeBounds(_ pts: [InkPoint], padding: CGFloat) -> CGRect {
        var minX = Float.infinity, minY = Float.infinity, maxX = -Float.infinity, maxY = -Float.infinity
        for p in pts {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        return CGRect(x: CGFloat(minX), y: CGFloat(minY), width: CGFloat(maxX - minX), height: CGFloat(maxY - minY))
            .insetBy(dx: -padding, dy: -padding)
    }
}

extension Stroke: Codable {
    private enum CodingKeys: String, CodingKey { case id, kind, color, width, points, recording, recordingOffset }

    /// Points are packed as little-endian Float32 quadruples (x, y, pressure, time): 16 bytes per point.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(kind, forKey: .kind)
        try c.encode(color, forKey: .color)
        try c.encode(width, forKey: .width)
        var data = Data(capacity: points.count * 16)
        for p in points {
            for v in [p.x, p.y, p.pressure, p.time] {
                withUnsafeBytes(of: v.bitPattern.littleEndian) { data.append(contentsOf: $0) }
            }
        }
        try c.encode(data, forKey: .points)
        try c.encodeIfPresent(recording, forKey: .recording)
        try c.encodeIfPresent(recordingOffset, forKey: .recordingOffset)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let data = try c.decode(Data.self, forKey: .points)
        guard data.count % 16 == 0 else {
            throw DecodingError.dataCorruptedError(forKey: .points, in: c, debugDescription: "point data is \(data.count) bytes, not a multiple of 16")
        }
        var pts: [InkPoint] = []
        pts.reserveCapacity(data.count / 16)
        data.withUnsafeBytes { raw in
            func f(_ o: Int) -> Float { Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: o, as: UInt32.self))) }
            var o = 0
            while o < raw.count {
                pts.append(InkPoint(x: f(o), y: f(o + 4), pressure: f(o + 8), time: f(o + 12)))
                o += 16
            }
        }
        let kind = (try? c.decode(ToolKind.self, forKey: .kind)) ?? .pen
        guard let s = Stroke(id: try c.decode(UUID.self, forKey: .id), kind: kind,
                             color: try c.decode(RGBA.self, forKey: .color),
                             width: try c.decode(Float.self, forKey: .width), points: pts) else {
            throw DecodingError.dataCorruptedError(forKey: .points, in: c, debugDescription: "stroke has no valid points")
        }
        self = s
        recording = try? c.decode(UUID.self, forKey: .recording)
        recordingOffset = (try? c.decode(Double.self, forKey: .recordingOffset)).flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
    }
}

// MARK: - Pages and notebooks

enum PageStyle: String, Codable, CaseIterable, Identifiable {
    case blank, ruled, grid, dotted
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

enum PaperColor: String, Codable, CaseIterable, Identifiable {
    case white, cream, gray
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var rgba: RGBA {
        switch self {
        case .white: return RGBA(1, 1, 1)
        case .cream: return RGBA(0.992, 0.973, 0.918)
        case .gray: return RGBA(0.945, 0.945, 0.95)
        }
    }
}

enum PageSize: String, Codable, CaseIterable, Identifiable {
    case a4, letter, widescreen
    var id: String { rawValue }
    var title: String {
        switch self {
        case .a4: return "A4"
        case .letter: return "Letter"
        case .widescreen: return "Widescreen"
        }
    }
    var size: CGSize {
        switch self {
        case .a4: return CGSize(width: 595, height: 842)
        case .letter: return CGSize(width: 612, height: 792)
        case .widescreen: return CGSize(width: 1024, height: 576)
        }
    }
}

// MARK: - Page elements (typed text, images, links)

enum TextFont: String, Codable, CaseIterable, Identifiable {
    case sans, serif, mono, hand
    var id: String { rawValue }
    var title: String {
        switch self {
        case .sans: return "Sans"
        case .serif: return "Serif"
        case .mono: return "Mono"
        case .hand: return "Handwriting"
        }
    }
}

enum TextAlign: String, Codable, CaseIterable, Identifiable {
    case left, center, right
    var id: String { rawValue }
}

struct TextStyle: Codable, Equatable {
    static let sizeRange: ClosedRange<Double> = 6...144

    var font: TextFont = .sans
    var size: Double = 18
    var color: RGBA = RGBA(0.11, 0.13, 0.18)
    var bold = false
    var italic = false
    var alignment: TextAlign = .left
    /// Optional background fill behind the text (a "highlighted" text box).
    var highlight: RGBA?

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        font = (try? c.decode(TextFont.self, forKey: .font)) ?? .sans
        size = ((try? c.decode(Double.self, forKey: .size)) ?? 18).finiteOrDefault(18).clamped(Self.sizeRange.lowerBound, Self.sizeRange.upperBound)
        color = (try? c.decode(RGBA.self, forKey: .color)) ?? RGBA(0.11, 0.13, 0.18)
        bold = (try? c.decode(Bool.self, forKey: .bold)) ?? false
        italic = (try? c.decode(Bool.self, forKey: .italic)) ?? false
        alignment = (try? c.decode(TextAlign.self, forKey: .alignment)) ?? .left
        highlight = try? c.decode(RGBA.self, forKey: .highlight)
    }
}

struct PageElement: Identifiable, Codable, Equatable {
    enum Content: Codable, Equatable {
        case image(asset: UUID)
        case text(String, TextStyle)
        /// An invisible clickable area (e.g. a link attached to a lasso selection of ink).
        case link
        /// Study tape: an opaque strip that hides what's under it until clicked; doubles as a flash card.
        case tape(RGBA, Review?)
    }

    static let maxTextLength = 20_000

    var id = UUID()
    var frame: CGRect
    var content: Content
    /// Hyperlink opened when the element is clicked (⌘-click with drawing tools).
    var link: String?

    init(id: UUID = UUID(), frame: CGRect, content: Content, link: String? = nil) {
        self.id = id
        self.frame = PageElement.sanitize(frame)
        self.content = content
        self.link = link.flatMap(LinkURL.normalize)
        if case .text(let t, let st) = content, t.count > Self.maxTextLength {
            self.content = .text(String(t.prefix(Self.maxTextLength)), st)
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let frame = try c.decode(CGRect.self, forKey: .frame)
        guard frame.origin.x.isFinite, frame.origin.y.isFinite, frame.width.isFinite, frame.height.isFinite else {
            throw DecodingError.dataCorruptedError(forKey: .frame, in: c, debugDescription: "non-finite frame")
        }
        self.init(id: try c.decode(UUID.self, forKey: .id), frame: frame,
                  content: try c.decode(Content.self, forKey: .content),
                  link: try? c.decode(String.self, forKey: .link))
    }

    static func sanitize(_ r: CGRect) -> CGRect {
        let r = r.standardized
        return CGRect(x: r.minX.finiteOr(0).clamped(-1e5, 1e5), y: r.minY.finiteOr(0).clamped(-1e5, 1e5),
                      width: r.width.finiteOr(10).clamped(4, 1e5), height: r.height.finiteOr(10).clamped(4, 1e5))
    }

    var text: String? { if case .text(let t, _) = content { return t } else { return nil } }
    var textStyle: TextStyle? { if case .text(_, let s) = content { return s } else { return nil } }
    var imageAsset: UUID? { if case .image(let a) = content { return a } else { return nil } }
    var isTape: Bool { if case .tape = content { return true } else { return false } }
    var review: Review? { if case .tape(_, let r) = content { return r } else { return nil } }
}

enum LinkURL {
    /// Normalises user-typed links: adds https:// to bare domains, keeps mailto:/tel:, rejects junk.
    static func normalize(_ raw: String) -> String? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, s.count <= 2048, !s.contains(" ") else { return nil }
        if let u = URL(string: s), let scheme = u.scheme?.lowercased() {
            return ["http", "https", "mailto", "tel", "file"].contains(scheme) ? s : nil
        }
        guard s.contains("."), let u = URL(string: "https://" + s), u.host != nil else { return nil }
        return "https://" + s
    }
}

/// A page drawn on top of an imported document page instead of a ruled template.
enum PageBackground: Codable, Equatable {
    case pdf(asset: UUID, index: Int)
}

struct Page: Identifiable, Codable, Equatable {
    static let sizeRange: ClosedRange<CGFloat> = 72...14_400

    var id = UUID()
    var style: PageStyle = .ruled
    var paper: PaperColor = .white
    var size: PageSize = .a4
    /// Overrides `size` (imported PDF pages keep their own dimensions).
    var customSize: CGSize?
    var background: PageBackground?
    var strokes: [Stroke] = []
    var elements: [PageElement] = []
    /// Handwriting recognised on-device, for search. Not user-editable.
    var recognizedText: String?
    /// Fingerprint of the ink that `recognizedText` was computed from.
    var indexSignature: String?
    /// Non-nil when the page is bookmarked; the string is its (optional) label.
    var bookmark: String?
    /// Text of the imported document page (e.g. a PDF's own text), for search.
    var documentText: String?

    var pageSize: CGSize { customSize ?? size.size }
    var rect: CGRect { CGRect(origin: .zero, size: pageSize) }

    init(style: PageStyle = .ruled, paper: PaperColor = .white, size: PageSize = .a4) {
        self.style = style
        self.paper = paper
        self.size = size
    }

    /// A blank copy with the same look (template, paper, size, background).
    func emptyCopy() -> Page {
        var p = Page(style: style, paper: paper, size: size)
        p.customSize = customSize
        p.background = background
        return p
    }

    /// Tolerant decoding: unknown enum values fall back to defaults and unreadable strokes or
    /// elements are skipped instead of failing the whole notebook.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        style = (try? c.decode(PageStyle.self, forKey: .style)) ?? .blank
        paper = (try? c.decode(PaperColor.self, forKey: .paper)) ?? .white
        size = (try? c.decode(PageSize.self, forKey: .size)) ?? .a4
        if let cs = try? c.decode(CGSize.self, forKey: .customSize), cs.width.isFinite, cs.height.isFinite {
            customSize = CGSize(width: cs.width.clamped(Self.sizeRange.lowerBound, Self.sizeRange.upperBound),
                                height: cs.height.clamped(Self.sizeRange.lowerBound, Self.sizeRange.upperBound))
        }
        background = try? c.decode(PageBackground.self, forKey: .background)
        var seen = Set<UUID>()
        strokes = ((try? c.decode([Lossy<Stroke>].self, forKey: .strokes)) ?? []).compactMap(\.value)
            .filter { seen.insert($0.id).inserted }
        elements = ((try? c.decode([Lossy<PageElement>].self, forKey: .elements)) ?? []).compactMap(\.value)
            .filter { seen.insert($0.id).inserted }
        recognizedText = try? c.decode(String.self, forKey: .recognizedText)
        indexSignature = try? c.decode(String.self, forKey: .indexSignature)
        bookmark = (try? c.decode(String.self, forKey: .bookmark)).map { String($0.prefix(200)) }
        documentText = (try? c.decode(String.self, forKey: .documentText)).map { String($0.prefix(50_000)) }
    }

    /// Everything searchable on this page: typed text first, then recognised handwriting.
    var searchableText: String {
        let typed = elements.compactMap(\.text).joined(separator: "\n")
        return [typed, recognizedText ?? "", documentText ?? ""].filter { !$0.isEmpty }.joined(separator: "\n")
    }

    /// Changes whenever the ink changes; used to decide when handwriting needs re-recognising.
    var inkSignature: String {
        var h = Hasher()
        for s in strokes { h.combine(s.id); h.combine(s.points.count); h.combine(s.bounds.minX); h.combine(s.bounds.minY) }
        return "\(strokes.count)-\(h.finalize())"
    }
}

struct Notebook: Identifiable, Codable, Equatable {
    static let maxPages = 5_000

    var id = UUID()
    var title: String
    var created = Date()
    var modified = Date()
    var cover: RGBA = RGBA(0.20, 0.38, 0.85)
    var pages: [Page]
    /// Embedded files (images, imported PDFs, audio), referenced by elements, page backgrounds and recordings.
    var assets: [UUID: Data] = [:]
    var recordings: [Recording] = []

    init(title: String, cover: RGBA = RGBA(0.20, 0.38, 0.85), firstPage: Page = Page()) {
        self.title = Notebook.cleanTitle(title)
        self.cover = cover
        self.pages = [firstPage]
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = Notebook.cleanTitle((try? c.decode(String.self, forKey: .title)) ?? "")
        created = (try? c.decode(Date.self, forKey: .created)) ?? Date()
        modified = (try? c.decode(Date.self, forKey: .modified)) ?? created
        cover = (try? c.decode(RGBA.self, forKey: .cover)) ?? RGBA(0.20, 0.38, 0.85)
        var seen = Set<UUID>()
        pages = ((try? c.decode([Lossy<Page>].self, forKey: .pages)) ?? []).compactMap(\.value)
            .filter { seen.insert($0.id).inserted }
        if pages.isEmpty { pages = [Page()] } // a notebook always has at least one page
        if pages.count > Self.maxPages { pages = Array(pages.prefix(Self.maxPages)) }
        assets = (try? c.decode([UUID: Data].self, forKey: .assets)) ?? [:]
        recordings = ((try? c.decode([Lossy<Recording>].self, forKey: .recordings)) ?? []).compactMap(\.value)
            .filter { assets[$0.asset] != nil } // a recording without its audio is useless
    }

    static func cleanTitle(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .controlCharacters).joined()
        return t.isEmpty ? "Untitled" : String(t.prefix(200))
    }

    /// Asset ids still referenced by some page.
    var referencedAssets: Set<UUID> {
        var ids = Set<UUID>()
        for p in pages {
            if case .pdf(let a, _) = p.background { ids.insert(a) }
            for e in p.elements { if let a = e.imageAsset { ids.insert(a) } }
        }
        for r in recordings { ids.insert(r.asset) }
        return ids
    }

    /// Drops assets nothing references. Only safe when no undo history could bring a reference back.
    mutating func pruneAssets() {
        let keep = referencedAssets
        assets = assets.filter { keep.contains($0.key) }
    }

    var metadata: NotebookMetadata {
        // Per-page search text, capped so the uncompressed metadata block stays small.
        var budget = 400_000
        let transcripts = Dictionary(grouping: recordings.filter { $0.transcript != nil }, by: \.page)
        let texts = pages.map { p -> String in
            let spoken = (transcripts[p.id] ?? []).compactMap(\.transcript).joined(separator: "\n")
            let all = spoken.isEmpty ? p.searchableText : p.searchableText + "\n" + spoken
            let t = String(all.prefix(min(8_000, max(0, budget))))
            budget -= t.utf8.count
            return t
        }
        return NotebookMetadata(id: id, title: title, created: created, modified: modified, cover: cover,
                                pageCount: pages.count, pageTexts: texts)
    }
}

/// An audio recording made while writing. Strokes written meanwhile point back to it with an offset.
struct Recording: Codable, Identifiable, Equatable {
    var id = UUID()
    var asset: UUID
    var started: Date
    var duration: Double
    /// The page that was in view when recording started (its transcript is searched there).
    var page: UUID
    var transcript: String?
    var title: String { "Recording · " + started.formatted(date: .abbreviated, time: .shortened) }
}

/// The small header stored uncompressed at the front of a notebook file so the library can list
/// and search notebooks without decoding every stroke.
struct NotebookMetadata: Codable, Equatable, Identifiable {
    var id: UUID
    var title: String
    var created: Date
    var modified: Date
    var cover: RGBA
    var pageCount: Int
    var pageTexts: [String]?
    /// True for password-protected notebooks (their search text is never stored in the clear).
    var locked: Bool?
}

/// Decodes a value if possible and otherwise records nil, so one bad element doesn't fail an array.
struct Lossy<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}

// MARK: - Helpers

extension Comparable {
    func clamped(_ lo: Self, _ hi: Self) -> Self { min(max(self, lo), hi) }
}

extension Float {
    func finiteOr(_ fallback: Float) -> Float { isFinite ? self : fallback }
}

extension CGFloat {
    func finiteOr(_ fallback: CGFloat) -> CGFloat { isFinite ? self : fallback }
}

extension Double {
    func finiteOrDefault(_ fallback: Double) -> Double { isFinite ? self : fallback }
}
