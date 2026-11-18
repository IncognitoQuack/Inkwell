import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Toolbar

struct ToolbarActions {
    var toggleSidebar: () -> Void
    var addPage: () -> Void
    var deletePage: () -> Void
    var previousPage: () -> Void
    var nextPage: () -> Void
    var zoomIn: () -> Void
    var zoomOut: () -> Void
    var fitWidth: () -> Void
    var exportPDF: () -> Void
    var exportPagePDF: () -> Void
    var exportPagePNG: () -> Void
    var setTemplate: (PageStyle?, PaperColor?, Bool) -> Void
    var insertImage: () -> Void
    var addLink: () -> Void
    var removeLink: () -> Void
    var convertToText: () -> Void
    var deleteSelection: () -> Void
    var duplicateSelection: () -> Void
    var toggleBookmark: () -> Void
    var toggleZoomWindow: () -> Void
    var toggleRuler: () -> Void
    var study: (Bool) -> Void
    var setAllTapes: (Bool) -> Void
    var solve: () -> Void
    var playSelection: () -> Void
}

/// Popover visibility (SwiftUI @State isn't usable in this toolchain, so it lives in an object).
final class ToolbarUI: ObservableObject {
    @Published var stylePopover = false
    @Published var audioPopover = false
}

struct NotebookToolbar: View {
    @ObservedObject var tools: ToolState
    @ObservedObject var session: NotebookSession
    @ObservedObject var canvas: CanvasState
    @ObservedObject var ui: ToolbarUI
    @ObservedObject var audio: AudioController
    let actions: ToolbarActions
    @Namespace private var toolNS
    private var spring: Animation? { Motion.reduced ? nil : .spring(response: 0.32, dampingFraction: 0.82) }

