import Compression
import CoreGraphics
import Foundation

/// Imports GoodNotes `.goodnotes` exports into Strokebook notebooks.
///
/// A `.goodnotes` file is a ZIP of length-delimited protobuf record streams:
/// - `index.events.pb`: document events. Type 30 = document (title), 2 = page template (attachment +
///   page size), 54 = page (template + sortable position), plus bookkeeping events we ignore.
/// - `notes/<id>`: one per page (id = the page UUID + 1). Records alternate between a short header and an
///   item; field 7 = pen stroke with field 4 = RGBA colour and field 2 = an Apple-LZ4 ("bv41") blob.
///   The blob is a "tpl" container: `tpl\0`, u32 length, a type signature such as
///   `vA(v)A(u)…` (v = u16, u = f32, A(x) = u32 count + items), then the data. Its first three fields are
///   the stroke's centre line: path ops (0 = move, 1 = quadratic curve), the start point, and per curve a
///   control + end point, each point being (x, y, radius) in page points, top-left origin.
/// - `attachments/<id>`: the page backgrounds (templates) as PDFs.
/// Item types other than pen strokes are counted and reported, never silently dropped.
enum GoodNotesImporter {
    enum ImportError: LocalizedError, Equatable {
        case notGoodNotes
        case damaged(String)
        case noPages

        var errorDescription: String? {
            switch self {
            case .notGoodNotes: return "That file isn’t a GoodNotes notebook (.goodnotes)."
            case .damaged(let why): return "The GoodNotes file couldn’t be read (\(why))."
            case .noPages: return "The GoodNotes notebook has no pages."
            }
        }
    }

    struct Result {
        var notebook: Notebook
        var strokes = 0
        /// Items Strokebook can't import yet, by GoodNotes item field number.
        var skipped: [Int: Int] = [:]
        var skippedCount: Int { skipped.values.reduce(0, +) }
    }

    static func importNotebook(_ data: Data, fallbackTitle: String) throws -> Result {
        let zip = try ZipArchive(data)
        guard let events = zip.file("index.events.pb") else { throw ImportError.notGoodNotes }

        // Document title, templates and pages from the event log.
        var title: String?
        var templates: [String: (attachment: String, size: CGSize)] = [:]
        var pages: [(id: String, template: String, position: String)] = []
        for record in ProtoReader.records(events) {
            guard let msg = ProtoReader.fields(record), let body = msg.first(where: { $0.number != 1 }),
                  let bodyData = body.data, let f = ProtoReader.fields(bodyData) else { continue }
            switch body.number {
            case 30:
                title = lww(f, 2) ?? title
            case 2:
                guard let tid = string(f, 2), let att = string(f, 4) else { continue }
                var size = CGSize(width: 834.24, height: 1078.825)
                if let sz = f.first(where: { $0.number == 8 })?.data, let s = ProtoReader.fields(sz) {
                    let w = s.first { $0.number == 1 }?.float, h = s.first { $0.number == 2 }?.float
                    if let w, let h, w.isFinite, h.isFinite, w > 10, h > 10 { size = CGSize(width: CGFloat(w), height: CGFloat(h)) }
                }
                templates[tid] = (att, size)
            case 54:
                guard let pid = string(f, 2) else { continue }
                pages.append((pid, lww(f, 3) ?? "", lww(f, 4) ?? ""))
            default:
                break
            }
        }
        // Later events for the same page win (GoodNotes appends updates).
        var latest: [String: (String, String)] = [:]
        var order: [String] = []
        for p in pages {
            if latest[p.id] == nil { order.append(p.id) }
            latest[p.id] = (p.template, p.position)
        }
        // Pages sort by their fractional-index position strings (plain byte order).
        let sorted = order.enumerated().sorted { a, b in
            let pa = latest[a.element]!.1, pb = latest[b.element]!.1
            return pa == pb ? a.offset < b.offset : Array(pa.utf8).lexicographicallyPrecedes(Array(pb.utf8))
        }.map(\.element)
        guard !sorted.isEmpty else { throw ImportError.noPages }

        let cleanTitle = (title ?? "").trimmingCharacters(in: .whitespaces)
        var nb = Notebook(title: cleanTitle.isEmpty || cleanTitle == "Untitled Notebook" ? fallbackTitle : cleanTitle)
        nb.pages = []
        var result = Result(notebook: nb)
        var assetFor: [String: UUID] = [:]

        for pid in sorted {
            let (tid, _) = latest[pid]!
            var page = Page(style: .blank, paper: .white, size: .a4)
            let template = templates[tid]
            page.customSize = CGSize(width: (template?.size.width ?? 834.24).clamped(Page.sizeRange.lowerBound, Page.sizeRange.upperBound),
                                     height: (template?.size.height ?? 1078.825).clamped(Page.sizeRange.lowerBound, Page.sizeRange.upperBound))
            if let att = template?.attachment, let pdf = zip.file("attachments/\(att)"), pdf.starts(with: Data("%PDF".utf8)) {
                let asset = assetFor[att] ?? UUID()
                assetFor[att] = asset
                nb.assets[asset] = pdf
                page.background = .pdf(asset: asset, index: 0)
            }
            if let notesID = uuidPlusOne(pid), let notes = zip.file("notes/\(notesID)") {
                let (strokes, skipped) = parseNotes(notes)
                page.strokes = strokes
                result.strokes += strokes.count
                for (k, v) in skipped { result.skipped[k, default: 0] += v }
            }
            nb.pages.append(page)
        }
        result.notebook = nb
        return result
    }

