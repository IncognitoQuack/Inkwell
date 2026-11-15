import AppKit
import Combine

extension Notification.Name {
    /// Posted on the main thread after a notebook is saved. userInfo: "notebook" (Notebook).
    static let inkwellNotebookSaved = Notification.Name("inkwellNotebookSaved")
}

/// One open notebook: the single source of truth for its edits, undo history and autosave.
///
/// Undo works on snapshots: every action records the affected page (or the page list) as it was
/// before. Pages are value types with copy-on-write storage, so a snapshot shares all unchanged
/// stroke data and costs little; it makes every kind of edit undoable with one mechanism.
final class NotebookSession: ObservableObject {
    let store: LibraryStore
    let undoManager = UndoManager()
    let assets: AssetCache

    @Published private(set) var notebook: Notebook
    @Published var currentPageIndex = 0
    @Published private(set) var saveError: String?
    @Published private(set) var isDirty = false
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    /// Set when the notebook is password-protected; used to encrypt every save. Never written to disk.
    @Published private(set) var password: String?
    /// Bumped on every page edit; the sidebar uses it to refresh thumbnails.
    @Published private(set) var pageVersions: [UUID: Int] = [:]

    /// Called with a page id whose content changed, and the area that needs redrawing (nil = whole page).
    var pageContentChanged: ((UUID, CGRect?) -> Void)?
    /// Called when pages were added, removed, reordered or restyled.
    var pagesChanged: (() -> Void)?

    private var autosave: DispatchWorkItem?
    private let saveQueue = DispatchQueue(label: "inkwell.session.save", qos: .utility)
    private var saveGeneration = 0

    init(notebook: Notebook, store: LibraryStore, password: String? = nil) {
        self.password = password
        var nb = notebook
        nb.pruneAssets() // safe here: there is no undo history yet that could need an orphan back
        self.notebook = nb
        self.store = store
        assets = AssetCache(assets: nb.assets)
        undoManager.levelsOfUndo = 200
        // Explicit groups: exactly one undo step per user action, however events are batched.
        undoManager.groupsByEvent = false
        // Publish only real changes: the undo manager posts notifications every run-loop pass, and
        // republishing on each one would keep SwiftUI updating forever.
        observers = [Notification.Name.NSUndoManagerDidCloseUndoGroup, .NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange].map { name in
            NotificationCenter.default.addObserver(forName: name, object: undoManager, queue: .main) { [weak self] _ in
                self?.refreshUndoState()
            }
        }
    }

    private var observers: [NSObjectProtocol] = []

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    var currentPage: Page? { notebook.pages.indices.contains(currentPageIndex) ? notebook.pages[currentPageIndex] : nil }

    func pageIndex(_ id: UUID) -> Int? { notebook.pages.firstIndex { $0.id == id } }

    func page(_ id: UUID) -> Page? { pageIndex(id).map { notebook.pages[$0] } }

    // MARK: Core edit primitives

    /// Edits one page as a single undoable action. `area` limits the redraw when known.
    func editPage(_ id: UUID, _ name: String, area: CGRect? = nil, _ mutate: (inout Page) -> Void) {
        guard let i = pageIndex(id) else { return }
        let before = notebook.pages[i]
        mutate(&notebook.pages[i])
        guard notebook.pages[i] != before else { return }
        registerUndo(name) { $0.restorePage(before, name: name) }
        pageChanged(id, area: area)
    }

    private func restorePage(_ snapshot: Page, name: String) {
        guard let i = pageIndex(snapshot.id) else { return }
        let current = notebook.pages[i]
        notebook.pages[i] = snapshot
        registerUndo(name) { $0.restorePage(current, name: name) }
        let structural = current.pageSize != snapshot.pageSize || current.style != snapshot.style
            || current.paper != snapshot.paper || current.bookmark != snapshot.bookmark
        if structural { structureChanged() }
        pageChanged(snapshot.id, area: nil)
    }

    /// Changes a page without recording undo; pair with `commitLiveEdit` (used while erasing, so a
    /// whole rub is one undo step yet every sample shows immediately).
    func liveEdit(_ id: UUID, area: CGRect?, _ mutate: (inout Page) -> Void) {
        guard let i = pageIndex(id) else { return }
        mutate(&notebook.pages[i])
        pageContentChanged?(id, area)
    }

    func commitLiveEdit(_ id: UUID, original: Page, name: String) {
        guard let i = pageIndex(id), notebook.pages[i] != original else { return }
        registerUndo(name) { $0.restorePage(original, name: name) }
        pageChanged(id, area: nil)
    }

    /// Edits the page list (add/remove/reorder) as one undoable action.
    func editPages(_ name: String, _ mutate: (inout [Page]) -> Void) {
        let before = notebook.pages
        mutate(&notebook.pages)
        if notebook.pages.isEmpty { notebook.pages = before } // never leave a notebook with no pages
        guard notebook.pages != before else { return }
        registerUndo(name) { $0.restorePages(before, name: name) }
        currentPageIndex = min(currentPageIndex, notebook.pages.count - 1)
        structureChanged()
    }

