import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Model

final class LibraryModel: ObservableObject {
    let store: LibraryStore
    @Published private(set) var items: [NotebookMetadata] = []
    @Published private(set) var problems: [String] = []
    @Published private(set) var thumbnails: [UUID: NSImage] = [:]
    @Published var query = ""
    @Published var selection: UUID?
    @Published var showingNew = false
    /// Bumped to ask the search field to take focus.
    @Published var searchFocusRequest = 0
    @Published private(set) var folders = LibraryFolders()
    /// Shown while PDFs are being imported in the background.
    @Published private(set) var importing: String?
    /// nil = All Notebooks.
    @Published var selectedFolder: UUID?
    let draft = NewNotebookDraft()

    var open: (UUID, Int?) -> Void = { _, _ in }
    var willDelete: (UUID) -> Void = { _ in }

    private var thumbKeys: [UUID: Date] = [:]
    private let thumbQueue = DispatchQueue(label: "inkwell.thumbs", qos: .utility)
    private var bag = Set<AnyCancellable>()

    init(store: LibraryStore) {
        self.store = store
        NotificationCenter.default.publisher(for: .inkwellNotebookSaved)
            .sink { [weak self] n in
                guard let nb = n.userInfo?["notebook"] as? Notebook else { return }
                self?.notebookSaved(nb, locked: n.userInfo?["locked"] as? Bool ?? false)
            }
            .store(in: &bag)
        reload()
    }

    /// Notebooks in the selected folder (or all).
    var inFolder: [NotebookMetadata] {
        guard let f = selectedFolder, let folder = folders.folders.first(where: { $0.id == f }) else { return items }
        let ids = Set(folder.notebooks)
        return items.filter { ids.contains($0.id) }
    }