    // MARK: Notes (page items)

    static func parseNotes(_ data: Data) -> ([Stroke], [Int: Int]) {
        var strokes: [Stroke] = []
        var skipped: [Int: Int] = [:]
        for record in ProtoReader.records(data) {
            guard let msg = ProtoReader.fields(record), let first = msg.first else { continue }
            // Headers are small records with an id (1) and a version (2); items are a single nested field.
            if msg.contains(where: { $0.number == 2 && $0.data != nil }) && first.number == 1 { continue }
            guard let body = first.data, let f = ProtoReader.fields(body) else { continue }
            guard first.number == 7 else { skipped[first.number, default: 0] += 1; continue }
            guard let blob = f.first(where: { $0.number == 2 })?.data else { skipped[7, default: 0] += 1; continue }
            switch decodeStroke(blob, fields: f) {
            case .stroke(let s): strokes.append(s)
            case .empty: break // draws nothing in GoodNotes either (e.g. a scratch-out gesture's leftover)
            case .unsupported: skipped[7, default: 0] += 1
            }
        }
        return (strokes, skipped)
    }

    enum Decoded { case stroke(Stroke), empty, unsupported }

    static func decodeStroke(_ blob: Data, fields f: [ProtoReader.Field]) -> Decoded {
        guard let tpl = decompressAppleLZ4(blob), let parts = Tpl.parse(tpl) else { return .unsupported }
        return stroke(from: parts, fields: f)
    }

    /// Builds a stroke from a parsed tpl blob. Non-finite numbers in a damaged file are rejected, never trusted.
    static func stroke(from parts: [Tpl.Value], fields f: [ProtoReader.Field]) -> Decoded {
        if Tpl.isEmpty(parts) { return .empty }
        guard parts.count >= 4, case .u16s(let ops) = parts[1], case .floats(let start) = parts[2], case .floats(let segs) = parts[3],
              start.count >= 3, start.allSatisfy(\.isFinite), segs.allSatisfy(\.isFinite) else { return .unsupported }
        var color = RGBA(0, 0, 0)
        if let c = f.first(where: { $0.number == 4 })?.data, let cf = ProtoReader.fields(c) {
            let v = (1...4).map { n in cf.first { $0.number == n }?.float ?? (n == 4 ? 1 : 0) }
            color = RGBA(v[0], v[1], v[2], v[3])
        }
        // Centre line: start point, then per op either a quadratic curve (6 floats) or a move/line.
        var pts: [(CGFloat, CGFloat, CGFloat)] = [(CGFloat(start[0]), CGFloat(start[1]), CGFloat(start[2]))]
        var i = 0
        for op in ops.dropFirst() {
            if op == 1, i + 6 <= segs.count {
                let p0 = pts.last!
                let c = (CGFloat(segs[i]), CGFloat(segs[i + 1]), CGFloat(segs[i + 2]))
                let p1 = (CGFloat(segs[i + 3]), CGFloat(segs[i + 4]), CGFloat(segs[i + 5]))
                let len = hypot(c.0 - p0.0, c.1 - p0.1) + hypot(p1.0 - c.0, p1.1 - c.1)
                let n = Int(min((len / 1.5).rounded(.up), 64)).clamped(1, 64) // clamp before converting: huge values trap
                for k in 1...n {
                    let t = CGFloat(k) / CGFloat(n), u = 1 - t
                    pts.append((u * u * p0.0 + 2 * u * t * c.0 + t * t * p1.0,
                                u * u * p0.1 + 2 * u * t * c.1 + t * t * p1.1,
                                u * u * p0.2 + 2 * u * t * c.2 + t * t * p1.2))
                }
                i += 6
            } else if i + 3 <= segs.count {
                pts.append((CGFloat(segs[i]), CGFloat(segs[i + 1]), CGFloat(segs[i + 2])))
                i += 3
            }
        }
        // Strokebook nib: radius = width/2 × (0.22 + 0.78 × p^0.7). Take width from the widest point and
        // invert the curve for each point's pressure, so the imported line keeps its thick-thin shape.
        let maxR = max(pts.map(\.2).max() ?? 1, 0.1)
        let width = Float(maxR * 2)
        let ink = pts.map { p -> InkPoint in
            let ratio = Float(p.2 / maxR)
            let pressure = ratio <= 0.22 ? 0 : pow((ratio - 0.22) / 0.78, 1 / 0.7)
            return InkPoint(x: Float(p.0), y: Float(p.1), pressure: pressure.clamped(0, 1), time: 0)
        }
        // A translucent wide stroke is GoodNotes' highlighter.
        let kind: ToolKind = color.a < 0.9 && width > 6 ? .highlighter : .pen
        return Stroke(kind: kind, color: color, width: width, points: ink).map { Decoded.stroke($0) } ?? .empty
    }

