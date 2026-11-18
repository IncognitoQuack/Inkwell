// Fuzz harness for everything that reads untrusted bytes: notebook files, encrypted payloads, images, PDFs,
// GoodNotes exports and the maths parser. Every input must either load or throw; a trap (crash) is a bug.
//   zsh Tools/fuzz/fuzz.sh codec-deep 5000 [seed]
// Targets: codec-raw, codec-deep (damage that keeps the checksum valid), crypto, png, pdf, goodnotes,
//          goodnotes-deep (damage to a valid export), math.
// Set FUZZ_OUT=file to save each input before it runs, so the last one written is the crasher.
import Foundation
import CoreGraphics
import ImageIO

struct XS: RandomNumberGenerator {
    var s: UInt64
    mutating func next() -> UInt64 { s ^= s << 13; s ^= s >> 7; s ^= s << 17; return s }
}
var rng = XS(s: UInt64(CommandLine.arguments.count > 3 ? CommandLine.arguments[3] : "88172645463325252")!)

func mutate(_ d: Data, lo: Int = 0, hi: Int? = nil) -> Data {
    var b = [UInt8](d)
    let hiMax = hi ?? b.count
    for _ in 0..<Int.random(in: 1...3, using: &rng) {
        let hi = min(hiMax, b.count)
        guard hi > lo + 1 else { break }
        switch Int.random(in: 0..<7, using: &rng) {
        case 0: for _ in 0..<Int.random(in: 1...8, using: &rng) { b[Int.random(in: lo..<hi, using: &rng)] ^= UInt8.random(in: 1...255, using: &rng) }
        case 1: b = Array(b[0..<Int.random(in: lo...hi, using: &rng)] + b[hi...])   // cut a tail of the region
        case 2: let at = Int.random(in: lo..<hi, using: &rng); b.insert(contentsOf: (0..<Int.random(in: 1...64, using: &rng)).map { _ in UInt8.random(in: 0...255, using: &rng) }, at: at)
        case 3: let a = Int.random(in: lo..<hi, using: &rng); let n = min(Int.random(in: 1...64, using: &rng), hi - a); for i in a..<(a + n) { b[i] = 0 }
        case 4: let a = Int.random(in: lo..<max(lo + 1, hi - 3), using: &rng); for i in a..<min(a + 4, b.count) { b[i] = 0xFF }
        case 5: let a = Int.random(in: lo..<hi, using: &rng); let n = min(Int.random(in: 1...128, using: &rng), hi - a); b.insert(contentsOf: Array(b[a..<(a + n)]), at: a)
        default: let a = Int.random(in: lo..<hi, using: &rng); b[a] = UInt8.random(in: 0...255, using: &rng)
        }
    }
    return Data(b)
}

func pt(_ x: Float, _ y: Float, _ p: Float = 0.5, _ t: Float = 0) -> InkPoint { InkPoint(x: x, y: y, pressure: p, time: t) }
func sampleNotebook() -> Notebook {
    var nb = Notebook(title: "Physics ✏️ नोट्स")
    nb.pages[0].strokes = (0..<12).map { i in
        Stroke(kind: i % 5 == 0 ? .highlighter : .pen, color: RGBA(0.1, 0.2, 0.9, 1), width: 2.5,
               points: (0..<20).map { pt(Float($0) * 3, Float(i) * 10, Float($0) / 30, Float($0) * 0.01) })!
    }
    nb.pages.append(Page(style: .grid, paper: .cream, size: .letter))
    var st = TextStyle(); st.font = .serif; st.size = 20
    nb.pages[0].elements = [PageElement(frame: CGRect(x: 80, y: 120, width: 300, height: 40), content: .text("Read https://apple.com", st)),
                            PageElement(frame: CGRect(x: 80, y: 300, width: 120, height: 80), content: .link, link: "example.org")]
    nb.pages[0].recognizedText = "handwritten words"
    return nb
}
func makePNG(w: Int, h: Int) -> Data {
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(srgbRed: 0.2, green: 0.5, blue: 0.9, alpha: 0.5)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    let out = NSMutableData(); let d = CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(d, ctx.makeImage()!, nil); CGImageDestinationFinalize(d); return out as Data
}

func fixCRC(_ d: Data) -> Data {
    var b = d
    guard let h = try? NotebookCodec.readHeader(b) else { return d }
    let total = NotebookCodec.headerSize + h.metaLength + h.payloadLength
    guard b.count >= total else { return d }
    let crc = CRC32.checksum(b[NotebookCodec.headerSize..<total])
    b.replaceSubrange(16..<20, with: withUnsafeBytes(of: crc.littleEndian) { Array($0) })
    return b
}

let target = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "codec"
let iters = CommandLine.arguments.count > 2 ? Int(CommandLine.arguments[2])! : 1000
let outPath = ProcessInfo.processInfo.environment["FUZZ_OUT"]
var slow: [(Double, String)] = []
var accepted = 0, rejected = 0

func run(_ name: String, _ input: Data, _ body: (Data) -> Bool) {
    if let p = outPath { try? input.write(to: URL(fileURLWithPath: p)) }
    let t = Date()
    if body(input) { accepted += 1 } else { rejected += 1 }
    let dt = Date().timeIntervalSince(t)
    if dt > 1.0 { slow.append((dt, name)) }
}

