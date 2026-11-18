import Foundation
import CoreGraphics
import ImageIO
let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("fuzz-gn-\(getpid())")

/// Protobuf encoding helpers for building synthetic GoodNotes exports.
func pbVarint(_ v: UInt64) -> Data { var v = v; var d = Data(); repeat { var b = UInt8(v & 0x7F); v >>= 7; if v > 0 { b |= 0x80 }; d.append(b) } while v > 0; return d }
func pbBytes(_ n: Int, _ d: Data) -> Data { pbVarint(UInt64(n << 3 | 2)) + pbVarint(UInt64(d.count)) + d }
func pbString(_ n: Int, _ s: String) -> Data { pbBytes(n, Data(s.utf8)) }
func pbFloat(_ n: Int, _ f: Float) -> Data { var d = pbVarint(UInt64(n << 3 | 5)); withUnsafeBytes(of: f.bitPattern.littleEndian) { d.append(contentsOf: $0) }; return d }
func pbInt(_ n: Int, _ v: UInt64) -> Data { pbVarint(UInt64(n << 3)) + pbVarint(v) }
func pbRecord(_ m: Data) -> Data { pbVarint(UInt64(m.count)) + m }
func lww(_ s: String) -> Data { pbString(1, s) + pbBytes(2, pbInt(1, 1) + pbInt(2, 7)) }

func tplStroke(start: (Float, Float, Float), quads: [(Float, Float, Float, Float, Float, Float)]) -> Data {
    var d = Data("tpl\0".utf8)
    let sig = Data("vA(v)A(u)A(u)A(v)A(v)A(u)A(u)A(u)A(u)A(v)\0".utf8)
    var body = Data()
    func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { body.append(contentsOf: $0) } }
    func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { body.append(contentsOf: $0) } }
    func f(_ v: Float) { withUnsafeBytes(of: v.bitPattern.littleEndian) { body.append(contentsOf: $0) } }
    u16(2)
    u32(UInt32(quads.count + 1)); u16(0); for _ in quads { u16(1) }
    u32(3); f(start.0); f(start.1); f(start.2)
    u32(UInt32(quads.count * 6)); for q in quads { [q.0, q.1, q.2, q.3, q.4, q.5].forEach(f) }
    for _ in 0..<7 { u32(0) } // outline arrays GoodNotes precomputes; Inkwell rebuilds its own
    let total = UInt32(8 + sig.count + body.count)
    withUnsafeBytes(of: total.littleEndian) { d.append(contentsOf: $0) }
    return d + sig + body
}

func makeGoodNotes(pages: Int, strokeOnPage: Int, extraItem: Bool = false) throws -> Data {
    let dir = tmp.appendingPathComponent("gn-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir.appendingPathComponent("notes"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: dir.appendingPathComponent("attachments"), withIntermediateDirectories: true)
    let doc = UUID().uuidString, tid = UUID().uuidString, att = UUID().uuidString
    var events = pbRecord(pbString(1, doc) + pbBytes(30, pbString(1, doc) + pbBytes(2, lww("Lecture 4"))))
    events += pbRecord(pbString(1, tid) + pbBytes(2, pbString(1, doc) + pbString(2, tid) + pbString(4, att) + pbBytes(8, pbFloat(1, 600) + pbFloat(2, 800))))
    // Pages are appended out of order on purpose: their position strings decide the order.
    let ids = (0..<pages).map { _ in UUID().uuidString }
    for (k, pid) in ids.enumerated().reversed() {
        events += pbRecord(pbString(1, doc) + pbBytes(54, pbString(1, doc) + pbString(2, pid) + pbBytes(3, lww(tid)) + pbBytes(4, lww("p\(k)"))))
    }
    try events.write(to: dir.appendingPathComponent("index.events.pb"))
    // A template PDF.
    var box = CGRect(x: 0, y: 0, width: 300, height: 400)
    let pdfURL = dir.appendingPathComponent("attachments/\(att)")
    let ctx = CGContext(pdfURL as CFURL, mediaBox: &box, nil)!
    ctx.beginPDFPage(nil); ctx.setFillColor(CGColor(srgbRed: 0.98, green: 0.95, blue: 0.85, alpha: 1)); ctx.fill(box); ctx.endPDFPage(); ctx.closePDF()
    for (k, pid) in ids.enumerated() {
        var notes = Data()
        if k == strokeOnPage {
            let blob = try (tplStroke(start: (100, 200, 1), quads: [(150, 180, 2, 200, 200, 3), (250, 220, 2, 300, 200, 1)]) as NSData).compressed(using: .lz4) as Data
            let color = pbFloat(1, 0.2) + pbFloat(2, 0.3) + pbFloat(3, 0.9) + pbFloat(4, 1)
            notes += pbRecord(pbString(1, UUID().uuidString) + pbBytes(2, pbInt(1, 3) + pbInt(2, 5)))
            notes += pbRecord(pbBytes(7, pbString(1, UUID().uuidString) + pbBytes(2, blob) + pbBytes(4, color)))
            if extraItem { notes += pbRecord(pbBytes(12, pbString(1, "unknown"))) }
        }
        try notes.write(to: dir.appendingPathComponent("notes/\(GoodNotesImporter.uuidPlusOne(pid)!)"))
    }
    let zipURL = tmp.appendingPathComponent("gn-\(UUID().uuidString).goodnotes")
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
    p.currentDirectoryURL = dir
    p.arguments = ["-q", "-r", zipURL.path, "."]
    try p.run(); p.waitUntilExit()
    return try Data(contentsOf: zipURL)
}