    static func decompressAppleLZ4(_ data: Data) -> Data? {
        guard data.starts(with: Data("bv4".utf8)) else { return nil }
        return try? (data as NSData).decompressed(using: .lz4) as Data
    }

    // MARK: Small helpers

    private static func string(_ f: [ProtoReader.Field], _ n: Int) -> String? {
        f.first { $0.number == n }?.data.flatMap { String(data: $0, encoding: .utf8) }
    }

    /// A last-writer-wins register's value (field 1 of the nested message).
    private static func lww(_ f: [ProtoReader.Field], _ n: Int) -> String? {
        guard let d = f.first(where: { $0.number == n })?.data, let inner = ProtoReader.fields(d) else { return nil }
        return inner.first { $0.number == 1 }?.data.flatMap { String(data: $0, encoding: .utf8) }
    }

    /// GoodNotes names a page's notes file after the page UUID plus one (as a 128-bit number).
    static func uuidPlusOne(_ s: String) -> String? {
        guard let u = UUID(uuidString: s) else { return nil }
        var b = withUnsafeBytes(of: u.uuid) { Array($0) }
        for i in stride(from: 15, through: 0, by: -1) {
            b[i] = b[i] &+ 1
            if b[i] != 0 { break }
        }
        let t = (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15])
        return UUID(uuid: t).uuidString
    }
}

/// The "tpl" typed container used inside GoodNotes item blobs.
/// Signature grammar: `v` = u16, `u`/`f` = f32, `S(…)` = a struct of the listed types, `A(x)` = u32 count + count × x.
enum Tpl {
    enum Value: Equatable {
        case u16(UInt16)
        case f32(Float)
        case u16s([UInt16])
        case floats([Float])
        /// Arrays of structs (or other composites), kept as flattened numbers with their element count.
        case structs(count: Int, flat: [Float])
        case structValue([Float])
    }

    indirect enum TypeNode { case u16, f32, structOf([TypeNode]), array(TypeNode) }

    static func parseSignature(_ sig: [UInt8]) -> [TypeNode]? {
        var i = 0
        func node() -> TypeNode? {
            guard i < sig.count else { return nil }
            let c = sig[i]
            i += 1
            switch c {
            case UInt8(ascii: "v"): return .u16
            case UInt8(ascii: "u"), UInt8(ascii: "f"): return .f32
            case UInt8(ascii: "A"), UInt8(ascii: "S"):
                guard i < sig.count, sig[i] == UInt8(ascii: "(") else { return nil }
                i += 1
                var inner: [TypeNode] = []
                while i < sig.count, sig[i] != UInt8(ascii: ")") {
                    guard let n = node() else { return nil }
                    inner.append(n)
                }
                guard i < sig.count, !inner.isEmpty else { return nil }
                i += 1
                if c == UInt8(ascii: "A") { return inner.count == 1 ? .array(inner[0]) : .array(.structOf(inner)) }
                return .structOf(inner)
            default: return nil
            }
        }
        var out: [TypeNode] = []
        while i < sig.count {
            guard let n = node() else { return nil }
            out.append(n)
        }
        return out
    }