    private func restorePages(_ snapshot: [Page], name: String) {
        let current = notebook.pages
        notebook.pages = snapshot
        registerUndo(name) { $0.restorePages(current, name: name) }
        currentPageIndex = min(currentPageIndex, notebook.pages.count - 1)
        structureChanged()
    }

    /// Stores an embedded file and returns its id. Assets are never deleted while the notebook is open
    /// (undo may need them); unreferenced ones are dropped the next time it is opened.
    func addAsset(_ data: Data) -> UUID {
        let id = UUID()
        notebook.assets[id] = data
        assets.update(notebook.assets)
        markDirty()
        return id
    }

    // MARK: Convenience edits

    func addStrokes(_ strokes: [Stroke], to pageID: UUID, actionName: String = "Ink") {
        guard !strokes.isEmpty else { return }
        editPage(pageID, actionName, area: union(strokes.map(\.bounds))) { $0.strokes.append(contentsOf: strokes) }
    }

    func removeStrokes(_ ids: Set<UUID>, from pageID: UUID, actionName: String = "Erase") {
        guard !ids.isEmpty, let p = page(pageID) else { return }
        let area = union(p.strokes.filter { ids.contains($0.id) }.map(\.bounds))
        editPage(pageID, actionName, area: area) { $0.strokes.removeAll { ids.contains($0.id) } }
    }

    /// Moves strokes and elements together (a lasso selection can hold both).
    func moveItems(strokes: Set<UUID>, elements: Set<UUID>, on pageID: UUID, dx: CGFloat, dy: CGFloat) {
        guard dx.isFinite, dy.isFinite, dx != 0 || dy != 0 else { return }
        editPage(pageID, "Move") { p in
            p.strokes = p.strokes.map { strokes.contains($0.id) ? $0.translated(dx: dx, dy: dy) : $0 }
            for i in p.elements.indices where elements.contains(p.elements[i].id) {
                p.elements[i].frame = PageElement.sanitize(p.elements[i].frame.offsetBy(dx: dx, dy: dy))
            }
        }
    }

    func deleteItems(strokes: Set<UUID>, elements: Set<UUID>, on pageID: UUID) {
        editPage(pageID, "Delete") { p in
            p.strokes.removeAll { strokes.contains($0.id) }
            p.elements.removeAll { elements.contains($0.id) }
        }
    }

    func recolorStrokes(_ ids: Set<UUID>, on pageID: UUID, to color: RGBA) {
        editPage(pageID, "Change Color") { p in
            for i in p.strokes.indices where ids.contains(p.strokes[i].id) {
                // Keep each stroke's own transparency so a recoloured highlighter stays see-through.
                p.strokes[i].color = RGBA(color.r, color.g, color.b, p.strokes[i].color.a)
            }
        }
    }

    func upsertElement(_ e: PageElement, on pageID: UUID, actionName: String) {
        editPage(pageID, actionName) { p in
            if let i = p.elements.firstIndex(where: { $0.id == e.id }) { p.elements[i] = e } else { p.elements.append(e) }
        }
    }

    // MARK: Page edits

    @discardableResult
    func insertPage(_ page: Page, at index: Int) -> Int {
        let i = index.clamped(0, notebook.pages.count)
        editPages("Add Page") { $0.insert(page, at: i) }
        return i
    }

    /// Adds a page after the current one, styled like it (an imported PDF page continues as blank paper).
    @discardableResult
    func addPageAfterCurrent() -> Int {
        var p = (currentPage ?? Page()).emptyCopy()
        if p.background != nil { p.background = nil; p.style = .blank }
        return insertPage(p, at: currentPageIndex + 1)
    }

    func duplicatePage(id: UUID) {
        guard let i = pageIndex(id), notebook.pages.count < Notebook.maxPages else { return }
        var copy = notebook.pages[i]
        copy.id = UUID()
        copy.strokes = copy.strokes.compactMap { Stroke(kind: $0.kind, color: $0.color, width: $0.width, points: $0.points) }
        copy.elements = copy.elements.map { var e = $0; e.id = UUID(); return e }
        editPages("Duplicate Page") { $0.insert(copy, at: i + 1) }
    }

    func movePage(id: UUID, by offset: Int) {
        guard let i = pageIndex(id) else { return }
        let j = (i + offset).clamped(0, notebook.pages.count - 1)
        guard i != j else { return }
        editPages("Move Page") { $0.swapAt(i, j) }
        currentPageIndex = j
    }

    func deletePage(id: UUID) {
        guard notebook.pages.count > 1 else { return }
        editPages("Delete Page") { $0.removeAll { $0.id == id } }
    }

    func setStyle(_ style: PageStyle?, paper: PaperColor?, forPages ids: [UUID]) {
        let set = Set(ids)
        editPages("Change Template") { pages in
            for i in pages.indices where set.contains(pages[i].id) {
                if let style { pages[i].style = style }
                if let paper { pages[i].paper = paper }
            }
        }
    }

    func toggleBookmark(id: UUID) {
        editPages("Bookmark") { pages in
            if let i = pages.firstIndex(where: { $0.id == id }) { pages[i].bookmark = pages[i].bookmark == nil ? "" : nil }
        }
    }