    var filtered: [NotebookMetadata] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return inFolder }
        return inFolder.filter { $0.title.localizedStandardContains(q) }
    }

    // MARK: Folders

    private func saveFolders() {
        do { try store.saveFolders(folders) } catch { NSAlert(error: error).runModal() }
    }

    private func askName(_ title: String, initial: String = "") -> String? {
        let alert = NSAlert()
        alert.messageText = title
        let field = NSTextField(string: initial)
        field.placeholderString = "Folder name"
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return LibraryFolder.cleanName(field.stringValue)
    }

    func newFolder() {
        guard let name = askName("New Folder") else { return }
        let f = LibraryFolder(name: name)
        folders.folders.append(f)
        saveFolders()
        selectedFolder = f.id
    }

    func renameFolder(_ id: UUID) {
        guard let i = folders.folders.firstIndex(where: { $0.id == id }), let name = askName("Rename Folder", initial: folders.folders[i].name) else { return }
        folders.folders[i].name = name
        saveFolders()
    }

    func deleteFolder(_ id: UUID) {
        guard let f = folders.folders.first(where: { $0.id == id }) else { return }
        let alert = NSAlert()
        alert.messageText = "Delete the folder “\(f.name)”?"
        alert.informativeText = "The notebooks in it are not deleted; they stay in All Notebooks."
        alert.addButton(withTitle: "Delete Folder")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        folders.folders.removeAll { $0.id == id }
        if selectedFolder == id { selectedFolder = nil }
        saveFolders()
    }

    func move(_ notebook: UUID, to folder: UUID?) {
        folders.move(notebook, to: folder)
        saveFolders()
    }

    /// New and imported notebooks land in the folder being viewed.
    private func fileIntoSelectedFolder(_ id: UUID) {
        guard let f = selectedFolder else { return }
        move(id, to: f)
    }

    /// Loads a notebook, asking for its password if it's locked. Returns nil if cancelled or unreadable.
    private func loadAsking(_ id: UUID) -> (Notebook, String?)? {
        var password: String?
        var prompt = "Enter the password for this notebook."
        while true {
            do {
                return (try store.load(id: id, password: password).notebook, password)
            } catch NotebookCodec.CodecError.locked {
                guard let pw = PasswordPrompt.ask(title: "This notebook is locked", message: prompt) else { return nil }
                password = pw
            } catch NotebookCrypto.CryptoError.wrongPassword {
                prompt = "That password isn’t right. Try again."
                guard let pw = PasswordPrompt.ask(title: "This notebook is locked", message: prompt) else { return nil }
                password = pw
            } catch {
                NSAlert(error: error).runModal()
                return nil
            }
        }
    }

    struct SearchHit: Identifiable {
        var id: String { "\(notebook.id)-\(page)" }
        var notebook: NotebookMetadata
        var page: Int
        var snippet: AttributedString
    }

    /// Matches inside notes: typed text and recognised handwriting, per page, with a snippet.
    var contentHits: [SearchHit] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2 else { return [] }
        var hits: [SearchHit] = []
        for m in items {
            for (i, text) in (m.pageTexts ?? []).enumerated() {
                guard let r = text.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) else { continue }
                hits.append(SearchHit(notebook: m, page: i, snippet: Self.snippet(text, around: r)))
                if hits.count >= 200 { return hits }
            }
        }
        return hits
    }

    static func snippet(_ text: String, around r: Range<String.Index>) -> AttributedString {
        let start = text.index(r.lowerBound, offsetBy: -40, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(r.upperBound, offsetBy: 60, limitedBy: text.endIndex) ?? text.endIndex
        func clean(_ s: Substring) -> String { s.replacingOccurrences(of: "\n", with: " ") }
        var out = AttributedString((start > text.startIndex ? "…" : "") + clean(text[start..<r.lowerBound]))
        var match = AttributedString(clean(text[r]))
        match.inlinePresentationIntent = .stronglyEmphasized
        match.backgroundColor = Color.yellow.opacity(0.35)
        out += match
        out += AttributedString(clean(text[r.upperBound..<end]) + (end < text.endIndex ? "…" : ""))
        return out
    }

    func focusSearch() { searchFocusRequest += 1 }

    func importPDFs() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf] + [UTType(filenameExtension: "goodnotes"), UTType(filenameExtension: LibraryStore.fileExtension)].compactMap { $0 }
        panel.allowsMultipleSelection = true
        panel.message = "Choose PDFs to write on, or GoodNotes notebooks (.goodnotes) to bring over."
        guard panel.runModal() == .OK else { return }
        importFiles(panel.urls)
    }

    /// Imports PDFs (and .inkwell files) as notebooks in the background, then opens the first one.
    func importFiles(_ urls: [URL], openFirst: Bool = true) {
        let urls = urls.filter { $0.isFileURL }
        guard !urls.isEmpty else { return }
        importing = urls.count == 1 ? "Importing “\(urls[0].deletingPathExtension().lastPathComponent)”…" : "Importing \(urls.count) files…"
        let store = self.store
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var failures: [String] = []
            var made: [(Notebook?, UUID)] = []
            var notes: [String] = []
            for url in urls {
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                do {
                    if url.pathExtension.lowercased() == LibraryStore.fileExtension {
                        made.append((nil, try store.importNotebookFile(url)))
                        continue
                    }
                    if url.pathExtension.lowercased() == "goodnotes" {
                        let r = try GoodNotesImporter.importNotebook(Data(contentsOf: url, options: .mappedIfSafe),
                                                                     fallbackTitle: url.deletingPathExtension().lastPathComponent)
                        try store.save(r.notebook)
                        made.append((r.notebook, r.notebook.id))
                        if r.skippedCount > 0 {
                            notes.append("“\(r.notebook.title)”: \(r.notebook.pages.count) pages and \(r.strokes) strokes imported; \(r.skippedCount) item(s) such as typed text or pictures aren’t supported yet and were left out.")
                        }
                        continue
                    }
                    guard UTType(filenameExtension: url.pathExtension)?.conforms(to: .pdf) == true else {
                        throw Importer.ImportError.unreadablePDF
                    }
                    let data = try Data(contentsOf: url, options: .mappedIfSafe)
                    var nb = try Importer.notebook(fromPDF: data, title: url.deletingPathExtension().lastPathComponent)
                    if let asset = nb.assets.keys.first { PDFText.fill(&nb.pages, pdfAsset: asset, data: data) }
                    try store.save(nb)
                    made.append((nb, nb.id))
                } catch {
                    failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
                }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.importing = nil
                for (nb, id) in made {
                    if let nb { self.notebookSaved(nb) }
                    self.fileIntoSelectedFolder(id)
                }
                if made.contains(where: { $0.0 == nil }) { self.reload() }
                if !failures.isEmpty || !notes.isEmpty {
                    let alert = NSAlert()
                    alert.messageText = failures.isEmpty ? "Imported, with a note." : "Some files couldn’t be imported."
                    alert.informativeText = (failures + notes).joined(separator: "\n")
                    alert.runModal()
                }
                if openFirst, let first = made.first?.1 { self.open(first, nil) }
            }
        }
    }

    func reload() {
        let listing = store.list()
        items = listing.notebooks
        problems = listing.problems.map { "\($0.file): \($0.reason)" }
        var f = store.loadFolders()
        let before = f
        f.sanitize(existing: Set(items.map(\.id)))
        folders = f
        if f != before { try? store.saveFolders(f) } // forget notebooks that were deleted elsewhere
        if let s = selectedFolder, !f.folders.contains(where: { $0.id == s }) { selectedFolder = nil }
        for m in items where thumbKeys[m.id] != m.modified && m.locked != true { makeThumbnail(id: m.id, modified: m.modified, notebook: nil) }
    }

    private func notebookSaved(_ nb: Notebook, locked: Bool = false) {
        var meta = nb.metadata
        if locked {
            // Mirror what's on disk: title only, no search text, no picture of the contents.
            meta.pageTexts = nil
            meta.locked = true
        }
        if let i = items.firstIndex(where: { $0.id == nb.id }) { items[i] = meta } else { items.append(meta) }
        items.sort { $0.modified > $1.modified }
        if locked { thumbnails[nb.id] = nil; thumbKeys[nb.id] = nb.modified } else { makeThumbnail(id: nb.id, modified: nb.modified, notebook: nb) }
    }

    private func makeThumbnail(id: UUID, modified: Date, notebook: Notebook?) {
        thumbKeys[id] = modified
        thumbQueue.async { [weak self] in
            guard let self else { return }
            let nb = notebook ?? (try? self.store.load(id: id))?.notebook
            guard let nb, let page = nb.pages.first,
                  let cg = PageRenderer.image(of: page, maxSide: 420, assets: AssetCache(assets: nb.assets)) else { return }
            let img = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            DispatchQueue.main.async { if self.thumbKeys[id] == modified { self.thumbnails[id] = img } }
        }
    }

    func create() {
        var nb = Notebook(title: draft.title, cover: draft.cover,
                          firstPage: Page(style: draft.style, paper: draft.paper, size: draft.size))
        nb.modified = Date()
        do {
            try store.save(nb)
            items.insert(nb.metadata, at: 0)
            makeThumbnail(id: nb.id, modified: nb.modified, notebook: nb)
            fileIntoSelectedFolder(nb.id)
            showingNew = false
            draft.reset()
            open(nb.id, nil)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    func duplicate(_ id: UUID) {
        guard let (original, password) = loadAsking(id) else { return }
        do {
            var nb = original
            nb.id = UUID()
            nb.title = Notebook.cleanTitle(nb.title + " copy")
            nb.created = Date()
            nb.modified = Date()
            try store.save(nb, password: password) // a copy of a locked notebook stays locked
            notebookSaved(nb, locked: password != nil)
            if let f = folders.folder(of: id) { move(nb.id, to: f) }
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    func delete(_ id: UUID) {
        guard let m = items.first(where: { $0.id == id }) else { return }
        let alert = NSAlert()
        alert.messageText = "Move “\(m.title)” to the Trash?"
        alert.informativeText = "You can restore it from the Trash in Finder."
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        willDelete(id)
        do {
            try store.trash(id: id)
            folders.move(id, to: nil)
            saveFolders()
            items.removeAll { $0.id == id }
            thumbnails[id] = nil
            if selection == id { selection = nil }
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    func exportPDF(_ id: UUID) {
        guard let (nb, _) = loadAsking(id) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = nb.title.replacingOccurrences(of: "/", with: "-") + ".pdf"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try PageRenderer.exportPDF(nb, to: url)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}

final class NewNotebookDraft: ObservableObject {
    static let covers: [RGBA] = [RGBA(0.20, 0.38, 0.85), RGBA(0.13, 0.55, 0.42), RGBA(0.85, 0.33, 0.28),
                                 RGBA(0.95, 0.65, 0.15), RGBA(0.50, 0.32, 0.78), RGBA(0.20, 0.22, 0.27)]
    @Published var title = ""
    @Published var style = PageStyle.ruled
    @Published var paper = PaperColor.white
    @Published var size = PageSize.a4
    @Published var cover = covers[0]

    func reset() {
        title = ""
        cover = Self.covers.randomElement() ?? Self.covers[0]
    }
}

// MARK: - Views

struct LibraryView: View {
    @ObservedObject var model: LibraryModel
    @FocusState private var searchFocused: Bool

    var body: some View {
        HStack(spacing: 0) {
            folderSidebar
            Divider()
            mainColumn
        }
    }

    private var folderSidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            folderRow(nil, name: "All Notebooks", symbol: "books.vertical", count: model.items.count)
            HStack {
                Text("Folders").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Button { model.newFolder() } label: { Image(systemName: "plus") }
                    .buttonStyle(.plain).help("New Folder")
            }
            .padding(.horizontal, 10).padding(.top, 16).padding(.bottom, 4)
            ForEach(model.folders.folders) { f in
                folderRow(f.id, name: f.name, symbol: "folder", count: f.notebooks.count)
                    .contextMenu {
                        Button("Rename…") { model.renameFolder(f.id) }
                        Button("Delete Folder…", role: .destructive) { model.deleteFolder(f.id) }
                    }
            }
            if model.folders.folders.isEmpty {
                Text("Group notebooks into folders with +, or right-click a notebook.")
                    .font(.caption).foregroundStyle(.tertiary).padding(.horizontal, 10)
            }
            Spacer()
        }
        .padding(.vertical, 14).padding(.horizontal, 8)
        .frame(width: 200)
        .background(Color(nsColor: .underPageBackgroundColor).opacity(0.5))
    }

    private func folderRow(_ id: UUID?, name: String, symbol: String, count: Int) -> some View {
        let selected = model.selectedFolder == id
        return Button { withAnimation(Motion.reduced ? nil : .easeInOut(duration: 0.15)) { model.selectedFolder = id } } label: {
            HStack(spacing: 8) {
                Image(systemName: symbol).frame(width: 18).foregroundStyle(selected ? Color.accentColor : .secondary)
                Text(name).lineLimit(1)
                Spacer()
                Text("\(count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Color.accentColor.opacity(0.15) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var mainColumn: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if model.items.isEmpty {
                emptyState
            } else {
                ScrollView {
                    let q = model.query.trimmingCharacters(in: .whitespaces)
                    let notebooks = model.filtered
                    let hits = model.contentHits
                    if !q.isEmpty && notebooks.isEmpty && hits.isEmpty {
                        Text("Nothing matches “\(q)”.").foregroundStyle(.secondary).padding(.top, 60)
                    }
                    if !notebooks.isEmpty {
                        if !q.isEmpty { sectionTitle("Notebooks") }
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 168, maximum: 210), spacing: 26)], spacing: 30) {
                            ForEach(notebooks) { m in
                                NotebookCard(meta: m, thumbnail: model.thumbnails[m.id], selected: model.selection == m.id)
                                    .onTapGesture(count: 2) { model.open(m.id, nil) }
                                    .simultaneousGesture(TapGesture().onEnded { model.selection = m.id })
                                    .contextMenu {
                                        Button("Open") { model.open(m.id, nil) }
                                        Button("Duplicate") { model.duplicate(m.id) }
                                        Menu("Move to Folder") {
                                            Button("None") { model.move(m.id, to: nil) }
                                            if !model.folders.folders.isEmpty { Divider() }
                                            ForEach(model.folders.folders) { f in
                                                Button(f.name) { model.move(m.id, to: f.id) }
                                            }
                                            Divider()
                                            Button("New Folder…") { model.newFolder(); if let f = model.selectedFolder { model.move(m.id, to: f) } }
                                        }
                                        Button("Export as PDF…") { model.exportPDF(m.id) }
                                        Divider()
                                        Button("Move to Trash", role: .destructive) { model.delete(m.id) }
                                    }
                            }
                        }
                        .padding(.horizontal, 28).padding(.vertical, q.isEmpty ? 28 : 12)
                    }
                    if !hits.isEmpty {
                        sectionTitle("In your notes · \(hits.count) match\(hits.count == 1 ? "" : "es")")
                        LazyVStack(spacing: 2) {
                            ForEach(hits) { hit in
                                Button { model.open(hit.notebook.id, hit.page) } label: { hitRow(hit) }
                                    .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 20).padding(.bottom, 24)
                    }
                    if !model.problems.isEmpty {
                        Label("\(model.problems.count) file(s) in the library folder couldn’t be read.", systemImage: "exclamationmark.triangle")
                            .font(.callout).foregroundStyle(.secondary)
                            .help(model.problems.joined(separator: "\n"))
                            .padding(.bottom, 20)
                    }
                }
            }
        }
        .frame(minWidth: 560, minHeight: 420)
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $model.showingNew) { NewNotebookSheet(model: model, draft: model.draft) }
        .overlay(alignment: .bottom) {
            if let msg = model.importing {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(msg).font(.callout.weight(.medium))
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(.regularMaterial, in: Capsule())
                .padding(.bottom, 22)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(Motion.reduced ? nil : .spring(response: 0.3, dampingFraction: 0.85), value: model.importing)
        .animation(Motion.reduced ? nil : .easeInOut(duration: 0.2), value: model.query)
        .animation(Motion.reduced ? nil : .spring(response: 0.35, dampingFraction: 0.85), value: model.items.map(\.id))
        .onChange(of: model.searchFocusRequest) { searchFocused = true }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            // Dropped PDFs become notebooks.
            var urls: [URL] = []
            let group = DispatchGroup()
            for p in providers {
                group.enter()
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    if let url { DispatchQueue.main.async { urls.append(url) } }
                    group.leave()
                }
            }
            group.notify(queue: .main) { DispatchQueue.main.async { if !urls.isEmpty { model.importFiles(urls) } } }
            return true
        }
    }

    private func sectionTitle(_ s: String) -> some View {
        Text(s).font(.headline).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 28).padding(.top, 18).padding(.bottom, 4)
    }

    private func hitRow(_ hit: LibraryModel.SearchHit) -> some View {
        HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: 2).fill(Color(nsColor: hit.notebook.cover.nsColor)).frame(width: 4, height: 36)
            VStack(alignment: .leading, spacing: 3) {
                Text("\(hit.notebook.title) · page \(hit.page + 1)").font(.callout.weight(.semibold))
                Text(hit.snippet).font(.callout).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            Image(systemName: "arrow.right.circle").foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
        .contentShape(Rectangle())
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text(model.selectedFolder.flatMap { id in model.folders.folders.first { $0.id == id }?.name } ?? "Notebooks")
                .font(.system(size: 22, weight: .semibold)).lineLimit(1)
            Spacer()
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search titles, text and handwriting", text: $model.query)
                    .textFieldStyle(.plain).frame(width: 230)
                    .focused($searchFocused)
                if !model.query.isEmpty {
                    Button { model.query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
            Button { model.importPDFs() } label: { Label("Import…", systemImage: "doc.badge.arrow.up") }
                .controlSize(.large)
                .help("Import a PDF to write on, or a GoodNotes notebook (.goodnotes). You can also drop files here.")
            Button { model.showingNew = true } label: { Label("New Notebook", systemImage: "plus") }
                .keyboardShortcut("n", modifiers: .command)
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 28).padding(.vertical, 16)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "book.closed").font(.system(size: 54, weight: .light)).foregroundStyle(.secondary)
            Text("No notebooks yet").font(.title2.weight(.semibold))
            Text("Create one and start writing with your pen, or drop a PDF or GoodNotes notebook here.").foregroundStyle(.secondary)
            HStack {
                Button("Import…") { model.importPDFs() }.controlSize(.large)
                Button("Create Notebook") { model.showingNew = true }.controlSize(.large).buttonStyle(.borderedProminent)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

final class HoverModel: ObservableObject {
    @Published var on = false
}

struct NotebookCard: View {
    let meta: NotebookMetadata
    let thumbnail: NSImage?
    let selected: Bool
    @StateObject private var hover = HoverModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 8).fill(Color.white)
                if meta.locked == true {
                    // Locked: never show the contents.
                    RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: meta.cover.nsColor).opacity(0.18))
                    Image(systemName: "lock.fill").font(.system(size: 30, weight: .medium))
                        .foregroundStyle(Color(nsColor: meta.cover.nsColor)).frame(maxWidth: .infinity)
                } else if let t = thumbnail {
                    Image(nsImage: t).resizable().aspectRatio(contentMode: .fill)
                        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .top)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity)
                }
                // Cover-coloured spine.
                UnevenRoundedRectangle(topLeadingRadius: 8, bottomLeadingRadius: 8)
                    .fill(Color(nsColor: meta.cover.nsColor)).frame(width: 9)
            }
            .aspectRatio(0.72, contentMode: .fit)
            .shadow(color: .black.opacity(hover.on ? 0.28 : 0.18), radius: hover.on ? 10 : 5, y: hover.on ? 5 : 2)
            .scaleEffect(hover.on && !Motion.reduced ? 1.03 : 1)
            .animation(Motion.reduced ? nil : .spring(response: 0.28, dampingFraction: 0.75), value: hover.on)
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(selected ? Color.accentColor : .clear, lineWidth: 3).padding(-4))
            HStack(spacing: 4) {
                if meta.locked == true { Image(systemName: "lock.fill").font(.system(size: 10)).foregroundStyle(.secondary) }
                Text(meta.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
            }
            Text("\(meta.pageCount) page\(meta.pageCount == 1 ? "" : "s") · \(meta.modified.formatted(.relative(presentation: .named)))")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .contentShape(Rectangle())
        .onHover { hover.on = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(meta.title), \(meta.pageCount) pages\(meta.locked == true ? ", locked" : "")")
    }
}