    /// Parses a decompressed tpl blob. nil when malformed: bad magic, unknown types, lengths that overrun,
    /// or bytes left over (then it isn't the structure we think it is).
    static func parse(_ b: Data) -> [Value]? {
        let bytes = [UInt8](b)
        guard bytes.count >= 9, bytes[0..<4] == [0x74, 0x70, 0x6C, 0x00] else { return nil }
        guard let sigEnd = bytes[8...].firstIndex(of: 0), sigEnd - 8 <= 512,
              let types = parseSignature(Array(bytes[8..<sigEnd])) else { return nil }
        var i = sigEnd + 1
        func u32() -> Int? {
            guard i + 4 <= bytes.count else { return nil }
            defer { i += 4 }
            return Int(bytes[i]) | Int(bytes[i + 1]) << 8 | Int(bytes[i + 2]) << 16 | Int(bytes[i + 3]) << 24
        }
        func u16() -> UInt16? {
            guard i + 2 <= bytes.count else { return nil }
            defer { i += 2 }
            return UInt16(bytes[i]) | UInt16(bytes[i + 1]) << 8
        }
        func f32() -> Float? {
            guard i + 4 <= bytes.count else { return nil }
            defer { i += 4 }
            return Float(bitPattern: UInt32(bytes[i]) | UInt32(bytes[i + 1]) << 8 | UInt32(bytes[i + 2]) << 16 | UInt32(bytes[i + 3]) << 24)
        }
        func read(_ t: TypeNode, into flat: inout [Float]) -> Bool {
            switch t {
            case .u16: guard let v = u16() else { return false }; flat.append(Float(v))
            case .f32: guard let v = f32() else { return false }; flat.append(v)
            case .structOf(let fields): for f in fields { guard read(f, into: &flat) else { return false } }
            case .array(let el):
                guard let n = u32(), n <= 10_000_000 else { return false }
                for _ in 0..<n { guard read(el, into: &flat) else { return false } }
            }
            return true
        }
        var out: [Value] = []
        for t in types {
            switch t {
            case .u16: guard let v = u16() else { return nil }; out.append(.u16(v))
            case .f32: guard let v = f32() else { return nil }; out.append(.f32(v))
            case .array(.u16):
                guard let n = u32(), n <= 10_000_000, i + n * 2 <= bytes.count else { return nil }
                out.append(.u16s((0..<n).map { _ in u16()! }))
            case .array(.f32):
                guard let n = u32(), n <= 10_000_000, i + n * 4 <= bytes.count else { return nil }
                out.append(.floats((0..<n).map { _ in f32()! }))
            case .array(let el):
                guard let n = u32(), n <= 10_000_000 else { return nil }
                var flat: [Float] = []
                for _ in 0..<n { guard read(el, into: &flat) else { return nil } }
                out.append(.structs(count: n, flat: flat))
            case .structOf:
                var flat: [Float] = []
                guard read(t, into: &flat) else { return nil }
                out.append(.structValue(flat))
            }
        }
        guard i == bytes.count else { return nil }
        return out
    }

    /// True when every array in the blob is empty: the item draws nothing.
    static func isEmpty(_ values: [Value]) -> Bool {
        values.allSatisfy { v in
            switch v {
            case .u16s(let a): return a.isEmpty
            case .floats(let a): return a.isEmpty
            case .structs(let n, _): return n == 0
            default: return true
            }
        }
    }
}

/// Minimal protobuf wire-format reader (no schema).
enum ProtoReader {
    struct Field {
        var number: Int
        var varint: UInt64?
        var data: Data?
        var float: Float?
        var double: Double?
    }

    /// Splits a stream of varint-length-prefixed messages.
    static func records(_ d: Data) -> [Data] {
        let b = [UInt8](d)
        var out: [Data] = []
        var i = 0
        while i < b.count {
            // Compare as UInt64 first: converting an absurd length to Int would trap on damaged input.
            guard let (n, j) = varint(b, i), n <= UInt64(b.count - j) else { break }
            out.append(Data(b[j..<(j + Int(n))]))
            i = j + Int(n)
        }
        return out
    }

    /// Parses one message's fields; nil if it isn't valid wire format.
    static func fields(_ d: Data) -> [Field]? {
        let b = [UInt8](d)
        var out: [Field] = []
        var i = 0
        while i < b.count {
            guard let (key, j) = varint(b, i) else { return nil }
            i = j
            let n = Int(key >> 3), wt = key & 7
            guard n > 0 else { return nil }
            switch wt {
            case 0:
                guard let (v, j2) = varint(b, i) else { return nil }
                out.append(Field(number: n, varint: v)); i = j2
            case 1:
                guard i + 8 <= b.count else { return nil }
                let bits = (0..<8).reduce(UInt64(0)) { $0 | UInt64(b[i + $1]) << (8 * UInt64($1)) }
                out.append(Field(number: n, double: Double(bitPattern: bits))); i += 8
            case 2:
                guard let (len, j2) = varint(b, i), len <= UInt64(b.count - j2) else { return nil }
                out.append(Field(number: n, data: Data(b[j2..<(j2 + Int(len))]))); i = j2 + Int(len)
            case 5:
                guard i + 4 <= b.count else { return nil }
                let bits = UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24
                out.append(Field(number: n, float: Float(bitPattern: bits))); i += 4
            default:
                return nil
            }
        }
        return out
    }

