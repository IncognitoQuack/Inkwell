import AppKit
import Vision

/// On-device handwriting recognition (Apple Vision). Nothing leaves the Mac.
enum HandwritingRecognizer {
    /// Recognises text in an ink-only rendering. Returns lines top to bottom; empty on failure.
    static func recognize(_ image: CGImage, languageCorrection: Bool = true) -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        // Off for maths: correction "fixes" 2+3 into words.
        request.usesLanguageCorrection = languageCorrection
        request.automaticallyDetectsLanguage = true
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do { try handler.perform([request]) } catch { return [] }
        let obs = (request.results ?? []).sorted { a, b in
            // Vision's boxes are bottom-left origin: higher maxY = higher on the page.
            abs(a.boundingBox.midY - b.boundingBox.midY) > 0.01 ? a.boundingBox.midY > b.boundingBox.midY : a.boundingBox.minX < b.boundingBox.minX
        }
        return obs.compactMap { $0.topCandidates(1).first?.string }.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// Recognises just some strokes (for "Convert to Text"), rendered on their own.
    static func recognize(strokes: [Stroke], languageCorrection: Bool = true) -> String {
        guard !strokes.isEmpty else { return "" }
        let bounds = strokes.map(\.bounds).reduce(CGRect.null) { $0.union($1) }.insetBy(dx: -12, dy: -12)
        var page = Page(style: .blank)
        page.customSize = CGSize(width: max(bounds.width, 72), height: max(bounds.height, 72))
        page.strokes = strokes.map { $0.translated(dx: -bounds.minX, dy: -bounds.minY) }
        guard let img = PageRenderer.image(of: page, maxSide: min(2400, max(800, max(bounds.width, bounds.height) * 3)), inkOnly: true) else { return "" }
        return recognize(img, languageCorrection: languageCorrection).joined(separator: "\n")
    }
}

/// Keeps each page's `recognizedText` current in the background so handwriting is searchable.
/// It waits for a pause in writing, works one page at a time at low priority, and only re-reads
/// pages whose ink actually changed.
final class HandwritingIndexer {
    private weak var session: NotebookSession?
    private let queue = DispatchQueue(label: "inkwell.indexer", qos: .background)
    private var pending: DispatchWorkItem?
    private var busy = false

    init(session: NotebookSession) {
        self.session = session
    }

    /// Call after edits; indexing starts once writing pauses.
    func schedule(after delay: TimeInterval = 3) {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.runNext() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func runNext() {
        guard !busy, let session else { return }
        guard let page = session.notebook.pages.first(where: { p in
            p.strokes.isEmpty ? p.recognizedText != nil : p.indexSignature != p.inkSignature
        }) else { return }
        if page.strokes.isEmpty {
            session.setRecognizedText("", signature: page.inkSignature, for: page.id)
            schedule(after: 0.1)
            return
        }
        busy = true
        let signature = page.inkSignature
        queue.async { [weak self] in
            let text = PageRenderer.image(of: page, maxSide: 2200, inkOnly: true).map { HandwritingRecognizer.recognize($0).joined(separator: "\n") } ?? ""
            DispatchQueue.main.async {
                guard let self else { return }
                self.busy = false
                // Ignored if the page changed meanwhile (signature mismatch); it gets picked up again.
                self.session?.setRecognizedText(text, signature: signature, for: page.id)
                self.schedule(after: 0.5)
            }
        }
    }
}