struct NewNotebookSheet: View {
    @ObservedObject var model: LibraryModel
    @ObservedObject var draft: NewNotebookDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("New Notebook").font(.title2.weight(.semibold))
            TextField("Title", text: $draft.title).textFieldStyle(.roundedBorder).onSubmit { model.create() }
            VStack(alignment: .leading, spacing: 8) {
                Text("Template").font(.headline)
                HStack(spacing: 12) {
                    ForEach(PageStyle.allCases) { s in
                        Button { draft.style = s } label: {
                            VStack(spacing: 6) {
                                TemplatePreview(style: s, paper: draft.paper)
                                    .frame(width: 64, height: 86)
                                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(draft.style == s ? Color.accentColor : Color.primary.opacity(0.15), lineWidth: draft.style == s ? 2.5 : 1))
                                Text(s.title).font(.caption)
                            }
                        }.buttonStyle(.plain)
                    }
                }
            }
            HStack(spacing: 24) {
                Picker("Paper", selection: $draft.paper) { ForEach(PaperColor.allCases) { Text($0.title).tag($0) } }.frame(width: 170)
                Picker("Size", selection: $draft.size) { ForEach(PageSize.allCases) { Text($0.title).tag($0) } }.frame(width: 190)
            }
            HStack(spacing: 10) {
                Text("Cover").font(.headline)
                ForEach(Array(NewNotebookDraft.covers.enumerated()), id: \.offset) { _, c in
                    Button { draft.cover = c } label: {
                        Circle().fill(Color(nsColor: c.nsColor)).frame(width: 22, height: 22).padding(3)
                            .overlay(Circle().stroke(draft.cover == c ? Color.accentColor : .clear, lineWidth: 2))
                    }.buttonStyle(.plain)
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { model.showingNew = false }.keyboardShortcut(.cancelAction)
                Button("Create") { model.create() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 460)
    }
}