    func rename(_ title: String) {
        let clean = Notebook.cleanTitle(title)
        guard clean != notebook.title else { return }
        let old = notebook.title
        notebook.title = clean
        registerUndo("Rename") { $0.rename(old) }
        markDirty()
    }

    /// Locks (or with nil, unlocks) the notebook; takes effect on the next save, which happens now.
    func setPassword(_ pw: String?) {
        if let old = password, pw != old { NotebookCrypto.forget(old) }
        password = (pw?.isEmpty ?? true) ? nil : pw
        markDirty(touch: false)
        saveNow()
    }

    // MARK: Audio and study (bookkeeping, not undoable edits)

    func addRecording(_ r: Recording) {
        notebook.recordings.append(r)
        markDirty()
    }

    func removeRecording(_ id: UUID) {
        notebook.recordings.removeAll { $0.id == id }
        markDirty()
    }

    func setTranscript(_ text: String, for id: UUID) {
        guard let i = notebook.recordings.firstIndex(where: { $0.id == id }) else { return }
        notebook.recordings[i].transcript = text.isEmpty ? nil : String(text.prefix(100_000))
        markDirty(touch: false)
    }

    /// Records a flash-card answer on a tape.
    func setReview(_ review: Review, forTape id: UUID, on pageID: UUID) {
        guard let pi = pageIndex(pageID), let ei = notebook.pages[pi].elements.firstIndex(where: { $0.id == id }),
              case .tape(let color, _) = notebook.pages[pi].elements[ei].content else { return }
        notebook.pages[pi].elements[ei].content = .tape(color, review)
        markDirty(touch: false)
    }

    /// Stores recognised handwriting for search. Not an edit the user made, so no undo entry.
    func setRecognizedText(_ text: String, signature: String, for pageID: UUID) {
        guard let i = pageIndex(pageID), notebook.pages[i].inkSignature == signature else { return }
        notebook.pages[i].recognizedText = text.isEmpty ? nil : text
        notebook.pages[i].indexSignature = signature
        markDirty(touch: false) // background bookkeeping isn't an edit: keep the library order stable
    }

    // MARK: Bookkeeping

    private func registerUndo(_ name: String, _ handler: @escaping (NotebookSession) -> Void) {
        let open = undoManager.groupingLevel == 0
        if open { undoManager.beginUndoGrouping() }
        undoManager.registerUndo(withTarget: self, handler: handler)
        undoManager.setActionName(name)
        if open { undoManager.endUndoGrouping() }
    }

    private func refreshUndoState() {
        if canUndo != undoManager.canUndo { canUndo = undoManager.canUndo }
        if canRedo != undoManager.canRedo { canRedo = undoManager.canRedo }
    }

    private func union(_ rects: [CGRect]) -> CGRect? {
        let u = rects.reduce(CGRect.null) { $0.union($1) }
        return u.isNull ? nil : u
    }

    private func pageChanged(_ id: UUID, area: CGRect?) {
        pageVersions[id, default: 0] += 1
        pageContentChanged?(id, area)
        markDirty()
    }

    private func structureChanged() {
        for p in notebook.pages { pageVersions[p.id, default: 0] += 1 }
        pagesChanged?()
        markDirty()
    }

    /// Cancels autosave and drops unsaved state (used when the notebook is being deleted).
    func discardPendingSaves() {
        autosave?.cancel()
        saveQueue.sync {}
        saveGeneration += 1
        isDirty = false
    }

    private func markDirty(touch: Bool = true) {
        if touch { notebook.modified = Date() }
        isDirty = true
        // The undo group closes at the end of this event; read availability right after it.
        DispatchQueue.main.async { [weak self] in self?.refreshUndoState() }
        autosave?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        autosave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    /// Writes in the background. A newer edit supersedes an in-flight save; errors are kept and shown,
    /// and the next edit or flush retries. Nothing in memory is ever discarded on failure.
    func saveNow() {
        autosave?.cancel()
        guard isDirty else { return }
        saveGeneration += 1
        let gen = saveGeneration
        let snapshot = notebook
        let pw = password
        saveQueue.async { [weak self] in
            guard let self else { return }
            do {
                try self.store.save(snapshot, password: pw)
                DispatchQueue.main.async {
                    if gen == self.saveGeneration { self.isDirty = false }
                    self.saveError = nil
                    NotificationCenter.default.post(name: .inkwellNotebookSaved, object: self, userInfo: ["notebook": snapshot, "locked": pw != nil])
                }
            } catch {
                DispatchQueue.main.async { self.saveError = error.localizedDescription }
            }
        }
    }

    /// Blocks until everything is on disk (window close, quit). Returns the error if the save failed.
    @discardableResult
    func flush() -> Error? {
        autosave?.cancel()
        saveQueue.sync {} // let any in-flight save finish first
        guard isDirty else { return nil }
        do {
            try store.save(notebook, password: password)
            isDirty = false
            saveError = nil
            NotificationCenter.default.post(name: .inkwellNotebookSaved, object: self, userInfo: ["notebook": notebook, "locked": password != nil])
            return nil
        } catch {
            saveError = error.localizedDescription
            return error
        }
    }
}
