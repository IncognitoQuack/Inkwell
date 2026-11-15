import AppKit
import SwiftUI

/// Flash-card study: every study tape in the notebook is a card. Shows the area around the tape with
/// the answer covered, then revealed; your rating schedules the next review (SM-2).
final class StudyModel: ObservableObject {
    struct Card: Equatable { let page: UUID; let tape: UUID }

    @Published private(set) var queue: [Card] = []
    @Published private(set) var index = 0
    @Published var revealed = false
    @Published private(set) var image: NSImage?
    @Published private(set) var reviewed = 0
    @Published private(set) var finished = false
    let studyingAll: Bool

    private let session: NotebookSession

    init(session: NotebookSession, all: Bool) {
        self.session = session
        studyingAll = all
        let now = Date()
        var cards: [(Card, Date)] = []
        for p in session.notebook.pages {
            for e in p.elements where e.isTape {
                let due = e.review?.due ?? now
                if all || due <= now { cards.append((Card(page: p.id, tape: e.id), due)) }
            }
        }
        // Most overdue first.
        queue = cards.sorted { $0.1 < $1.1 }.map(\.0)
        finished = queue.isEmpty
        render()
    }

    var current: Card? { queue.indices.contains(index) ? queue[index] : nil }

    static func dueCount(_ nb: Notebook, now: Date = Date()) -> Int {
        nb.pages.reduce(0) { $0 + $1.elements.filter { $0.isTape && ($0.review?.due ?? now) <= now }.count }
    }

    func reveal() {
        guard !revealed else { return }
        revealed = true
        render()
    }

    func grade(_ g: Review.Grade) {
        guard let c = current, revealed, let page = session.page(c.page),
              let tape = page.elements.first(where: { $0.id == c.tape }) else { return }
        session.setReview((tape.review ?? .new()).answered(g), forTape: c.tape, on: c.page)
        reviewed += 1
        if g == .again { queue.append(c) } // see it again this session
        index += 1
        revealed = false
        finished = index >= queue.count
        render()
    }

    /// Renders the tape with some page around it for context.
    private func render() {
        guard let c = current, let page = session.page(c.page), let tape = page.elements.first(where: { $0.id == c.tape }) else {
            image = nil
            return
        }
        let region = tape.frame.insetBy(dx: -160, dy: -110).intersection(page.rect)
        let maxSide: CGFloat = 1800
        guard let full = PageRenderer.image(of: page, maxSide: maxSide, assets: session.assets, revealedTapes: revealed ? [c.tape] : []) else { return }
        let scale = CGFloat(full.width) / page.pageSize.width
        let crop = CGRect(x: region.minX * scale, y: region.minY * scale, width: region.width * scale, height: region.height * scale).integral
        guard let cut = full.cropping(to: crop) else { return }
        image = NSImage(cgImage: cut, size: NSSize(width: cut.width, height: cut.height))
    }
}

struct StudyView: View {
    @ObservedObject var model: StudyModel
    let close: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            if model.finished {
                Spacer()
                Image(systemName: "checkmark.seal.fill").font(.system(size: 52)).foregroundStyle(.green)
                Text(model.reviewed == 0 ? "Nothing is due right now." : "Done: \(model.reviewed) card\(model.reviewed == 1 ? "" : "s") reviewed.")
                    .font(.title2.weight(.semibold))
                Text(model.reviewed == 0 ? "Cover answers with the Tape tool (U); every tape becomes a card." :
                        "Cards come back when they’re due: sooner if they were hard, later if easy.")
                    .foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("Close") { close() }.keyboardShortcut(.defaultAction)
                Spacer()
            } else {
                HStack {
                    Text("Card \(min(model.index + 1, model.queue.count)) of \(model.queue.count)").font(.headline)
                    Spacer()
                    ProgressView(value: Double(model.index), total: Double(max(model.queue.count, 1))).frame(width: 200)
                }
                Group {
                    if let img = model.image {
                        Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .shadow(color: .black.opacity(0.2), radius: 6, y: 2)
                            .transition(.opacity)
                            .id(model.revealed)
                    } else {
                        RoundedRectangle(cornerRadius: 10).fill(Color.white)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .animation(Motion.reduced ? nil : .easeInOut(duration: 0.2), value: model.revealed)
                if model.revealed {
                    HStack(spacing: 10) {
                        ForEach(Review.Grade.allCases) { g in
                            Button {
                                model.grade(g)
                            } label: {
                                Text(g.title).frame(minWidth: 80)
                            }
                            .controlSize(.large)
                            .keyboardShortcut(KeyEquivalent(Character("\(Review.Grade.allCases.firstIndex(of: g)! + 1)")), modifiers: [])
                            .help("Key \(Review.Grade.allCases.firstIndex(of: g)! + 1)")
                        }
                    }
                } else {
                    Button("Show Answer") { model.reveal() }
                        .controlSize(.large).buttonStyle(.borderedProminent)
                        .keyboardShortcut(.space, modifiers: [])
                }
            }
        }
        .padding(24)
        .frame(minWidth: 720, minHeight: 560)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

final class StudyWindowController: NSWindowController {
    init(session: NotebookSession, all: Bool) {
        let model = StudyModel(session: session, all: all)
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 600), styleMask: [.titled, .closable, .resizable],
                         backing: .buffered, defer: false)
        w.title = "Study – \(session.notebook.title)"
        w.isReleasedWhenClosed = false
        super.init(window: w)
        w.contentView = NSHostingView(rootView: StudyView(model: model) { [weak w] in w?.close() })
        w.center()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
}
