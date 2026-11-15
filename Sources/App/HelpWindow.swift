import AppKit
import SwiftUI

/// Gestures & shortcuts cheat-sheet (Help menu; shown once on first launch).
struct HelpView: View {
    private let sections: [(String, String, [(String, String)])] = [
        ("Pen (XPPen G640)", "pencil.tip", [
            ("Lower button: hold + draw", "Erase"),
            ("Lower button: click", "Swap to your previous tool"),
            ("Upper button: hold + drag", "Move the page"),
            ("Upper button: click", "Undo"),
            ("Hover", "See the nib's exact size and colour"),
        ]),
        ("Writing", "scribble.variable", [
            ("Pause at the end of a stroke", "Snap to line, arrow, rectangle, ellipse, triangle"),
            ("Hold Shift while drawing", "Perfectly straight line, 15° steps"),
            ("Scribble over ink", "Erase it"),
            ("Write a sum, then = and pause", "The answer appears"),
            ("Draw along the ruler (⌘R)", "Ink follows its edge"),
        ]),
        ("Selecting & editing", "lasso", [
            ("Lasso (L): circle ink", "Select; drag to move; ⌫ delete; ⌘D duplicate"),
            ("Click an image or text box", "Select it; drag the corner dot to resize"),
            ("Text tool (T): click", "New text box, or edit an existing one"),
            ("Text tool: drag a box", "Move it"),
            ("⌘C / ⌘V", "Copy and paste ink, pictures and text (between notebooks too)"),
            ("⌘-click", "Open a link"),
        ]),
        ("Moving around", "hand.draw", [
            ("Pinch, or ⌘ + scroll", "Zoom"),
            ("Two-finger double-tap", "Zoom in on that spot / back to fit"),
            ("Space + drag", "Move the page"),
            ("Page Up / Down, Home / End", "Previous / next, first / last page"),
            ("Mouse back / forward buttons", "Previous / next page"),
            ("⌥⌘Z", "Zoom window: write large, ink lands small"),
        ]),
        ("Tools", "keyboard", [
            ("P  H  E  L  T  U  K", "Pen, highlighter, eraser, lasso, text, tape, laser"),
            ("Esc", "Cancel what you're doing, then deselect"),
            ("⇧⌘Y", "Study cards made from your tape"),
            ("⌥⌘R", "Start / stop audio recording"),
            ("⇧⌘F", "Search all notes: typed, handwritten, PDFs, audio"),
        ]),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Gestures & Shortcuts").font(.largeTitle.weight(.semibold))
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 22, alignment: .top), GridItem(.flexible(), alignment: .top)], spacing: 22) {
                    ForEach(sections, id: \.0) { title, symbol, rows in
                        VStack(alignment: .leading, spacing: 8) {
                            Label(title, systemImage: symbol).font(.headline)
                            ForEach(rows, id: \.0) { k, v in
                                HStack(alignment: .firstTextBaseline, spacing: 10) {
                                    Text(k).font(.callout.weight(.medium)).frame(width: 190, alignment: .leading)
                                    Text(v).font(.callout).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
                    }
                }
            }
            .padding(26)
        }
        .frame(minWidth: 900, minHeight: 600)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

final class HelpWindowController: NSWindowController {
    init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 660), styleMask: [.titled, .closable, .resizable, .miniaturizable],
                         backing: .buffered, defer: false)
        w.title = "Inkwell Help"
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: HelpView())
        w.center()
        super.init(window: w)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
}