    var body: some View {
        HStack(spacing: 12) {
            iconButton("sidebar.left", help: "Pages (⌥⌘S)", enabled: true) { actions.toggleSidebar() }
            toolPicker
            Divider().frame(height: 26)
            ViewThatFits(in: .horizontal) {
                options(compact: false)
                options(compact: true)
            }
            .id("\(tools.tool.rawValue)-\(canvas.hasSelection)")
            .transition(.opacity.combined(with: .offset(y: 4)))
            .animation(spring, value: tools.tool)
            .animation(spring, value: canvas.hasSelection)
            Spacer(minLength: 6)
            saveStatus
            Button { ui.audioPopover.toggle() } label: {
                Image(systemName: audio.isRecording ? "record.circle.fill" : "waveform")
                    .font(.system(size: 14, weight: .medium)).frame(width: 30, height: 28)
                    .foregroundStyle(audio.isRecording ? Color.red : audio.playing != nil ? Color.accentColor : .primary)
                    .symbolEffect(.pulse, isActive: audio.isRecording && !Motion.reduced)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Record audio linked to your ink (⌥⌘R)")
            .popover(isPresented: $ui.audioPopover, arrowEdge: .bottom) { AudioPanel(audio: audio, session: session) }
            Button { actions.toggleRuler() } label: {
                Image(systemName: "ruler")
                    .font(.system(size: 14, weight: .medium)).frame(width: 30, height: 28)
                    .background(RoundedRectangle(cornerRadius: 7).fill(canvas.rulerShown ? Color.accentColor.opacity(0.18) : .clear))
                    .foregroundStyle(canvas.rulerShown ? Color.accentColor : .primary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Ruler (⌘R)")
            Button { actions.toggleZoomWindow() } label: {
                Image(systemName: "rectangle.and.text.magnifyingglass")
                    .font(.system(size: 14, weight: .medium)).frame(width: 30, height: 28)
                    .background(RoundedRectangle(cornerRadius: 7).fill(canvas.zoomWindowOpen ? Color.accentColor.opacity(0.18) : .clear))
                    .foregroundStyle(canvas.zoomWindowOpen ? Color.accentColor : .primary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Zoom window: write large, ink lands small (⌥⌘Z)")
            insertMenu
            pageControls
            Divider().frame(height: 26)
            HStack(spacing: 2) {
                iconButton("arrow.uturn.backward", help: "Undo (⌘Z)", enabled: session.canUndo) { session.undoManager.undo() }
                iconButton("arrow.uturn.forward", help: "Redo (⇧⌘Z)", enabled: session.canRedo) { session.undoManager.redo() }
            }
            moreMenu
        }
        .padding(.horizontal, 12)
        .frame(height: 50)
        .background(.bar)
    }

    // MARK: Tools

    private var toolPicker: some View {
        HStack(spacing: 1) {
            ForEach(Tool.allCases) { t in
                Button { withAnimation(spring) { tools.tool = t } } label: {
                    Image(systemName: t.symbol)
                        .font(.system(size: 15, weight: .medium))
                        .frame(width: 32, height: 30)
                        .background {
                            // One highlight that slides between tools.
                            if tools.tool == t {
                                RoundedRectangle(cornerRadius: 7).fill(Color.accentColor.opacity(0.18))
                                    .matchedGeometryEffect(id: "toolPill", in: toolNS)
                            }
                        }
                        .foregroundStyle(tools.tool == t ? Color.accentColor : .primary)
                        .scaleEffect(tools.tool == t ? 1.06 : 1)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("\(t.title) (\(t.shortcutKey.uppercased()))")
                .accessibilityLabel(t.title)
            }
        }
    }

    @ViewBuilder private func options(compact: Bool) -> some View {
        if canvas.hasSelection && tools.tool == .lasso {
            selectionActions(compact: compact)
        } else {
            switch tools.tool {
            case .pen, .highlighter:
                HStack(spacing: 10) {
                    swatches(compact ? Array(palette.prefix(3)) : palette)
                    styleButton
                }
            case .eraser:
                HStack(spacing: 8) {
                    eraserSizes
                    Picker("", selection: $tools.eraserMode) {
                        ForEach(EraserMode.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                    .help("Whole stroke removes strokes you touch; Precise cuts only where you rub")
                }
            case .lasso:
                hint(compact ? "Circle ink to select" : "Circle ink or click an item · drag to move · ⌫ delete")
            case .text:
                textOptions(compact: compact)
            case .laser:
                hint("Points without leaving marks: for presenting or screen sharing")
            case .tape:
                HStack(spacing: 8) {
                    swatches(ToolState.tapePalette)
                    Button("Peel All") { actions.setAllTapes(true) }.help("Reveal every tape")
                    Button("Cover All") { actions.setAllTapes(false) }.help("Cover every tape again")
                    Button { actions.study(false) } label: { Label("Study", systemImage: "rectangle.on.rectangle.angled") }
                        .help("Flash cards from your tapes (spaced repetition)")
                    if !compact { hint("Drag to cover · click to peel") }
                }
            }
        }
    }

    private var palette: [RGBA] { tools.tool == .highlighter ? ToolState.highlighterPalette : ToolState.penPalette }

    private func hint(_ s: String) -> some View {
        Text(s).font(.callout).foregroundStyle(.secondary).lineLimit(1)
    }

    private func swatches(_ colors: [RGBA]) -> some View {
        HStack(spacing: 6) {
            ForEach(Array(colors.enumerated()), id: \.offset) { _, c in
                let selected = sameHue(c, tools.activeColor)
                Button { tools.activeColor = c } label: {
                    Circle().fill(Color(nsColor: c.opaque.nsColor))
                        .frame(width: 19, height: 19)
                        .overlay(Circle().stroke(Color.primary.opacity(0.15), lineWidth: 0.5))
                        .padding(3)
                        .overlay(Circle().stroke(selected ? Color.accentColor : .clear, lineWidth: 2))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
            }
            let custom = !colors.contains { sameHue($0, tools.activeColor) }
            Button { ColorPanelBridge.shared.show(for: tools) } label: {
                Circle()
                    .fill(AngularGradient(colors: [.red, .yellow, .green, .cyan, .blue, .purple, .red], center: .center))
                    .frame(width: 19, height: 19)
                    .overlay(Circle().fill(Color(nsColor: tools.activeColor.opaque.nsColor)).frame(width: 9, height: 9).opacity(custom ? 1 : 0))
                    .padding(3)
                    .overlay(Circle().stroke(custom ? Color.accentColor : .clear, lineWidth: 2))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Custom colour")
        }
    }

    /// Width + opacity ("darkness") in one popover, with a live preview of the nib.
    private var styleButton: some View {
        Button { ui.stylePopover.toggle() } label: {
            HStack(spacing: 5) {
                let d = CGFloat(min(16, max(5, tools.activeWidth * (tools.tool == .highlighter ? 0.5 : 2))))
                Circle().fill(Color(nsColor: tools.activeColor.nsColor))
                    .frame(width: d, height: d)
                    .overlay(Circle().stroke(Color.primary.opacity(0.35), lineWidth: 0.75))
                    .frame(width: 20, height: 20)
                    .animation(spring, value: d)
                Text(String(format: "%.1f", tools.activeWidth)).font(.callout.monospacedDigit())
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 7).frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.06)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Width and opacity")
        .popover(isPresented: $ui.stylePopover, arrowEdge: .bottom) { stylePopover }
    }

    private var stylePopover: some View {
        let hl = tools.tool == .highlighter
        return VStack(alignment: .leading, spacing: 14) {
            Text(hl ? "Highlighter" : "Pen").font(.headline)
            VStack(alignment: .leading, spacing: 4) {
                HStack { Text("Width"); Spacer(); Text(String(format: "%.1f pt", tools.activeWidth)).monospacedDigit().foregroundStyle(.secondary) }
                Slider(value: Binding(get: { Double(tools.activeWidth) }, set: { tools.activeWidth = Float($0) }),
                       in: hl ? 4...60 : 0.5...20)
                HStack(spacing: 6) {
                    ForEach(hl ? ToolState.highlighterWidths : ToolState.penWidths, id: \.self) { w in
                        Button(String(format: "%g", w)) { tools.activeWidth = w }.controlSize(.small)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack { Text("Opacity"); Spacer(); Text("\(Int((tools.activeOpacity * 100).rounded()))%").monospacedDigit().foregroundStyle(.secondary) }
                Slider(value: Binding(get: { Double(tools.activeOpacity) }, set: { tools.activeOpacity = Float($0) }), in: 0.1...1)
            }
            StrokePreview(kind: hl ? .highlighter : .pen, color: tools.activeColor, width: tools.activeWidth)
                .frame(height: 54)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.white))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.1)))
        }
        .padding(16)
        .frame(width: 270)
    }

    private var eraserSizes: some View {
        HStack(spacing: 2) {
            ForEach(Array(ToolState.eraserRadii.enumerated()), id: \.offset) { i, r in
                Button { tools.eraserRadius = r } label: {
                    Circle().stroke(Color.primary.opacity(0.8), lineWidth: 1.5)
                        .frame(width: CGFloat(6 + i * 6), height: CGFloat(6 + i * 6))
                        .frame(width: 30, height: 28)
                        .background(RoundedRectangle(cornerRadius: 7).fill(abs(tools.eraserRadius - r) < 0.01 ? Color.accentColor.opacity(0.18) : .clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(["Small", "Medium", "Large"][i] + " eraser")
            }
        }
    }

    private func textOptions(compact: Bool) -> some View {
        HStack(spacing: 8) {
            Picker("", selection: $tools.textStyle.font) {
                ForEach(TextFont.allCases) { Text($0.title).tag($0) }
            }
            .labelsHidden().fixedSize().help("Font")
            HStack(spacing: 0) {
                Button { tools.textStyle.size = max(TextStyle.sizeRange.lowerBound, tools.textStyle.size - 2) } label: { Image(systemName: "minus").frame(width: 22, height: 24) }
                Text("\(Int(tools.textStyle.size))").font(.callout.monospacedDigit()).frame(width: 26)
                Button { tools.textStyle.size = min(TextStyle.sizeRange.upperBound, tools.textStyle.size + 2) } label: { Image(systemName: "plus").frame(width: 22, height: 24) }
            }
            .buttonStyle(.plain)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
            .help("Size")
            toggle("bold", on: tools.textStyle.bold) { tools.textStyle.bold.toggle() }
            toggle("italic", on: tools.textStyle.italic) { tools.textStyle.italic.toggle() }
            if !compact {
                Picker("", selection: $tools.textStyle.alignment) {
                    Image(systemName: "text.alignleft").tag(TextAlign.left)
                    Image(systemName: "text.aligncenter").tag(TextAlign.center)
                    Image(systemName: "text.alignright").tag(TextAlign.right)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            swatches(compact ? Array(ToolState.penPalette.prefix(3)) : Array(ToolState.penPalette.prefix(5)))
            toggle("highlighter", on: tools.textStyle.highlight != nil) {
                tools.textStyle.highlight = tools.textStyle.highlight == nil ? RGBA(1.0, 0.92, 0.35, 0.55) : nil
            }
            .help("Highlight background")
        }
    }

    private func selectionActions(compact: Bool) -> some View {
        HStack(spacing: 8) {
            if canvas.selectionHasInk {
                Button { actions.convertToText() } label: { Label("To Text", systemImage: "text.viewfinder") }
                    .help("Convert handwriting to typed text")
                Button { actions.solve() } label: { Label("Solve", systemImage: "function") }
                    .help("Solve handwritten arithmetic (⇧⌘=)")
                if canvas.selectionHasAudio {
                    Button { actions.playSelection() } label: { Label("Play", systemImage: "play.fill") }
                        .help("Play the audio recorded while this was written")
                }
                swatches(Array(ToolState.penPalette.prefix(compact ? 3 : 6)))
            }
            Button { actions.addLink() } label: { Label(canvas.selectionLink == nil ? "Link" : "Edit Link", systemImage: "link") }
            if canvas.selectionLink != nil {
                Button { actions.removeLink() } label: { Image(systemName: "link.badge.plus").symbolRenderingMode(.hierarchical) }
                    .help("Remove link")
            }
            Button { actions.duplicateSelection() } label: { Image(systemName: "plus.square.on.square") }.help("Duplicate (⌘D)")
            Button(role: .destructive) { actions.deleteSelection() } label: { Image(systemName: "trash") }.help("Delete (⌫)")
        }
        .controlSize(.regular)
    }

    private func toggle(_ symbol: String, on: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13, weight: .semibold))
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 6).fill(on ? Color.accentColor.opacity(0.2) : Color.primary.opacity(0.06)))
                .foregroundStyle(on ? Color.accentColor : .primary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Right side

    @ViewBuilder private var saveStatus: some View {
        if let err = session.saveError {
            Label("Not saved", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange).font(.callout)
                .help("Strokebook couldn’t save: \(err). Your work is safe in memory and saving will retry.")
        }
    }

    private var insertMenu: some View {
        Menu {
            Button("Image or PDF…") { actions.insertImage() }
            Button("Text Box") { tools.tool = .text }
            Divider()
            Button("New Page After This One") { actions.addPage() }
        } label: { Image(systemName: "plus.circle") }
            .menuStyle(.borderlessButton).fixedSize().help("Insert")
    }

    private var pageControls: some View {
        let bookmarked = session.currentPage?.bookmark != nil
        return HStack(spacing: 2) {
            iconButton("chevron.up", help: "Previous page", enabled: session.currentPageIndex > 0) { actions.previousPage() }
            Text("\(session.currentPageIndex + 1) / \(session.notebook.pages.count)")
                .font(.callout.monospacedDigit()).foregroundStyle(.secondary).frame(minWidth: 44)
            iconButton("chevron.down", help: "Next page", enabled: session.currentPageIndex < session.notebook.pages.count - 1) { actions.nextPage() }
            iconButton(bookmarked ? "bookmark.fill" : "bookmark", help: "Bookmark this page", enabled: true) { actions.toggleBookmark() }
                .foregroundStyle(bookmarked ? Color.orange : .primary)
            Menu {
                Button("Add Page After This One") { actions.addPage() }
                Divider()
                Section("Template") {
                    ForEach(PageStyle.allCases) { s in Button(s.title) { actions.setTemplate(s, nil, false) } }
                }
                Section("Paper") {
                    ForEach(PaperColor.allCases) { p in Button(p.title) { actions.setTemplate(nil, p, false) } }
                }
                Button("Apply This Page’s Template to All Pages") { actions.setTemplate(nil, nil, true) }
                Divider()
                Button("Delete This Page", role: .destructive) { actions.deletePage() }
                    .disabled(session.notebook.pages.count <= 1)
            } label: { Image(systemName: "doc.text") }
                .menuStyle(.borderlessButton).fixedSize().help("Page")
        }
    }

    private var moreMenu: some View {
        Menu {
            Button("Zoom In") { actions.zoomIn() }
            Button("Zoom Out") { actions.zoomOut() }
            Button("Fit Width") { actions.fitWidth() }
            Divider()
            Button("Export Notebook as PDF…") { actions.exportPDF() }
            Button("Export This Page as PDF…") { actions.exportPagePDF() }
            Button("Export This Page as PNG…") { actions.exportPagePNG() }
        } label: { Image(systemName: "square.and.arrow.up") }
            .menuStyle(.borderlessButton).fixedSize().help("Zoom & export")
    }

    private func iconButton(_ name: String, help: String, enabled: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name).font(.system(size: 14, weight: .medium)).frame(width: 28, height: 28).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .help(help)
    }

    private func sameHue(_ a: RGBA, _ b: RGBA) -> Bool {
        abs(a.r - b.r) < 0.01 && abs(a.g - b.g) < 0.01 && abs(a.b - b.b) < 0.01
    }
}

/// A sample stroke drawn with the real ink engine, so the preview matches what you'll get.
struct StrokePreview: View {
    let kind: ToolKind
    let color: RGBA
    let width: Float

    var body: some View {
        Canvas { ctx, size in
            let b = StrokeBuilder(kind: kind, color: color, width: width, scale: 1, simulatePressure: false)
            let n = 60
            for i in 0..<n {
                let u = Double(i) / Double(n - 1)
                let x = 16 + u * Double(size.width - 32), y = Double(size.height) / 2 + sin(u * .pi * 2) * Double(size.height) * 0.22
                b.add(x: x, y: y, pressure: kind == .pen ? 0.25 + 0.75 * sin(u * .pi) : 0.6, timestamp: u * 0.5)
            }
            guard let s = b.makeStroke() else { return }
            ctx.fill(Path(InkGeometry.outlinePath(for: s)), with: .color(Color(nsColor: color.nsColor)))
        }
    }
}

/// Routes the system colour panel to the active tool. Non-continuous, so dragging around the wheel
/// doesn't flood the undo history when it recolours a selection.
final class ColorPanelBridge: NSObject {
    static let shared = ColorPanelBridge()
    private weak var tools: ToolState?

    func show(for tools: ToolState) {
        self.tools = tools
        let panel = NSColorPanel.shared
        panel.showsAlpha = false
        panel.isContinuous = false
        panel.color = tools.activeColor.opaque.nsColor
        panel.setTarget(self)
        panel.setAction(#selector(colorChanged(_:)))
        panel.orderFront(nil)
    }

    @objc private func colorChanged(_ panel: NSColorPanel) {
        tools?.activeColor = RGBA(panel.color)
    }
}

// MARK: - Page sidebar

/// Page thumbnails rendered in the background and refreshed when a page's version changes.
final class ThumbnailStore: ObservableObject {
    @Published private(set) var images: [UUID: NSImage] = [:]
    private var rendered: [UUID: Int] = [:]
    private let queue = DispatchQueue(label: "inkwell.sidebar.thumbs", qos: .utility)

    func image(for page: Page, version: Int, assets: AssetCache) -> NSImage? {
        if rendered[page.id] != version {
            rendered[page.id] = version
            queue.async { [weak self] in
                guard let cg = PageRenderer.image(of: page, maxSide: 260, assets: assets) else { return }
                let img = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                DispatchQueue.main.async { if self?.rendered[page.id] == version { self?.images[page.id] = img } }
            }
        }
        return images[page.id]
    }
}

final class SidebarUI: ObservableObject {
    @Published var bookmarksOnly = false
}

struct PageSidebar: View {
    @ObservedObject var session: NotebookSession
    @ObservedObject var thumbs: ThumbnailStore
    @ObservedObject var ui: SidebarUI
    let goTo: (Int) -> Void

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $ui.bookmarksOnly) {
                Text("Pages").tag(false)
                Text("Bookmarks").tag(true)
            }
            .pickerStyle(.segmented).labelsHidden().padding(10)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 14) {
                        let items = Array(session.notebook.pages.enumerated()).filter { !ui.bookmarksOnly || $0.element.bookmark != nil }
                        if items.isEmpty {
                            Text(ui.bookmarksOnly ? "No bookmarks yet.\nUse the bookmark button in the toolbar." : "")
                                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.top, 30)
                        }
                        ForEach(items, id: \.element.id) { i, page in
                            thumbnail(page, index: i).id(page.id)
                        }
                    }
                    .padding(.vertical, 12)
                }
                .onChange(of: session.currentPageIndex) { _, i in
                    if session.notebook.pages.indices.contains(i) {
                        withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(session.notebook.pages[i].id, anchor: .center) }
                    }
                }
            }
        }
        .frame(width: 168)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func thumbnail(_ page: Page, index i: Int) -> some View {
        let current = i == session.currentPageIndex
        let size = page.pageSize
        let w: CGFloat = 112, h = max(40, w * size.height / max(size.width, 1))
        return VStack(spacing: 5) {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let img = thumbs.image(for: page, version: session.pageVersions[page.id] ?? 0, assets: session.assets) {
                        Image(nsImage: img).resizable()
                    } else {
                        Rectangle().fill(Color(nsColor: page.paper.rgba.nsColor))
                    }
                }
                .frame(width: w, height: h)
                .clipShape(RoundedRectangle(cornerRadius: 3))
                .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(current ? Color.accentColor : .clear, lineWidth: 2.5).padding(-3))
                if page.bookmark != nil {
                    Image(systemName: "bookmark.fill").font(.system(size: 13)).foregroundStyle(.orange).offset(x: -4, y: -1)
                }
            }
            Text("\(i + 1)").font(.caption.monospacedDigit()).foregroundStyle(current ? Color.accentColor : .secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture { goTo(i) }
        .contextMenu {
            Button("Add Page After") {
                var p = page.emptyCopy()
                if p.background != nil { p.background = nil; p.style = .blank }
                session.insertPage(p, at: i + 1)
            }
            Button("Duplicate Page") { session.duplicatePage(id: page.id) }
            Button(page.bookmark == nil ? "Bookmark" : "Remove Bookmark") { session.toggleBookmark(id: page.id) }
            Divider()
            Button("Move Up") { session.movePage(id: page.id, by: -1) }.disabled(i == 0)
            Button("Move Down") { session.movePage(id: page.id, by: 1) }.disabled(i == session.notebook.pages.count - 1)
            Divider()
            Button("Delete Page", role: .destructive) { session.deletePage(id: page.id) }.disabled(session.notebook.pages.count <= 1)
        }
        .accessibilityLabel("Page \(i + 1)\(page.bookmark != nil ? ", bookmarked" : "")")
    }
}

// MARK: - Window controller

final class NotebookWindowController: NSWindowController, NSWindowDelegate {
    let session: NotebookSession
    let canvas: CanvasView
    private let indexer: HandwritingIndexer
    private let sidebarHost: NSView
    private var sidebarWidth: NSLayoutConstraint!
    private var bag = Set<AnyCancellable>()
    private let thumbs = ThumbnailStore()
    let audio: AudioController
    private var study: StudyWindowController?
    var onClose: ((NotebookWindowController) -> Void)?

    init(session: NotebookSession, tools: ToolState) {
        self.session = session
        canvas = CanvasView(session: session, tools: tools)
        indexer = HandwritingIndexer(session: session)
        audio = AudioController(session: session)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 860),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.minSize = NSSize(width: 760, height: 480)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .preferred
        sidebarHost = NSView()
        super.init(window: window)
        window.delegate = self
        audio.canvas = canvas
        canvas.audio = audio

        let actions = ToolbarActions(
            toggleSidebar: { [weak self] in self?.toggleSidebar() },
            addPage: { [weak self] in self?.addPage() },
            deletePage: { [weak self] in self?.deleteCurrentPage() },
            previousPage: { [weak self] in self?.goToPage(offset: -1) },
            nextPage: { [weak self] in self?.goToPage(offset: 1) },
            zoomIn: { [weak self] in self?.canvas.zoom(by: 1.25) },
            zoomOut: { [weak self] in self?.canvas.zoom(by: 0.8) },
            fitWidth: { [weak self] in self?.canvas.zoomToFitWidth() },
            exportPDF: { [weak self] in self?.exportPDF(currentPageOnly: false) },
            exportPagePDF: { [weak self] in self?.exportPDF(currentPageOnly: true) },
            exportPagePNG: { [weak self] in self?.exportPagePNG() },
            setTemplate: { [weak self] style, paper, all in self?.setTemplate(style, paper, all) },
            insertImage: { [weak self] in self?.canvas.chooseImage() },
            addLink: { [weak self] in self?.promptForLink() },
            removeLink: { [weak self] in self?.canvas.removeLinks() },
            convertToText: { [weak self] in self?.canvas.convertSelectionToText() },
            deleteSelection: { [weak self] in self?.canvas.deleteSelection() },
            duplicateSelection: { [weak self] in self?.canvas.duplicateSelection() },
            toggleBookmark: { [weak self] in self?.toggleBookmark() },
            toggleZoomWindow: { [weak self] in self?.canvas.toggleZoomWriter() },
            toggleRuler: { [weak self] in self?.canvas.toggleRuler() },
            study: { [weak self] all in self?.openStudy(all: all) },
            setAllTapes: { [weak self] r in self?.canvas.setAllTapes(revealed: r) },
            solve: { [weak self] in self?.canvas.solveSelection() },
            playSelection: { [weak self] in self?.canvas.playSelection() })
        let bar = NSHostingView(rootView: NotebookToolbar(tools: tools, session: session, canvas: canvas.state, ui: ToolbarUI(), audio: audio, actions: actions))
        let sidebar = NSHostingView(rootView: PageSidebar(session: session, thumbs: thumbs, ui: SidebarUI()) { [weak self] i in
            self?.canvas.scrollToPage(i)
        })
        let divider = NSBox()
        divider.boxType = .separator
        for v in [bar, sidebar, divider, canvas, sidebarHost] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false }
        sidebarHost.wantsLayer = true
        sidebarHost.layer?.masksToBounds = true
        sidebarHost.addSubview(sidebar)
        sidebarHost.addSubview(divider)
        let root = NSView()
        root.addSubview(sidebarHost)
        root.addSubview(canvas)
        root.addSubview(bar)
        sidebarWidth = sidebarHost.widthAnchor.constraint(equalToConstant: UserDefaults.standard.bool(forKey: "sidebarHidden") ? 0 : 169)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: root.topAnchor),
            bar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bar.heightAnchor.constraint(equalToConstant: 50),
            sidebarHost.topAnchor.constraint(equalTo: bar.bottomAnchor),
            sidebarHost.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            sidebarHost.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            sidebarWidth,
            sidebar.topAnchor.constraint(equalTo: sidebarHost.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: sidebarHost.bottomAnchor),
            sidebar.leadingAnchor.constraint(equalTo: sidebarHost.leadingAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: 168),
            divider.topAnchor.constraint(equalTo: sidebarHost.topAnchor),
            divider.bottomAnchor.constraint(equalTo: sidebarHost.bottomAnchor),
            divider.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),
            canvas.topAnchor.constraint(equalTo: bar.bottomAnchor),
            canvas.leadingAnchor.constraint(equalTo: sidebarHost.trailingAnchor),
            canvas.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            canvas.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        window.contentView = root
        window.title = session.notebook.title
        window.setFrameAutosaveName("Notebook-\(session.notebook.id.uuidString)")
        if window.frame.origin == .zero { window.center() }

        session.$notebook.map(\.title).removeDuplicates()
            .sink { [weak window] t in window?.title = t }.store(in: &bag)
        // Keep handwriting searchable: re-read changed pages once writing pauses.
        session.$pageVersions.dropFirst().sink { [weak self] _ in self?.indexer.schedule() }.store(in: &bag)
        indexer.schedule(after: 1.5)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { session.undoManager }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        canvas.endTextEditing()
        if audio.isRecording { audio.stopRecording() }
        guard let error = session.flush() else { return true }
        let alert = NSAlert()
        alert.messageText = "“\(session.notebook.title)” couldn’t be saved."
        alert.informativeText = "\(error.localizedDescription)\n\nIf you close it now, changes since the last save will be lost."
        alert.addButton(withTitle: "Keep Open")
        alert.addButton(withTitle: "Close Without Saving")
        alert.buttons[1].hasDestructiveAction = true
        return alert.runModal() == .alertSecondButtonReturn
    }

    func windowWillClose(_ notification: Notification) {
        if audio.isRecording { audio.stopRecording() } // never lose a recording when the window closes
        audio.stopPlayback()
        study?.close()
        onClose?(self)
    }

    func openStudy(all: Bool) {
        canvas.endTextEditing()
        if canvas.tapeCount == 0 {
            canvas.showHUD("Cover answers with the Tape tool (U) first: each tape is a card", symbol: "rectangle.dashed")
            return
        }
        if !all, StudyModel.dueCount(session.notebook) == 0 {
            let alert = NSAlert()
            alert.messageText = "No cards are due right now."
            alert.informativeText = "Study all \(canvas.tapeCount) cards anyway?"
            alert.addButton(withTitle: "Study All")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            return openStudy(all: true)
        }
        study?.close()
        study = StudyWindowController(session: session, all: all)
        study?.showWindow(nil)
    }

    func windowDidResignKey(_ notification: Notification) { session.saveNow() }

    // MARK: Actions

    func toggleSidebar() {
        let hide = sidebarWidth.constant > 0
        UserDefaults.standard.set(hide, forKey: "sidebarHidden")
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.allowsImplicitAnimation = true
            sidebarWidth.animator().constant = hide ? 0 : 169
            window?.contentView?.layoutSubtreeIfNeeded()
        }
    }

    func addPage() {
        let i = session.addPageAfterCurrent()
        DispatchQueue.main.async { self.canvas.scrollToPage(i) }
    }

    func deleteCurrentPage() {
        guard let page = session.currentPage, session.notebook.pages.count > 1 else { NSSound.beep(); return }
        if !page.strokes.isEmpty || !page.elements.isEmpty {
            let alert = NSAlert()
            alert.messageText = "Delete page \(session.currentPageIndex + 1)?"
            alert.informativeText = "You can undo this with ⌘Z."
            alert.addButton(withTitle: "Delete")
            alert.addButton(withTitle: "Cancel")
            alert.buttons[0].hasDestructiveAction = true
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        session.deletePage(id: page.id)
    }

    func goToPage(offset: Int) {
        canvas.scrollToPage((session.currentPageIndex + offset).clamped(0, session.notebook.pages.count - 1))
    }

    func toggleBookmark() {
        guard let p = session.currentPage else { return }
        session.toggleBookmark(id: p.id)
        let on = session.currentPage?.bookmark != nil
        canvas.showHUD(on ? "Page bookmarked" : "Bookmark removed", symbol: on ? "bookmark.fill" : "bookmark.slash")
    }

    func setTemplate(_ style: PageStyle?, _ paper: PaperColor?, _ all: Bool) {
        guard let current = session.currentPage else { return }
        if all {
            session.setStyle(current.style, paper: current.paper, forPages: session.notebook.pages.map(\.id))
        } else {
            session.setStyle(style, paper: paper, forPages: [current.id])
        }
    }

    private var safeTitle: String { session.notebook.title.replacingOccurrences(of: "/", with: "-") }

    func exportPDF(currentPageOnly: Bool) {
        guard let window else { return }
        canvas.endTextEditing()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        let page = session.currentPageIndex
        panel.nameFieldStringValue = safeTitle + (currentPageOnly ? " – page \(page + 1)" : "") + ".pdf"
        panel.beginSheetModal(for: window) { [session] response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try PageRenderer.exportPDF(session.notebook, pages: currentPageOnly ? [page] : nil, to: url)
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                NSAlert(error: error).beginSheetModal(for: window)
            }
        }
    }

    func exportPagePNG() {
        guard let window, let page = session.currentPage else { return }
        canvas.endTextEditing()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = safeTitle + " – page \(session.currentPageIndex + 1).png"
        panel.beginSheetModal(for: window) { [session] response in
            guard response == .OK, let url = panel.url else { return }
            do {
                let side = max(page.pageSize.width, page.pageSize.height) * 3 // ~216 dpi
                guard let img = PageRenderer.image(of: page, maxSide: min(side, 6000), assets: session.assets) else { throw CocoaError(.fileWriteUnknown) }
                try PageRenderer.writePNG(img, to: url)
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                NSAlert(error: error).beginSheetModal(for: window)
            }
        }
    }

    func lockWithPassword() {
        let changing = session.password != nil
        guard let pw = PasswordPrompt.choose(title: changing ? "Change Password" : "Lock “\(session.notebook.title)”") else { return }
        session.setPassword(pw)
        canvas.showHUD(changing ? "Password changed" : "Notebook locked", symbol: "lock.fill")
    }

    func removePassword() {
        guard session.password != nil else { return }
        let alert = NSAlert()
        alert.messageText = "Remove the password from “\(session.notebook.title)”?"
        alert.informativeText = "Anyone using this Mac will be able to open it, and its text will appear in search."
        alert.addButton(withTitle: "Remove Password")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        session.setPassword(nil)
        canvas.showHUD("Password removed", symbol: "lock.open")
    }

    func promptForLink() {
        guard let window, canvas.hasSelection else { NSSound.beep(); return }
        let alert = NSAlert()
        alert.messageText = canvas.selectionLink == nil ? "Add Link" : "Edit Link"
        alert.informativeText = "Clicking the selection with the lasso, or ⌘-clicking it with any tool, opens this link."
        let field = NSTextField(string: canvas.selectionLink ?? "")
        field.placeholderString = "https://example.com"
        field.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Add Link")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] r in
            guard r == .alertFirstButtonReturn, let self else { return }
            if !self.canvas.addLink(field.stringValue) {
                let bad = NSAlert()
                bad.messageText = "That doesn’t look like a web link."
                bad.informativeText = "Use an address like example.com or https://example.com (mailto: works too)."
                bad.beginSheetModal(for: window)
            }
        }
    }

    func rename() {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Rename Notebook"
        let field = NSTextField(string: session.notebook.title)
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [session] r in
            if r == .alertFirstButtonReturn { session.rename(field.stringValue) }
        }
    }
}