let plain = try! NotebookCodec.encode(sampleNotebook())
var withAsset = sampleNotebook()
let png = try! Importer.imageAsset(from: makePNG(w: 64, h: 32)); let aid = UUID()
withAsset.assets[aid] = png.data
withAsset.pages[0].elements.append(PageElement(frame: CGRect(x: 300, y: 500, width: 128, height: 64), content: .image(asset: aid)))
let assetEnc = try! NotebookCodec.encode(withAsset)
let locked = try! NotebookCodec.encode(sampleNotebook(), password: "pw")
let seeds = [plain, assetEnc]

switch target {
case "codec-raw":
    for _ in 0..<iters {
        let s = (seeds + [locked]).randomElement(using: &rng)!
        run("codec-raw", mutate(s)) { d in
            _ = try? NotebookCodec.decodeMetadata(d); _ = NotebookCodec.isIntact(d); _ = NotebookCodec.isEncrypted(d)
            return (try? NotebookCodec.decode(d, password: "pw")) != nil
        }
    }
case "codec-deep":
    for _ in 0..<iters {
        let s = seeds.randomElement(using: &rng)!
        let h = try! NotebookCodec.readHeader(s)
        let region = Bool.random(using: &rng)
            ? (NotebookCodec.headerSize, NotebookCodec.headerSize + h.metaLength)
            : (NotebookCodec.headerSize + h.metaLength, s.count)
        // mutate inside one region, keep the lengths and the checksum consistent
        var m = s
        let region2 = mutate(Data(s[region.0..<region.1]))
        if region2.count == region.1 - region.0 {
            m.replaceSubrange(region.0..<region.1, with: region2)
            run("codec-deep", fixCRC(m)) { d in
                _ = try? NotebookCodec.decodeMetadata(d)
                return (try? NotebookCodec.decode(d)) != nil
            }
        } else { // size changed: rebuild header lengths
            var out = Data(s[0..<NotebookCodec.headerSize]) + (region.0 == NotebookCodec.headerSize ? region2 + Data(s[region.1...]) : Data(s[NotebookCodec.headerSize..<region.0]) + region2)
            let ml = region.0 == NotebookCodec.headerSize ? region2.count : h.metaLength
            let pl = region.0 == NotebookCodec.headerSize ? h.payloadLength : region2.count
            out.replaceSubrange(8..<12, with: withUnsafeBytes(of: UInt32(ml).littleEndian) { Array($0) })
            out.replaceSubrange(12..<16, with: withUnsafeBytes(of: UInt32(pl).littleEndian) { Array($0) })
            run("codec-deep-resized", fixCRC(out)) { d in
                _ = try? NotebookCodec.decodeMetadata(d)
                return (try? NotebookCodec.decode(d)) != nil
            }
        }
    }
case "crypto":
    let sealed = try! NotebookCrypto.seal(Data("hello world payload".utf8), password: "pw")
    for _ in 0..<iters {
        run("crypto", mutate(sealed)) { d in (try? NotebookCrypto.open(d, password: "pw")) != nil }
    }
case "png":
    let base = makePNG(w: 64, h: 32)
    for _ in 0..<iters { run("png", mutate(base)) { d in (try? Importer.imageAsset(from: d)) != nil } }
case "pdf":
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("fuzz-\(getpid()).pdf")
    try! PageRenderer.exportPDF(sampleNotebook(), to: url)
    let base = try! Data(contentsOf: url)
    for _ in 0..<iters { run("pdf", mutate(base)) { d in (try? Importer.notebook(fromPDF: d, title: "f")) != nil } }
case "goodnotes":
    for _ in 0..<iters {
        let n = Int.random(in: 0...300, using: &rng)
        var d = Data((0..<n).map { _ in UInt8.random(in: 0...255, using: &rng) })
        if Bool.random(using: &rng) { d = Data([0x50, 0x4B, 0x03, 0x04]) + d }   // looks like a zip
        run("goodnotes", d) { d in
            _ = GoodNotesImporter.parseNotes(d)
            return (try? GoodNotesImporter.importNotebook(d, fallbackTitle: "x")) != nil
        }
    }
case "goodnotes-deep":
    let seed = try! makeGoodNotes(pages: 3, strokeOnPage: 2, extraItem: true)
    print("seed zip: \(seed.count) bytes, imports: \((try? GoodNotesImporter.importNotebook(seed, fallbackTitle: "x")) != nil)")
    for _ in 0..<iters {
        run("goodnotes-deep", mutate(seed)) { d in (try? GoodNotesImporter.importNotebook(d, fallbackTitle: "x")) != nil }
    }
case "math":
    let alphabet = Array("0123456789+-*/()%.^√×÷xX =,:−ol I")
    for _ in 0..<iters {
        let s = String((0..<Int.random(in: 0...40, using: &rng)).map { _ in alphabet.randomElement(using: &rng)! })
        run("math", Data(s.utf8)) { _ in MathEval.solve(s) != nil }
    }
default: print("unknown target"); exit(2)
}
print("\(target): \(iters) inputs, accepted \(accepted), rejected \(rejected), slow(>1s): \(slow.map { "\($0.1) \(String(format: "%.1f", $0.0))s" })")