    static func varint(_ b: [UInt8], _ start: Int) -> (UInt64, Int)? {
        var v: UInt64 = 0, shift: UInt64 = 0, i = start
        while i < b.count, shift < 64 {
            let c = b[i]
            v |= UInt64(c & 0x7F) << shift
            i += 1
            if c < 0x80 { return (v, i) }
            shift += 7
        }
        return nil
    }
}

/// Minimal ZIP reader: stored and deflated entries via the central directory (no ZIP64, no encryption).
struct ZipArchive {
    private var entries: [String: (method: UInt16, compressed: Int, size: Int, offset: Int)] = [:]
    private let bytes: [UInt8]

    init(_ data: Data) throws {
        bytes = [UInt8](data)
        guard bytes.count >= 22, bytes.starts(with: [0x50, 0x4B]) else { throw GoodNotesImporter.ImportError.notGoodNotes }
        // End of central directory: search backwards (a comment may follow it).
        var eocd = -1
        var i = bytes.count - 22
        while i >= max(0, bytes.count - 65_557) {
            if bytes[i] == 0x50, bytes[i + 1] == 0x4B, bytes[i + 2] == 5, bytes[i + 3] == 6 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { throw GoodNotesImporter.ImportError.damaged("no ZIP directory") }
        let count = Int(le16(eocd + 10)), cdOffset = Int(le32(eocd + 16))
        guard count < 200_000, cdOffset < bytes.count else { throw GoodNotesImporter.ImportError.damaged("bad ZIP directory") }
        var p = cdOffset
        for _ in 0..<count {
            guard p + 46 <= bytes.count, le32(p) == 0x0201_4B50 else { throw GoodNotesImporter.ImportError.damaged("bad ZIP entry") }
            let method = le16(p + 10)
            let csize = Int(le32(p + 20)), usize = Int(le32(p + 24))
            let nlen = Int(le16(p + 28)), xlen = Int(le16(p + 30)), clen = Int(le16(p + 32))
            let local = Int(le32(p + 42))
            guard csize != 0xFFFF_FFFF, usize != 0xFFFF_FFFF, p + 46 + nlen <= bytes.count else {
                throw GoodNotesImporter.ImportError.damaged("ZIP64 isn't supported")
            }
            let name = String(decoding: bytes[(p + 46)..<(p + 46 + nlen)], as: UTF8.self)
            entries[name] = (method, csize, usize, local)
            p += 46 + nlen + xlen + clen
        }
    }

    var names: [String] { Array(entries.keys) }

    /// The entry's uncompressed contents, or nil when missing or unreadable.
    func file(_ name: String) -> Data? {
        guard let e = entries[name], e.offset + 30 <= bytes.count, le32(e.offset) == 0x0403_4B50 else { return nil }
        let start = e.offset + 30 + Int(le16(e.offset + 26)) + Int(le16(e.offset + 28))
        guard start + e.compressed <= bytes.count, e.size <= 512 << 20 else { return nil }
        let raw = Array(bytes[start..<(start + e.compressed)])
        switch e.method {
        case 0:
            return Data(raw)
        case 8:
            if e.size == 0 { return Data() }
            var out = [UInt8](repeating: 0, count: e.size)
            let n = raw.withUnsafeBufferPointer { src in
                out.withUnsafeMutableBufferPointer { dst in
                    compression_decode_buffer(dst.baseAddress!, e.size, src.baseAddress!, raw.count, nil, COMPRESSION_ZLIB)
                }
            }
            return n == e.size ? Data(out) : nil
        default:
            return nil
        }
    }

    private func le16(_ i: Int) -> UInt16 { UInt16(bytes[i]) | UInt16(bytes[i + 1]) << 8 }
    private func le32(_ i: Int) -> UInt32 {
        UInt32(bytes[i]) | UInt32(bytes[i + 1]) << 8 | UInt32(bytes[i + 2]) << 16 | UInt32(bytes[i + 3]) << 24
    }
}