/// Small live preview of a page template, drawn with the real renderer.
struct TemplatePreview: View {
    let style: PageStyle
    let paper: PaperColor

    var body: some View {
        let page = Page(style: style, paper: paper, size: .a4)
        if let cg = PageRenderer.image(of: page, maxSide: 172) {
            Image(decorative: cg, scale: 2).resizable().clipShape(RoundedRectangle(cornerRadius: 5))
        } else {
            RoundedRectangle(cornerRadius: 5).fill(Color(nsColor: paper.rgba.nsColor))
        }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @ObservedObject var tools: ToolState
    var openPenLab: () -> Void = {}
    var location = "local"
    var setLocation: (String) -> Void = { _ in }

    var body: some View {
        Form {
            Section("Pen") {
                Picker("Pressure feel", selection: $tools.pressureFeel) {
                    ForEach(PressureFeel.allCases.filter { $0 != .personal || tools.personalCurve != nil }) { Text($0.title).tag($0) }
                }
                Text("Soft gives full thickness with a light touch; Firm needs you to press harder. Personal is measured from your hand in the Pen Lab.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Text("Smoothing")
                    Slider(value: $tools.smoothing, in: 0.8...4) { Text("Smoothing") } minimumValueLabel: { Text("Smoother").font(.caption) } maximumValueLabel: { Text("Sharper").font(.caption) }
                }
                Button("Open Pen Lab…") { openPenLab() }
                    .help("Measure your pen and hand, then apply a personal pressure curve")
                Toggle("Hold at the end of a stroke to snap it to a line or shape", isOn: $tools.holdToStraighten)
                Toggle("Scribble over ink to erase it", isOn: $tools.scribbleToErase)
                Toggle("Answer sums as I write (write = and pause)", isOn: $tools.autoSolve)
                Toggle("Highlighter snaps to the text in PDFs", isOn: $tools.snapHighlights)
                Toggle("Predict pen movement (lower latency)", isOn: $tools.prediction)
                Toggle("Only the pen draws (mouse and trackpad scroll instead of inking; they still select and type)", isOn: $tools.penOnly)
            }
            Section("Library") {
                Picker("Keep notebooks", selection: Binding(get: { location }, set: { setLocation($0) })) {
                    Text("On this Mac").tag("local")
                    Text("iCloud Drive").tag("iCloud")
                    Text("Google Drive").tag("googleDrive")
                    Text("Another folder… (Dropbox, OneDrive…)").tag("custom")
                }
                Text("Cloud locations keep each notebook as a file (for Google Drive: My Drive › Inkwell, via Google Drive for desktop). Edit a notebook on one computer at a time; the library refreshes when you switch back to Inkwell.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("XPPen Star G640 setup") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("In the XPPen driver (PenTablet settings):").font(.callout.weight(.semibold))
                    Text("• Lower pen button → Mouse Right Click: hold and draw to erase, click to switch between your last two tools.")
                    Text("• Upper pen button → Mouse Middle Click: hold and drag to move the page, click to undo.")
                    Text("• Mapping → map to one display and keep proportions, so circles stay round.")
                    Text("Also: Space + drag pans, ⌘ + scroll or pinch zooms, P/H/E/L/T/K switch tools, ⌘-click opens links.")
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }
}
