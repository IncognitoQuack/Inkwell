import AppKit
import PDFKit
import SwiftUI

@main
enum Main {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { app.run() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private(set) var store: LibraryStore!
    /// Self-tests use their own preferences so they never change the user's tools, colours or pen settings.
    let tools = CommandLine.arguments.contains("--screenshot")
        ? ToolState(defaults: UserDefaults(suiteName: "local.inkwell.selftest") ?? .standard)
        : ToolState()
    private var library: LibraryModel!
    private var libraryWindow: NSWindow!
    private var settingsWindow: NSWindow?
    private var penLab: PenLabWindowController?
    private var help: HelpWindowController?
    private var notebooks: [UUID: NotebookWindowController] = [:]

    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = CommandLine.arguments
        let folder = args.firstIndex(of: "--library").flatMap { args.indices.contains($0 + 1) ? URL(fileURLWithPath: args[$0 + 1]) : nil }
            ?? Self.configuredLibraryFolder()
        do {
            store = try LibraryStore(folder: folder)
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = "Inkwell can’t open its library folder."
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        library = LibraryModel(store: store)
        library.open = { [weak self] id, page in self?.openNotebook(id, page: page) }
        library.willDelete = { [weak self] id in
            // Stop any pending autosave first, or it could write the file back after it went to the Trash.
            self?.notebooks[id]?.session.discardPendingSaves()
            self?.notebooks[id]?.close()
        }

        buildMenus()
        libraryWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 640),
                                 styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        libraryWindow.title = "Inkwell"
        libraryWindow.isReleasedWhenClosed = false
        libraryWindow.contentView = NSHostingView(rootView: LibraryView(model: library))
        libraryWindow.setFrameAutosaveName("Library")
        if libraryWindow.frame.origin == .zero { libraryWindow.center() }
        libraryWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        if !pendingOpen.isEmpty { let u = pendingOpen; pendingOpen = []; importOrOpen(u) }
        if let i = args.firstIndex(of: "--screenshot"), args.indices.contains(i + 1) {
            runScreenshot(to: args[i + 1])
        } else if !UserDefaults.standard.bool(forKey: "shownHelp") {
            // First launch: show the gestures once.
            UserDefaults.standard.set(true, forKey: "shownHelp")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self.showHelp() }
        }
    }

    /// PDFs and .inkwell files opened from Finder, the Dock, or "Open With".
    private var pendingOpen: [URL] = []

    func application(_ application: NSApplication, open urls: [URL]) {
        guard library != nil else { pendingOpen += urls; return } // launched with files: handled after setup
        importOrOpen(urls)
    }

    private func importOrOpen(_ urls: [URL]) {
        // A notebook already in the library just opens; everything else is imported.
        var rest: [URL] = []
        for u in urls {
            if u.pathExtension.lowercased() == LibraryStore.fileExtension,
               u.deletingLastPathComponent().standardizedFileURL == store.folder.standardizedFileURL,
               let id = UUID(uuidString: u.deletingPathExtension().lastPathComponent) {
                openNotebook(id)
            } else {
                rest.append(u)
            }
        }
        if !rest.isEmpty { showLibrary(); library.importFiles(rest) }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showLibrary() }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        for c in notebooks.values { c.canvas.endTextEditing() } // never lose text that's still being typed
        let failed = notebooks.values.compactMap { c in c.session.flush().map { (c.session.notebook.title, $0) } }
        guard !failed.isEmpty else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Some notebooks couldn’t be saved."
        alert.informativeText = failed.map { "• \($0.0): \($0.1.localizedDescription)" }.joined(separator: "\n")
            + "\n\nIf you quit now, their latest changes will be lost."
        alert.addButton(withTitle: "Don’t Quit")
        alert.addButton(withTitle: "Quit Anyway")
        alert.buttons[1].hasDestructiveAction = true
        return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }

    func applicationWillResignActive(_ notification: Notification) {
        for c in notebooks.values { c.session.saveNow() }
    }

    /// Pick up notebooks changed elsewhere (e.g. synced through iCloud Drive from another Mac).
    func applicationDidBecomeActive(_ notification: Notification) {
        library?.reload()
    }

    // MARK: Library location

    enum LibraryLocation: String { case local, iCloud, googleDrive, custom }

    static var libraryLocation: LibraryLocation {
        LibraryLocation(rawValue: UserDefaults.standard.string(forKey: "libraryLocation") ?? "") ?? .local
    }

    static func folder(for loc: LibraryLocation) -> URL? {
        switch loc {
        case .local: return LibraryStore.defaultFolder()
        case .iCloud: return LibraryStore.iCloudFolder()
        case .googleDrive: return LibraryStore.googleDriveFolder()
        case .custom: return UserDefaults.standard.string(forKey: "libraryCustomPath").map { URL(fileURLWithPath: $0, isDirectory: true) }
        }
    }

    /// Falls back to this Mac when the chosen service isn't available (e.g. Google Drive signed out).
    static func configuredLibraryFolder() -> URL {
        folder(for: libraryLocation) ?? LibraryStore.defaultFolder()
    }

    private static func name(_ loc: LibraryLocation) -> String {
        switch loc {
        case .local: return "this Mac"
        case .iCloud: return "iCloud Drive"
        case .googleDrive: return "Google Drive"
        case .custom: return "the chosen folder"
        }
    }

    /// Moves the library to another location (this Mac, iCloud Drive, Google Drive or any folder),
    /// then reopens Inkwell there.
    func changeLibraryLocation(to loc: LibraryLocation) {
        if loc == .custom {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.prompt = "Use This Folder"
            panel.message = "Choose a folder for your notebooks (for example inside Dropbox or OneDrive)."
            guard panel.runModal() == .OK, let url = panel.url else { return }
            UserDefaults.standard.set(url.appendingPathComponent("Inkwell", isDirectory: true).path, forKey: "libraryCustomPath")
        } else if loc == Self.libraryLocation {
            return
        }
        guard let dest = Self.folder(for: loc) else {
            let a = NSAlert()
            switch loc {
            case .iCloud:
                a.messageText = "iCloud Drive is off on this Mac."
                a.informativeText = "Turn on iCloud Drive in System Settings › Apple Account › iCloud, then try again."
            case .googleDrive:
                a.messageText = "Google Drive isn’t set up on this Mac."
                a.informativeText = "Install “Google Drive for desktop” from google.com/drive/download and sign in. Your Drive then appears in Finder, and Inkwell can keep your notebooks in My Drive › Inkwell."
                a.addButton(withTitle: "Get Google Drive")
                a.addButton(withTitle: "Cancel")
                if a.runModal() == .alertFirstButtonReturn, let u = URL(string: "https://www.google.com/drive/download/") { NSWorkspace.shared.open(u) }
                return
            default:
                a.messageText = "That location isn’t available."
            }
            a.runModal()
            return
        }
        let src = Self.configuredLibraryFolder()
        guard src.standardizedFileURL != dest.standardizedFileURL else { return }
        let alert = NSAlert()
        alert.messageText = "Move your notebooks to \(Self.name(loc))?"
        alert.informativeText = (loc == .local ? "They’ll be moved into this Mac’s library."
            : "They’ll be kept in \(dest.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")) and sync to your other computers through \(Self.name(loc)). Edit a notebook on one computer at a time.")
            + " Inkwell will reopen."
        alert.addButton(withTitle: "Move and Reopen")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        // Everything open must be on disk before files move.
        for c in notebooks.values {
            c.canvas.endTextEditing()
            if let err = c.session.flush() { NSAlert(error: err).runModal(); return }
        }
        let report = LibraryStore.moveLibrary(from: src, to: dest)
        if !report.failed.isEmpty {
            let a = NSAlert()
            a.messageText = "Some notebooks couldn’t be moved."
            a.informativeText = report.failed.joined(separator: "\n") + "\n\nThey’re still in their old location."
            a.runModal()
        }
        UserDefaults.standard.set(loc.rawValue, forKey: "libraryLocation")
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: cfg) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    // MARK: Windows

    @objc func showLibrary() {
        libraryWindow.makeKeyAndOrderFront(nil)
    }

    func openNotebook(_ id: UUID, page: Int? = nil) {
        if let existing = notebooks[id] {
            existing.window?.makeKeyAndOrderFront(nil)
            if let page { existing.canvas.scrollToPage(page) }
            return
        }
        defer {
            if let page, let c = notebooks[id] {
                // After the first layout and fit-to-width, which would otherwise scroll back to the top.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { c.canvas.scrollToPage(page) }
            }
        }
        do {
            var password: String?
            var loaded: LibraryStore.Loaded
            var prompt = "Enter the password for this notebook."
            while true {
                do {
                    loaded = try store.load(id: id, password: password)
                    break
                } catch NotebookCodec.CodecError.locked {
                    guard let pw = PasswordPrompt.ask(title: "This notebook is locked", message: prompt) else { return }
                    password = pw
                } catch NotebookCrypto.CryptoError.wrongPassword {
                    prompt = "That password isn’t right. Try again."
                    guard let pw = PasswordPrompt.ask(title: "This notebook is locked", message: prompt) else { return }
                    password = pw
                }
            }
            let session = NotebookSession(notebook: loaded.notebook, store: store, password: password)
            let controller = NotebookWindowController(session: session, tools: tools)
            controller.onClose = { [weak self] c in self?.notebooks[c.session.notebook.id] = nil }
            notebooks[id] = controller
            controller.showWindow(nil)
            if loaded.recoveredFromBackup {
                let alert = NSAlert()
                alert.messageText = "This notebook was restored from its backup."
                alert.informativeText = "The latest save was damaged, so Inkwell opened the previous good version. It will be saved normally from now on."
                alert.beginSheetModal(for: controller.window!)
                session.saveNow()
            }
        } catch {
            FileHandle.standardError.write("open failed: \(error)\n".data(using: .utf8)!)
            let alert = NSAlert()
            alert.messageText = "This notebook can’t be opened."
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    func notebookController(_ id: UUID) -> NotebookWindowController? { notebooks[id] }

    private var frontNotebook: NotebookWindowController? {
        (NSApp.keyWindow?.windowController as? NotebookWindowController)
            ?? (NSApp.mainWindow?.windowController as? NotebookWindowController)
    }

    @objc func showSettings() {
        if settingsWindow == nil {
            let w = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "Inkwell Settings"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: SettingsView(tools: tools, openPenLab: { [weak self] in self?.showPenLab() },
                                                                 location: Self.libraryLocation.rawValue,
                                                                 setLocation: { [weak self] l in self?.changeLibraryLocation(to: LibraryLocation(rawValue: l) ?? .local) }))
            w.center()
            settingsWindow = w
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    // MARK: Menu actions

    @objc func newNotebook() { showLibrary(); library.showingNew = true }
    @objc func exportPDF() { frontNotebook?.exportPDF(currentPageOnly: false) }
    @objc func exportPagePDF() { frontNotebook?.exportPDF(currentPageOnly: true) }
    @objc func exportPagePNG() { frontNotebook?.exportPagePNG() }
    @objc func importPDF() { showLibrary(); library.importPDFs() }
    @objc func insertImage() { frontNotebook?.canvas.chooseImage() }
    @objc func addLink() { frontNotebook?.promptForLink() }
    @objc func removeLink() { frontNotebook?.canvas.removeLinks() }
    @objc func convertToText() { frontNotebook?.canvas.convertSelectionToText() }
    @objc func toggleSidebar() { frontNotebook?.toggleSidebar() }
    @objc func toggleZoomWindow() { frontNotebook?.canvas.toggleZoomWriter() }
    @objc func lockNotebook() { frontNotebook?.lockWithPassword() }
    @objc func toggleRuler() { frontNotebook?.canvas.toggleRuler() }
    @objc func showHelp() {
        if help == nil { help = HelpWindowController() }
        help?.showWindow(nil)
    }
    /// ⌘O / ⌘⌫ in the library act on the selected notebook.
    @objc func openSelectedNotebook() { if let id = library.selection { openNotebook(id) } }
    @objc func trashSelectedNotebook() { if let id = library.selection { library.delete(id) } }
    @objc func toggleRecording() { frontNotebook?.audio.toggleRecording() }
    @objc func studyDue() { frontNotebook?.openStudy(all: false) }
    @objc func studyAll() { frontNotebook?.openStudy(all: true) }
    @objc func revealTapes() { frontNotebook?.canvas.setAllTapes(revealed: true) }
    @objc func coverTapes() { frontNotebook?.canvas.setAllTapes(revealed: false) }
    @objc func solveSelection() { frontNotebook?.canvas.solveSelection() }
    @objc func playSelection() { frontNotebook?.canvas.playSelection() }
    @objc func removePassword() { frontNotebook?.removePassword() }
    var penLabWindow: NSWindow? { penLab?.window }
    var penLabController: PenLabWindowController? { penLab }

    @objc func showPenLab() {
        if penLab == nil { penLab = PenLabWindowController(tools: tools) }
        penLab?.showWindow(nil)
        penLab?.window?.makeKeyAndOrderFront(nil)
    }
    @objc func toggleBookmark() { frontNotebook?.toggleBookmark() }
    @objc func findInNotes() { showLibrary(); library.focusSearch() }
    @objc func renameNotebook() { frontNotebook?.rename() }
    @objc func addPage() { frontNotebook?.addPage() }
    @objc func deletePage() { frontNotebook?.deleteCurrentPage() }
    @objc func nextPage() { frontNotebook?.goToPage(offset: 1) }
    @objc func previousPage() { frontNotebook?.goToPage(offset: -1) }
    @objc func zoomIn() { frontNotebook?.canvas.zoom(by: 1.25) }
    @objc func zoomOut() { frontNotebook?.canvas.zoom(by: 0.8) }
    @objc func actualSize() { frontNotebook?.canvas.zoomToActualSize() }
    @objc func fitWidth() { frontNotebook?.canvas.zoomToFitWidth() }
    @objc func deleteSelection() { frontNotebook?.canvas.deleteSelection() }
    @objc func duplicateSelection() { frontNotebook?.canvas.duplicateSelection() }
    @objc func selectAllInk() { frontNotebook?.canvas.selectAllOnCurrentPage() }
    @objc func chooseTool(_ sender: NSMenuItem) { if let t = sender.representedObject as? String, let tool = Tool(rawValue: t) { tools.tool = tool } }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let nb = frontNotebook
        switch item.action {
        case #selector(exportPagePDF), #selector(exportPagePNG), #selector(insertImage), #selector(toggleSidebar), #selector(toggleBookmark):
            return nb != nil
        case #selector(openSelectedNotebook), #selector(trashSelectedNotebook):
            return NSApp.keyWindow === libraryWindow && library.selection != nil
        case #selector(toggleRuler):
            item.state = nb?.canvas.isRulerShown == true ? .on : .off
            return nb != nil
        case #selector(toggleRecording):
            item.title = nb?.audio.isRecording == true ? "Stop Recording" : "Start Recording"
            return nb != nil
        case #selector(studyDue), #selector(studyAll), #selector(revealTapes), #selector(coverTapes):
            return (nb?.canvas.tapeCount ?? 0) > 0
        case #selector(solveSelection):
            return nb?.canvas.state.selectionHasInk ?? false
        case #selector(playSelection):
            return nb?.canvas.state.selectionHasAudio ?? false
        case #selector(lockNotebook):
            item.title = nb?.session.password == nil ? "Lock with Password…" : "Change Password…"
            return nb != nil
        case #selector(removePassword):
            return nb?.session.password != nil
        case #selector(toggleZoomWindow):
            item.state = nb?.canvas.isZoomWriterOpen == true ? .on : .off
            return nb != nil
        case #selector(addLink):
            return nb?.canvas.hasSelection ?? false
        case #selector(removeLink):
            return nb?.canvas.hasSelection ?? false
        case #selector(convertToText):
            return nb?.canvas.state.selectionHasInk ?? false
        case #selector(exportPDF), #selector(renameNotebook), #selector(addPage), #selector(nextPage), #selector(previousPage),
             #selector(zoomIn), #selector(zoomOut), #selector(actualSize), #selector(fitWidth), #selector(selectAllInk):
            return nb != nil
        case #selector(deletePage):
            return (nb?.session.notebook.pages.count ?? 0) > 1
        case #selector(deleteSelection), #selector(duplicateSelection):
            return nb?.canvas.hasSelection ?? false
        case #selector(chooseTool(_:)):
            item.state = (item.representedObject as? String) == tools.tool.rawValue ? .on : .off
            return true
        default:
            return true
        }
    }

    private func buildMenus() {
        let main = NSMenu()
        func menu(_ title: String, _ items: [NSMenuItem]) {
            let m = NSMenu(title: title)
            items.forEach(m.addItem)
            let host = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            host.submenu = m
            main.addItem(host)
        }
        func item(_ title: String, _ action: Selector?, _ key: String = "", _ mods: NSEvent.ModifierFlags = .command, target: AnyObject? = nil) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.keyEquivalentModifierMask = mods
            i.target = target
            return i
        }
        let me = self as AnyObject

        menu("Inkwell", [
            item("About Inkwell", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            .separator(),
            item("Settings…", #selector(showSettings), ",", target: me),
            item("Pen Lab…", #selector(showPenLab), "p", [.command, .option], target: me),
            .separator(),
            item("Hide Inkwell", #selector(NSApplication.hide(_:)), "h"),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            .separator(),
            item("Quit Inkwell", #selector(NSApplication.terminate(_:)), "q"),
        ])
        menu("File", [
            item("New Notebook…", #selector(newNotebook), "n", target: me),
            item("Show Library", #selector(showLibrary), "l", [.command, .shift], target: me),
            item("Open Selected Notebook", #selector(openSelectedNotebook), "o", target: me),
            item("Move Selected Notebook to Trash", #selector(trashSelectedNotebook), String(UnicodeScalar(NSBackspaceCharacter)!), target: me),
            .separator(),
            item("Import PDF or GoodNotes…", #selector(importPDF), "o", [.command, .shift], target: me),
            item("Search All Notes…", #selector(findInNotes), "f", [.command, .shift], target: me),
            .separator(),
            item("Rename Notebook…", #selector(renameNotebook), "", target: me),
            item("Lock with Password…", #selector(lockNotebook), "", target: me),
            item("Remove Password", #selector(removePassword), "", target: me),
            item("Export Notebook as PDF…", #selector(exportPDF), "e", [.command, .shift], target: me),
            item("Export Page as PDF…", #selector(exportPagePDF), "", target: me),
            item("Export Page as PNG…", #selector(exportPagePNG), "", target: me),
            .separator(),
            item("Close", #selector(NSWindow.performClose(_:)), "w"),
        ])
        menu("Edit", [
            item("Undo", Selector(("undo:")), "z"),
            item("Redo", Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x"),
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            .separator(),
            item("Select All Ink on Page", #selector(selectAllInk), "a", [.command, .shift], target: me),
            item("Duplicate Selection", #selector(duplicateSelection), "d", target: me),
            item("Delete Selection", #selector(deleteSelection), "", target: me),
            .separator(),
            item("Convert Handwriting to Text", #selector(convertToText), "t", [.command, .shift], target: me),
            item("Add Link…", #selector(addLink), "k", target: me),
            item("Remove Link", #selector(removeLink), "k", [.command, .shift], target: me),
            item("Solve Handwritten Sum", #selector(solveSelection), "=", [.command, .shift], target: me),
            item("Play Audio from Selection", #selector(playSelection), "", target: me),
        ])
        menu("Study", [
            item("Study Due Cards", #selector(studyDue), "y", [.command, .shift], target: me),
            item("Study All Cards", #selector(studyAll), "", target: me),
            .separator(),
            item("Peel Back All Tape", #selector(revealTapes), "", target: me),
            item("Cover All Tape", #selector(coverTapes), "", target: me),
            .separator(),
            item("Start Recording", #selector(toggleRecording), "r", [.command, .option], target: me),
        ])
        menu("Insert", [
            item("Image or PDF…", #selector(insertImage), "i", [.command, .shift], target: me),
            item("New Page", #selector(addPage), "n", [.command, .shift], target: me),
        ])
        let toolItems = Tool.allCases.enumerated().map { i, t -> NSMenuItem in
            let it = item("\(t.title)  (\(t.shortcutKey.uppercased()))", #selector(chooseTool(_:)), "\(i + 1)", target: me)
            it.representedObject = t.rawValue
            return it
        }
        menu("Tools", toolItems)
        menu("Page", [
            item("Bookmark Page", #selector(toggleBookmark), "b", [.command, .shift], target: me),
            item("Delete Page", #selector(deletePage), "", target: me),
            .separator(),
            item("Next Page", #selector(nextPage), String(UnicodeScalar(NSDownArrowFunctionKey)!), [.command], target: me),
            item("Previous Page", #selector(previousPage), String(UnicodeScalar(NSUpArrowFunctionKey)!), [.command], target: me),
        ])
        menu("View", [
            item("Zoom In", #selector(zoomIn), "=", target: me),
            item("Zoom Out", #selector(zoomOut), "-", target: me),
            item("Actual Size", #selector(actualSize), "0", target: me),
            item("Fit Width", #selector(fitWidth), "9", target: me),
            .separator(),
            item("Show/Hide Pages", #selector(toggleSidebar), "s", [.command, .option], target: me),
            item("Zoom Window", #selector(toggleZoomWindow), "z", [.command, .option], target: me),
            item("Ruler", #selector(toggleRuler), "r", target: me),
            .separator(),
            item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]),
        ])
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"))
        windowMenu.addItem(item("Zoom", #selector(NSWindow.performZoom(_:))))
        let wHost = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
        wHost.submenu = windowMenu
        main.addItem(wHost)
        NSApp.windowsMenu = windowMenu
        let helpMenu = NSMenu(title: "Help")
        helpMenu.addItem(item("Gestures & Shortcuts", #selector(showHelp), "?", target: me))
        helpMenu.addItem(item("Pen Lab…", #selector(showPenLab), "", target: me))
        let hHost = NSMenuItem(title: "Help", action: nil, keyEquivalent: "")
        hHost.submenu = helpMenu
        main.addItem(hHost)
        NSApp.helpMenu = helpMenu
        NSApp.mainMenu = main
    }

    // MARK: Self-test screenshots

    /// `--screenshot <dir>`: creates a demo notebook, draws through the real input path, and saves
    /// window snapshots. Used for automated visual checks.
    private func runScreenshot(to dir: String) {
        let out = URL(fileURLWithPath: dir, isDirectory: true)
        PenLabModel.folderOverride = store.folder.appendingPathComponent("PenLab", isDirectory: true)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        func snap(_ w: NSWindow?, _ name: String) {
            guard let v = w?.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
            v.cacheDisplay(in: v.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent(name))
        }
        var nb = Notebook(title: "Lecture notes — Physics", firstPage: Page(style: .ruled))
        nb.pages.append(Page(style: .grid, paper: .cream))
        try? store.save(nb)
        library.reload()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            snap(self.libraryWindow, "1-library.png")
            self.openNotebook(nb.id)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                guard let c = self.notebooks[nb.id], let pv = c.canvas.pageViews.first, let win = c.window else {
                    FileHandle.standardError.write("ui-checks: notebook window didn't open\n".data(using: .utf8)!)
                    NSApp.terminate(nil); return
                }
                SyntheticPen.write(on: pv, in: win, canvas: c.canvas, tools: self.tools)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    snap(win, "2-notebook.png")
                    let failures = SyntheticPen.exercise(on: pv, in: win, canvas: c.canvas, tools: self.tools, session: c.session, store: self.store)
                    FileHandle.standardError.write("ui-checks: \(failures.isEmpty ? "all passed" : failures.joined(separator: "; "))\n".data(using: .utf8)!)
                    c.canvas.scrollToPage(0)
                    win.displayIfNeeded()
                    snap(win, "4-features.png")
                    c.close()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                        snap(self.libraryWindow, "3-library-after.png")
                        if ProcessInfo.processInfo.environment["INKWELL_PERF"] != nil { SyntheticPen.perfPDF(appDelegate: self) }
                        if let sample = ProcessInfo.processInfo.environment["GOODNOTES_SAMPLE"] {
                            // Real GoodNotes export → Inkwell notebook window, checked and snapshotted.
                            var gfails: [String] = []
                            do {
                                let r = try GoodNotesImporter.importNotebook(Data(contentsOf: URL(fileURLWithPath: sample)), fallbackTitle: "GoodNotes sample")
                                try self.store.save(r.notebook)
                                self.openNotebook(r.notebook.id)
                                if let c = self.notebookController(r.notebook.id), let w = c.window {
                                    if c.canvas.pageViews.count != r.notebook.pages.count { gfails.append("page views") }
                                    if c.session.notebook.pages.map(\.strokes.count) != r.notebook.pages.map(\.strokes.count) { gfails.append("strokes in session") }
                                    c.canvas.scrollToPage(1)
                                    RunLoop.current.run(until: Date().addingTimeInterval(0.8))
                                    w.displayIfNeeded()
                                    snap(w, "6-goodnotes.png")
                                    c.close()
                                } else { gfails.append("window") }
                            } catch { gfails.append("\(error)") }
                            FileHandle.standardError.write("goodnotes-checks: \(gfails.isEmpty ? "all passed" : gfails.joined(separator: "; "))\n".data(using: .utf8)!)
                        }
                        let lab = SyntheticPen.exercisePenLab(appDelegate: self)
                        FileHandle.standardError.write("penlab-checks: \(lab.isEmpty ? "all passed" : lab.joined(separator: "; "))\n".data(using: .utf8)!)
                        snap(self.penLabWindow, "5-penlab.png")
                        print("screenshots written to \(out.path)")
                        NSApp.terminate(nil)
                    }
                }
            }
        }
    }
}

/// Feeds synthetic tablet events through the canvas's real pointer handlers.
enum SyntheticPen {
    private static func ev(_ type: NSEvent.EventType, _ p: CGPoint, _ pressure: Float, _ t: TimeInterval, pv: PageView, window: NSWindow) -> NSEvent {
        let w = pv.convert(p, to: nil)
        return NSEvent.mouseEvent(with: type, location: w, modifierFlags: [], timestamp: t, windowNumber: window.windowNumber,
                                  context: nil, eventNumber: 0, clickCount: 1, pressure: pressure)!
    }

    /// Runs one gesture with the given button (left = tool, right = lower pen button, other = upper).
    private static func gesture(_ button: Int, on pv: PageView, in window: NSWindow, canvas: CanvasView, n: Int = 90,
                                _ f: (Double) -> (CGFloat, CGFloat, Float)) {
        let (down, drag, up): (NSEvent.EventType, NSEvent.EventType, NSEvent.EventType) =
            button == 0 ? (.leftMouseDown, .leftMouseDragged, .leftMouseUp)
            : button == 1 ? (.rightMouseDown, .rightMouseDragged, .rightMouseUp)
            : (.otherMouseDown, .otherMouseDragged, .otherMouseUp)
        var t = ProcessInfo.processInfo.systemUptime
        let (x0, y0, p0) = f(0)
        canvas.pointerDown(ev(down, CGPoint(x: x0, y: y0), p0, t, pv: pv, window: window), on: pv)
        for i in 1..<max(n, 2) {
            t += 0.004
            let (x, y, p) = f(Double(i) / Double(max(n, 2) - 1))
            canvas.pointerDragged(ev(drag, CGPoint(x: x, y: y), p, t, pv: pv, window: window))
        }
        let (x1, y1, p1) = f(1)
        canvas.pointerUp(ev(up, CGPoint(x: x1, y: y1), p1, t + 0.004, pv: pv, window: window))
    }

    /// Exercises erase, button gestures, lasso move, undo/redo and save/reload; returns failures.
    static func exercise(on pv: PageView, in window: NSWindow, canvas: CanvasView, tools: ToolState,
                         session: NotebookSession, store: LibraryStore) -> [String] {
        var fails: [String] = []
        func expect(_ c: Bool, _ m: String) { if !c { fails.append(m) } }
        func count() -> Int { session.notebook.pages[0].strokes.count }
        let start = count()
        expect(start == 4, "expected 4 strokes after writing, got \(start)")

        // Lower button held + dragged across the wave erases it, as one undo step.
        gesture(1, on: pv, in: window, canvas: canvas, n: 30) { u in (CGFloat(200), CGFloat(110 + u * 60), 0.5) }
        expect(count() == start - 2, "button-erase across wave+highlight: \(count())")
        session.undoManager.undo()
        expect(count() == start, "undo restores erased strokes: \(count())")
        session.undoManager.redo()
        expect(count() == start - 2, "redo erases again: \(count())")
        session.undoManager.undo()

        // Lower button quick click (no movement) swaps tool and erases nothing.
        tools.tool = .pen
        tools.tool = .highlighter
        gesture(1, on: pv, in: window, canvas: canvas, n: 2) { _ in (200, 140, 0.5) }
        expect(tools.tool == .pen, "lower-button click swaps back to pen (got \(tools.tool))")
        expect(count() == start, "button click erased nothing: \(count())")

        // Upper button quick click undoes the last action.
        tools.tool = .pen
        gesture(0, on: pv, in: window, canvas: canvas, n: 20) { u in (CGFloat(100 + u * 50), 400, 0.6) }
        expect(count() == start + 1, "extra stroke drawn")
        gesture(2, on: pv, in: window, canvas: canvas, n: 2) { _ in (300, 300, 0.5) }
        expect(count() == start, "upper-button click undoes: \(count())")

        // Eraser tool: a sweep that misses everything changes nothing.
        tools.tool = .eraser
        gesture(0, on: pv, in: window, canvas: canvas, n: 20) { u in (CGFloat(100 + u * 300), 700, 0.5) }
        expect(count() == start, "eraser in empty area: \(count())")

        // Lasso the spiral and drag it 100 pt right.
        tools.tool = .lasso
        let spiral = session.notebook.pages[0].strokes.first { $0.color == ToolState.penPalette[1] }
        gesture(0, on: pv, in: window, canvas: canvas, n: 40) { u in
            let a = u * 2 * .pi
            return (CGFloat(180 + cos(a) * 75), CGFloat(260 + sin(a) * 75), 0.5)
        }
        expect(canvas.hasSelection, "lasso selected the spiral")
        gesture(0, on: pv, in: window, canvas: canvas, n: 20) { u in (CGFloat(180 + u * 100), 260, 0.5) }
        let moved = session.notebook.pages[0].strokes.first { $0.id == spiral?.id }
        if let s = spiral, let m = moved {
            expect(abs((m.bounds.minX - s.bounds.minX) - 100) < 1, "spiral moved by 100 (moved \(m.bounds.minX - s.bounds.minX))")
        } else { fails.append("spiral missing") }
        canvas.clearSelection()

        // Live ink mid-stroke: render the page's layer tree (including the live layer) and check the
        // ink appears where the pen is, i.e. the layer geometry isn't flipped.
        tools.tool = .pen
        tools.penColor = RGBA(1, 0, 0)
        var t = ProcessInfo.processInfo.systemUptime
        canvas.pointerDown(ev(.leftMouseDown, CGPoint(x: 120, y: 760), 0.8, t, pv: pv, window: window), on: pv)
        for i in 1..<30 {
            t += 0.004
            canvas.pointerDragged(ev(.leftMouseDragged, CGPoint(x: 120 + CGFloat(i) * 6, y: 760), 0.8, t, pv: pv, window: window))
        }
        if let layer = pv.layer {
            let w = Int(pv.bounds.width), h = Int(pv.bounds.height)
            let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.setFillColor(.white); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            layer.render(in: ctx)
            // The offscreen render may come out vertically mirrored as a whole. What matters is that the
            // live layer and the committed ink share one orientation: find which way the committed
            // wave (y≈140) landed, and require the live line (y=760) to have landed the same way.
            func pixel(_ x: Int, _ row: Int) -> (UInt8, UInt8, UInt8) {
                guard row >= 0, row < h, let d = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return (255, 255, 255) }
                let o = row * w * 4 + x * 4
                return (d[o], d[o + 1], d[o + 2])
            }
            func rowHas(_ row: Int, _ test: ((UInt8, UInt8, UInt8)) -> Bool) -> Bool {
                (row - 8...row + 8).contains { r in stride(from: 100, to: 480, by: 2).contains { test(pixel($0, r)) } }
            }
            let dark: ((UInt8, UInt8, UInt8)) -> Bool = { $0.0 < 90 && $0.1 < 90 && $0.2 < 110 }
            let red: ((UInt8, UInt8, UInt8)) -> Bool = { $0.0 > 200 && $0.1 < 80 && $0.2 < 80 }
            let waveDirect = rowHas(140, dark), waveMirrored = rowHas(h - 140, dark)
            let liveDirect = rowHas(760, red), liveMirrored = rowHas(h - 760, red)
            expect(waveDirect != waveMirrored, "committed ink found in exactly one orientation")
            expect(waveDirect ? liveDirect : liveMirrored, "live ink drawn in the same orientation as committed ink")
            if let img = ctx.makeImage() {
                try? PageRenderer.writePNG(img, to: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("inkwell-live.png"))
            }
        }
        canvas.pointerUp(ev(.leftMouseUp, CGPoint(x: 300, y: 760), 0.8, t + 0.004, pv: pv, window: window))
        tools.penColor = ToolState.penPalette[0]

        // Memory at maximum zoom: render several scroll positions at 4× and read the real footprint.
        func footprintMB() -> Double {
            var info = task_vm_info_data_t()
            var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
            let kr = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
            }
            return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
        }
        let before = footprintMB()
        canvas.scrollView.magnification = canvas.scrollView.maxMagnification
        for i in 0..<6 {
            canvas.scrollView.contentView.scroll(to: NSPoint(x: 100, y: CGFloat(i) * 260))
            canvas.scrollView.reflectScrolledClipView(canvas.scrollView.contentView)
            window.displayIfNeeded()
        }
        let peak = footprintMB()
        FileHandle.standardError.write(String(format: "memory: %.0f MB at fit-width, %.0f MB after 4x zoom + scroll\n", before, peak).data(using: .utf8)!)
        expect(peak < 1200, "memory at 4x zoom stays bounded (\(Int(peak)) MB)")
        canvas.zoomToFitWidth()

        fails += exerciseV2(on: pv, in: window, canvas: canvas, tools: tools, session: session)
        fails += exerciseZoom(on: pv, in: window, canvas: canvas, tools: tools, session: session)
        fails += exerciseV3(on: pv, in: window, canvas: canvas, tools: tools, session: session, store: store)
        fails += exerciseV4(on: pv, in: window, canvas: canvas, tools: tools, session: session)
        fails += exercisePDF(on: pv, in: window, canvas: canvas, tools: tools, session: session, store: store)

        // Save and reload from disk: identical strokes.
        session.flush()
        if let back = try? store.load(id: session.notebook.id).notebook {
            expect(back.pages == session.notebook.pages, "reloaded pages identical")
        } else { fails.append("reload failed") }
        return fails
    }

    /// Text, images, links, precise erase, scribble, shapes, laser, clipboard, pages and export.
    static func exerciseV2(on pv: PageView, in window: NSWindow, canvas: CanvasView, tools: ToolState, session: NotebookSession) -> [String] {
        var fails: [String] = []
        func expect(_ c: Bool, _ m: String) { if !c { fails.append(m) } }
        let pid = pv.page.id
        func page() -> Page { session.page(pid)! }
        canvas.clearSelection()

        // Precise eraser cuts the wave and the highlighter under it (both cross x=300); undo restores.
        tools.eraserMode = .precise
        tools.tool = .eraser
        var before = page().strokes.count
        gesture(0, on: pv, in: window, canvas: canvas, n: 20) { u in (300, CGFloat(110 + u * 60), 0.5) }
        expect(page().strokes.count == before + 2, "precise erase splits 2 strokes (\(before) → \(page().strokes.count))")
        session.undoManager.undo()
        expect(page().strokes.count == before, "undo precise erase (\(page().strokes.count))")
        tools.eraserMode = .stroke

        // Scribble over a small word deletes it and leaves no scribble behind.
        tools.tool = .pen
        before = page().strokes.count
        gesture(0, on: pv, in: window, canvas: canvas, n: 30) { u in (CGFloat(150 + u * 40), 600, 0.6) }
        expect(page().strokes.count == before + 1, "word written")
        gesture(0, on: pv, in: window, canvas: canvas, n: 120) { u in
            let k = (u * 10).truncatingRemainder(dividingBy: 1)
            return (CGFloat(140 + (k < 0.5 ? k * 2 : 2 - k * 2) * 60), CGFloat(590 + u * 20), 0.6)
        }
        expect(page().strokes.count == before, "scribble erased the word (\(page().strokes.count) vs \(before))")

        // Hold-to-snap: a wobbly loop becomes a clean ellipse.
        before = page().strokes.count
        var t = ProcessInfo.processInfo.systemUptime
        func at(_ p: CGPoint, _ type: NSEvent.EventType) -> NSEvent { ev(type, p, 0.6, t, pv: pv, window: window) }
        canvas.pointerDown(at(CGPoint(x: 400, y: 450), .leftMouseDown), on: pv)
        for i in 1...80 {
            t += 0.006
            let a = CGFloat(i) / 80 * 2 * .pi
            canvas.pointerDragged(at(CGPoint(x: 340 + cos(a) * 60 + sin(a * 7), y: 450 + sin(a) * 35), .leftMouseDragged))
        }
        canvas.snapIfHeld()
        canvas.pointerUp(at(CGPoint(x: 400, y: 450), .leftMouseUp))
        if let s = page().strokes.last, page().strokes.count == before + 1 {
            expect(abs(s.bounds.width - 120 - CGFloat(s.width)) < 12 && s.points.count > 40, "snapped ellipse (\(s.bounds), \(s.points.count) pts)")
        } else { fails.append("shape stroke added") }

        // Laser leaves no marks.
        tools.tool = .laser
        before = page().strokes.count
        gesture(0, on: pv, in: window, canvas: canvas, n: 20) { u in (CGFloat(100 + u * 200), 650, 0.5) }
        expect(page().strokes.count == before && page().elements.isEmpty, "laser leaves no ink")

        // Text tool: type, commit, auto-detected link.
        tools.tool = .text
        canvas.pointerDown(ev(.leftMouseDown, CGPoint(x: 100, y: 720), 0.5, t, pv: pv, window: window), on: pv)
        // Type for real, through the same path as the keyboard (insertText registers undo, checks spelling…).
        if let tv = canvas.textEditor?.textView {
            expect(window.firstResponder === tv, "text view has keyboard focus")
            tv.insertText("Read more at apple.com", replacementRange: NSRange(location: NSNotFound, length: 0))
            tv.insertText(" today", replacementRange: NSRange(location: NSNotFound, length: 0))
            expect(tv.string == "Read more at apple.com today", "typed text appears (\(tv.string))")
            // Real key events too: a keyDown delivered to the window reaches the text view.
            let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: t, windowNumber: window.windowNumber,
                                       context: nil, characters: "!", charactersIgnoringModifiers: "!", isARepeat: false, keyCode: 18)!
            window.sendEvent(key)
            expect(tv.string.hasSuffix("!"), "key event typed (\(tv.string))")
            tv.undoManager?.undo()
            tv.string = "Read more at apple.com today"
        } else { fails.append("text editor opened") }
        canvas.endTextEditing()
        let texts = page().elements.filter { $0.text != nil }
        expect(texts.count == 1 && texts.first?.text == "Read more at apple.com today", "text box committed")
        expect(PageRenderer.linkAreas(page()).count == 1, "link detected in text")
        // An empty new box is discarded, not saved.
        canvas.pointerDown(ev(.leftMouseDown, CGPoint(x: 100, y: 780), 0.5, t, pv: pv, window: window), on: pv)
        canvas.endTextEditing()
        expect(page().elements.count == 1, "empty text box discarded")

        // Image: insert, resize by the handle (aspect kept), link, copy/paste with its asset.
        let img = NSImage(size: NSSize(width: 300, height: 150), flipped: false) { r in
            NSColor.systemTeal.setFill(); r.fill(); return true
        }
        guard let tiff = img.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
            return fails + ["make test image"]
        }
        do { try canvas.insertImage(png, on: pv, at: CGPoint(x: 300, y: 300)) } catch { fails.append("insert image: \(error)") }
        guard let image = page().elements.first(where: { $0.imageAsset != nil }) else { return fails + ["image element"] }
        canvas.select(strokes: [], elements: [image.id], on: pv)
        expect(canvas.state.hasSelection && !canvas.state.selectionHasInk, "image selected")
        tools.tool = .lasso
        canvas.select(strokes: [], elements: [image.id], on: pv)
        let h = canvas.handleRect(for: canvas.selection!)
        gesture(0, on: pv, in: window, canvas: canvas, n: 10) { u in (h.midX + u * 60, h.midY + u * 10, 0.5) }
        if let r = page().elements.first(where: { $0.id == image.id })?.frame {
            expect(r.width > image.frame.width + 30 && abs(r.width / r.height - image.frame.width / image.frame.height) < 0.02,
                   "resized with aspect kept (\(image.frame.size) → \(r.size))")
        }
        canvas.select(strokes: [], elements: [image.id], on: pv)
        expect(canvas.addLink("example.com"), "link accepted")
        expect(page().elements.first { $0.id == image.id }?.link == "https://example.com", "link stored normalised")
        expect(!canvas.addLink("javascript:alert(1)"), "unsafe link refused")
        canvas.select(strokes: [], elements: [image.id], on: pv)
        let assetsBefore = session.notebook.assets.count
        canvas.copy(nil)
        canvas.paste(nil)
        expect(page().elements.filter { $0.imageAsset != nil }.count == 2 && session.notebook.assets.count == assetsBefore + 1,
               "paste duplicates image with its asset")

        // Lasso ink + elements together and move them as one undo step.
        canvas.clearSelection()
        let ink = Set(page().strokes.map(\.id)), els = Set(page().elements.map(\.id))
        canvas.select(strokes: ink, elements: els, on: pv)
        let firstStroke = page().strokes[0].bounds.minX, firstEl = page().elements[0].frame.minX
        gesture(0, on: pv, in: window, canvas: canvas, n: 10) { u in
            let c = canvas.selection!.bounds
            return (c.midX + u * 30, c.midY, 0.5)
        }
        expect(abs(page().strokes[0].bounds.minX - firstStroke - 30) < 1 && abs(page().elements[0].frame.minX - firstEl - 30) < 1, "mixed move")
        session.undoManager.undo()
        expect(abs(page().elements[0].frame.minX - firstEl) < 0.01, "mixed move undone")
        canvas.clearSelection()

        // Pages: duplicate, bookmark, move, delete; all undoable.
        let pages = session.notebook.pages.count
        session.duplicatePage(id: pid)
        expect(session.notebook.pages.count == pages + 1 && session.notebook.pages[1].strokes.count == page().strokes.count, "page duplicated")
        expect(Set(session.notebook.pages[1].strokes.map(\.id)).isDisjoint(with: page().strokes.map(\.id)), "duplicate has fresh ids")
        session.toggleBookmark(id: pid)
        expect(page().bookmark != nil, "bookmarked")
        session.movePage(id: pid, by: 1)
        expect(session.notebook.pages[1].id == pid, "moved down")
        session.undoManager.undo(); session.undoManager.undo(); session.undoManager.undo()
        expect(session.notebook.pages.count == pages && session.notebook.pages[0].id == pid && page().bookmark == nil, "page ops undone")

        // Export: link annotations present (text link + image link + pasted image link).
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("inkwell-uicheck.pdf")
        do {
            try PageRenderer.exportPDF(session.notebook, pages: [0], to: url)
            var annots: CGPDFArrayRef?
            let doc = CGPDFDocument(url as CFURL)
            let ok = doc?.page(at: 1)?.dictionary.map { CGPDFDictionaryGetArray($0, "Annots", &annots) } ?? false
            expect(ok && annots.map { CGPDFArrayGetCount($0) } ?? 0 >= 3, "exported PDF has link annotations")
        } catch { fails.append("export: \(error)") }

        // Handwriting recognition runs (accuracy depends on real handwriting; this checks it doesn't fail).
        _ = HandwritingRecognizer.recognize(strokes: Array(page().strokes.prefix(3)))
        tools.tool = .pen
        return fails
    }

    /// Zoom window: ink lands scaled into the box, auto-advance, next line, ⌥-click, undo, close.
    static func exerciseZoom(on pv: PageView, in window: NSWindow, canvas: CanvasView, tools: ToolState, session: NotebookSession) -> [String] {
        var fails: [String] = []
        func expect(_ c: Bool, _ m: String) { if !c { fails.append(m) } }
        let pid = pv.page.id
        func page() -> Page { session.page(pid)! }
        canvas.scrollToPage(0)
        canvas.toggleZoomWriter()
        window.contentView?.layoutSubtreeIfNeeded()
        guard let z = canvas.zoomWriter else { return ["zoom window opened"] }
        z.layoutSubtreeIfNeeded()
        z.moveTarget(to: CGPoint(x: 80, y: 560), on: pv)
        let paper = z.paper
        expect(paper.bounds.width > 200 && paper.bounds.height > 100, "strip laid out (\(paper.bounds.size))")
        expect(abs(z.target.width - paper.bounds.width / z.zoom) < 1, "box matches strip / zoom")
        tools.tool = .pen
        var t = ProcessInfo.processInfo.systemUptime
        func ev(_ type: NSEvent.EventType, _ p: CGPoint, mods: NSEvent.ModifierFlags = []) -> NSEvent {
            t += 0.005
            return NSEvent.mouseEvent(with: type, location: paper.convert(p, to: nil), modifierFlags: mods, timestamp: t,
                                      windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0.6)!
        }
        func write(from x0: CGFloat, to x1: CGFloat, y: CGFloat) {
            paper.mouseDown(with: ev(.leftMouseDown, CGPoint(x: x0, y: y)))
            for i in 1...30 { paper.mouseDragged(with: ev(.leftMouseDragged, CGPoint(x: x0 + (x1 - x0) * CGFloat(i) / 30, y: y + sin(CGFloat(i)) * 6))) }
            paper.mouseUp(with: ev(.leftMouseUp, CGPoint(x: x1, y: y)))
        }
        let box = z.target
        let before = page().strokes.count
        let w = paper.bounds.width
        write(from: w * 0.1, to: w * 0.4, y: paper.bounds.height / 2)
        expect(page().strokes.count == before + 1, "stroke from strip added")
        if let s = page().strokes.last {
            let expectedWidth = w * 0.3 / z.zoom
            expect(abs((s.bounds.width - CGFloat(s.width)) - expectedWidth) < 6, "ink scaled by 1/zoom (\(s.bounds.width) vs \(expectedWidth))")
            expect(box.insetBy(dx: -4, dy: -4).contains(s.bounds), "ink inside the box")
        }
        expect(z.target == box, "no advance for a stroke in the left part")
        write(from: w * 0.5, to: w * 0.9, y: paper.bounds.height / 2)
        expect(z.target.minX > box.minX + 10, "auto-advanced after writing near the edge")
        let y0 = z.target.minY
        z.newLine()
        expect(z.target.minY > y0 && abs(z.target.minX - ZoomWriter.leftMargin(page())) < 0.5, "new line returns to the margin")
        // Upper pen button click in the strip undoes the last stroke.
        let n = page().strokes.count
        paper.otherMouseDown(with: ev(.otherMouseDown, CGPoint(x: 50, y: 50)))
        paper.otherMouseUp(with: ev(.otherMouseUp, CGPoint(x: 50, y: 50)))
        expect(page().strokes.count == n - 1, "upper-button click in strip undoes")
        // ⌥-click on the page moves the box there.
        let click = NSEvent.mouseEvent(with: .leftMouseDown, location: pv.convert(CGPoint(x: 300, y: 300), to: nil), modifierFlags: .option,
                                       timestamp: t, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        canvas.pointerDown(click, on: pv)
        canvas.pointerUp(NSEvent.mouseEvent(with: .leftMouseUp, location: click.locationInWindow, modifierFlags: .option, timestamp: t,
                                            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0)!)
        // Left edge just before the click, unless that would push the box off the page's right edge.
        let wantX = min(292, page().rect.maxX - z.target.width)
        expect(abs(z.target.minX - wantX) < 1 && abs(z.target.midY - 300) < 1, "⌥-click placed the box (\(z.target))")
        expect(canvas.inputMapper == nil && canvas.inputScale == nil && pv.live.mirror == nil, "input routing reset after strip gestures")
        // Snapshot with the strip open (after animations and SwiftUI layout settle), then close it.
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        window.displayIfNeeded()

        if let v = window.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
            v.cacheDisplay(in: v.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("inkwell-zoom.png"))
        }
        // Deleting the page the box sits on moves the box to a page that exists.
        if canvas.pageViews.count > 1 {
            let second = canvas.pageViews[1]
            z.attach(to: second)
            session.deletePage(id: second.page.id)
            expect(z.pageView != nil && canvas.pageViews.contains { $0 === z.pageView }, "box re-homed after its page was deleted")
            session.undoManager.undo()
        }
        canvas.toggleZoomWriter()
        expect(canvas.zoomWriter == nil, "zoom window closed")
        // Background handwriting recognition must not reorder the library.
        let modified = session.notebook.modified
        session.setRecognizedText("test words", signature: page().inkSignature, for: pid)
        expect(session.notebook.modified == modified && page().recognizedText == "test words", "recognition doesn't touch modified date")
        return fails
    }

    /// Tape, study cards, ruler, maths, replay dimming, password lock, folders.
    static func exerciseV3(on pv: PageView, in window: NSWindow, canvas: CanvasView, tools: ToolState,
                           session: NotebookSession, store: LibraryStore) -> [String] {
        var fails: [String] = []
        func expect(_ c: Bool, _ m: String) { if !c { fails.append(m) } }
        let pid = pv.page.id
        func page() -> Page { session.page(pid)! }
        canvas.scrollToPage(0)

        // Tape: drag creates, click peels back, click again covers.
        tools.tool = .tape
        let tapesBefore = page().elements.filter(\.isTape).count
        gesture(0, on: pv, in: window, canvas: canvas, n: 10) { u in (CGFloat(100 + u * 160), CGFloat(130 + u * 30), 0.5) }
        let tapes = page().elements.filter(\.isTape)
        expect(tapes.count == tapesBefore + 1, "tape created")
        guard let tape = tapes.last else { return fails + ["no tape"] }
        expect(abs(tape.frame.width - 160) < 2 && abs(tape.frame.height - 30) < 2 && tape.review != nil, "tape frame + card state (\(tape.frame))")
        gesture(0, on: pv, in: window, canvas: canvas, n: 2) { _ in (tape.frame.midX, tape.frame.midY, 0.5) }
        expect(canvas.revealedTapes.contains(tape.id), "click peels tape back")
        gesture(0, on: pv, in: window, canvas: canvas, n: 2) { _ in (tape.frame.midX, tape.frame.midY, 0.5) }
        expect(!canvas.revealedTapes.contains(tape.id), "second click covers again")
        let covered = PageRenderer.image(of: page(), maxSide: 600, assets: session.assets)
        let peeled = PageRenderer.image(of: page(), maxSide: 600, assets: session.assets, revealedTapes: [tape.id])
        expect(covered != nil && peeled != nil && covered!.dataProvider?.data as Data? != peeled!.dataProvider?.data as Data?, "tape changes what's visible")

        // Study: the new card is due; reveal + grade schedules it; "again" re-queues.
        let study = StudyModel(session: session, all: false)
        expect(study.queue.contains { $0.tape == tape.id } && study.image != nil, "card queued and rendered")
        while let c = study.current, c.tape != tape.id { study.reveal(); study.grade(.good) }
        study.grade(.good)
        expect(study.current?.tape == tape.id, "can't grade before revealing")
        study.reveal()
        study.grade(.again)
        expect(study.queue.filter { $0.tape == tape.id }.count == 2, "again → seen again this session")
        while study.current != nil { study.reveal(); study.grade(.good) }
        expect(study.finished, "session finishes")
        let rev = page().elements.first { $0.id == tape.id }?.review
        expect(rev != nil && rev!.due > Date() && rev!.lapses == 1, "review stored: due later, one lapse")

        // Ruler: ink drawn near its edge lands exactly on the edge line.
        tools.tool = .pen
        canvas.toggleRuler()
        expect(canvas.isRulerShown, "ruler shown")
        canvas.rotateRuler(to: .pi / 6)
        let r = canvas.ruler!
        let n = CGVector(dx: -sin(r.angle), dy: cos(r.angle)), d = CGVector(dx: cos(r.angle), dy: sin(r.angle))
        let edge = CGPoint(x: r.center.x + n.dx * (r.width / 2 + 6), y: r.center.y + n.dy * (r.width / 2 + 6))
        let before = page().strokes.count
        gesture(0, on: pv, in: window, canvas: canvas, n: 30) { u in
            let t = (u - 0.5) * 300, wobble = sin(u * 30) * 5
            return (edge.x + d.dx * t + n.dx * wobble, edge.y + d.dy * t + n.dy * wobble, 0.6)
        }
        if page().strokes.count == before + 1, let s = page().strokes.last {
            let devs = s.points.map { p -> CGFloat in
                let v = CGPoint(x: CGFloat(p.x) - r.center.x, y: CGFloat(p.y) - r.center.y)
                return abs(v.x * n.dx + v.y * n.dy)
            }
            expect((devs.max() ?? 99) - (devs.min() ?? 0) < 0.05, "ruler ink perfectly straight (spread \((devs.max() ?? 99) - (devs.min() ?? 0)))")
        } else { fails.append("ruler stroke added") }
        // Grab the ruler body and move it.
        let c0 = r.center
        gesture(0, on: pv, in: window, canvas: canvas, n: 10) { u in (c0.x + u * 40, c0.y + u * 20, 0.5) }
        expect(abs(canvas.ruler!.center.x - c0.x - 40) < 1 && page().strokes.count == before + 1, "drag on ruler moves it, draws nothing")
        canvas.toggleRuler()
        expect(!canvas.isRulerShown, "ruler hidden")

        // Maths: Solve inserts the result beside the sum (OCR bypassed; MathEval + insertion tested).
        if let res = MathEval.solve("12 x (3+4) =") {
            let els = page().elements.count
            canvas.insertResult(res, beside: CGRect(x: 100, y: 500, width: 120, height: 30), strokes: [], on: pv)
            expect(page().elements.count == els + 1 && page().elements.last?.text == "= 84", "solve result inserted")
        } else { fails.append("MathEval") }

        // Audio replay: later ink is drawn faint (render differs while replaying).
        if var s = page().strokes.first {
            let rec = UUID()
            s.recording = rec
            s.recordingOffset = 50
            session.editPage(pid, "test") { $0.strokes[0] = s }
            var o = PageRenderer.Options()
            o.replay = (rec, 10)
            func render(_ o: PageRenderer.Options) -> Data? {
                let ctx = CGContext(data: nil, width: 300, height: 300, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                ctx.translateBy(x: 0, y: 300); ctx.scaleBy(x: 0.5, y: -0.5)
                PageRenderer.draw(page(), in: ctx, assets: session.assets, options: o)
                return ctx.makeImage()?.dataProvider?.data as Data?
            }
            expect(render(o) != render(PageRenderer.Options()), "replay dims ink not yet 'written'")
            canvas.setReplay(recording: rec, time: 10)
            expect(canvas.replay?.recording == rec, "canvas replay state set")
            canvas.setReplay(recording: nil, time: 0)
            session.undoManager.undo()
        }

        // Password lock: saved file needs the password; removing it makes it plain again.
        session.setPassword("test-pass-123")
        session.flush()
        do { _ = try store.load(id: session.notebook.id); fails.append("locked file opened without password") }
        catch { expect((error as? NotebookCodec.CodecError) == .locked, "locked on disk") }
        expect((try? store.load(id: session.notebook.id, password: "test-pass-123"))?.notebook.pages == session.notebook.pages, "opens with password")
        let meta = store.list().notebooks.first { $0.id == session.notebook.id }
        expect(meta?.locked == true && meta?.pageTexts == nil, "library sees title only")
        session.setPassword(nil)
        session.flush()
        expect((try? store.load(id: session.notebook.id)) != nil, "password removed")

        // Folders: move and persist through the store.
        var f = store.loadFolders()
        f.folders.append(LibraryFolder(name: "Tests"))
        f.move(session.notebook.id, to: f.folders.last!.id)
        try? store.saveFolders(f)
        expect(store.loadFolders().folder(of: session.notebook.id) == f.folders.last!.id, "folder membership persisted")
        f.move(session.notebook.id, to: nil)
        try? store.saveFolders(f)
        return fails
    }

    /// Strokes tracing a string's glyph outlines (a stand-in for real handwriting in tests).
    static func glyphStrokes(_ text: String, font: String, size: CGFloat, at origin: CGPoint) -> [Stroke] {
        let f = CTFontCreateWithName(font as CFString, size, nil)
        let chars = Array(text.utf16)
        var glyphs = [CGGlyph](repeating: 0, count: chars.count)
        CTFontGetGlyphsForCharacters(f, chars, &glyphs, chars.count)
        var advances = [CGSize](repeating: .zero, count: glyphs.count)
        CTFontGetAdvancesForGlyphs(f, .horizontal, glyphs, &advances, glyphs.count)
        var out: [Stroke] = []
        var x = origin.x
        for (g, adv) in zip(glyphs, advances) {
            defer { x += adv.width }
            guard let path = CTFontCreatePathForGlyph(f, g, nil) else { continue }
            var runs: [[CGPoint]] = [], cur: [CGPoint] = [], last = CGPoint.zero
            func add(_ p: CGPoint) { cur.append(CGPoint(x: x + p.x, y: origin.y - p.y)); last = p } // flip: glyph y is up
            path.applyWithBlock { el in
                let e = el.pointee
                switch e.type {
                case .moveToPoint: if !cur.isEmpty { runs.append(cur) }; cur = []; add(e.points[0])
                case .addLineToPoint: add(e.points[0])
                case .addQuadCurveToPoint:
                    let p0 = last, c = e.points[0], p1 = e.points[1]
                    for i in 1...6 { let t = CGFloat(i) / 6; add(CGPoint(x: (1-t)*(1-t)*p0.x + 2*(1-t)*t*c.x + t*t*p1.x, y: (1-t)*(1-t)*p0.y + 2*(1-t)*t*c.y + t*t*p1.y)) }
                case .addCurveToPoint:
                    let p0 = last, c1 = e.points[0], c2 = e.points[1], p1 = e.points[2]
                    for i in 1...8 {
                        let t = CGFloat(i) / 8, u = 1 - t
                        add(CGPoint(x: u*u*u*p0.x + 3*u*u*t*c1.x + 3*u*t*t*c2.x + t*t*t*p1.x, y: u*u*u*p0.y + 3*u*u*t*c1.y + 3*u*t*t*c2.y + t*t*t*p1.y))
                    }
                case .closeSubpath: if let f = cur.first { cur.append(f) }
                @unknown default: break
                }
            }
            if !cur.isEmpty { runs.append(cur) }
            for r in runs where r.count >= 2 {
                if let s = Stroke(kind: .pen, color: RGBA(0.1, 0.1, 0.15), width: 2.2,
                                  points: r.map { InkPoint(x: Float($0.x), y: Float($0.y), pressure: 0.6, time: 0) }) { out.append(s) }
            }
        }
        return out
    }

    /// Text tool editing/moving, auto-answer (fake + real recogniser), Shift lines, Esc, page keys, smart zoom.
    static func exerciseV4(on pv: PageView, in window: NSWindow, canvas: CanvasView, tools: ToolState,
                           session: NotebookSession) -> [String] {
        var fails: [String] = []
        func expect(_ c: Bool, _ m: String) { if !c { fails.append(m) } }
        let pid = pv.page.id
        func page() -> Page { session.page(pid)! }
        canvas.scrollToPage(0)
        canvas.clearSelection()
        var t = ProcessInfo.processInfo.systemUptime
        func ev(_ type: NSEvent.EventType, _ p: CGPoint, mods: NSEvent.ModifierFlags = [], clicks: Int = 1) -> NSEvent {
            t += 0.006
            return NSEvent.mouseEvent(with: type, location: pv.convert(p, to: nil), modifierFlags: mods, timestamp: t,
                                      windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: 0.6)!
        }

        // Text tool: click empty → new box; type; commit is ONE notebook undo step; drag moves; click edits.
        tools.tool = .text
        canvas.pointerDown(ev(.leftMouseDown, CGPoint(x: 120, y: 640)), on: pv)
        canvas.pointerUp(ev(.leftMouseUp, CGPoint(x: 120, y: 640)))
        guard let tv = canvas.textEditor?.textView else { return ["text editor opened"] }
        tv.insertText("Shopping list", replacementRange: NSRange(location: NSNotFound, length: 0))
        let before = session.undoManager.canUndo
        tv.undoManager?.undo() // typing undo stays inside the box…
        expect(tv.undoManager !== session.undoManager && session.undoManager.canUndo == before, "…and never touches the notebook's history")
        tv.string = ""
        tv.insertText("Shopping list", replacementRange: NSRange(location: NSNotFound, length: 0))
        let notebookUndoable = session.undoManager.canUndo
        canvas.endTextEditing()
        guard let box = page().elements.last(where: { $0.text == "Shopping list" }) else { return fails + ["typed box committed"] }
        expect(box.frame.maxX <= page().rect.maxX, "box fits on the page")
        session.undoManager.undo()
        expect(!page().elements.contains { $0.id == box.id }, "one ⌘Z removes the new box")
        session.undoManager.redo()
        expect(page().elements.contains { $0.id == box.id }, "redo restores it")
        _ = notebookUndoable
        // Drag with the text tool moves the box.
        let c = CGPoint(x: box.frame.midX, y: box.frame.midY)
        canvas.pointerDown(ev(.leftMouseDown, c), on: pv)
        for i in 1...10 { canvas.pointerDragged(ev(.leftMouseDragged, CGPoint(x: c.x + CGFloat(i) * 4, y: c.y))) }
        canvas.pointerUp(ev(.leftMouseUp, CGPoint(x: c.x + 40, y: c.y)))
        let moved = page().elements.first { $0.id == box.id }!.frame
        expect(abs(moved.minX - box.frame.minX - 40) < 1 && canvas.textEditor == nil && !canvas.hasSelection, "text tool drag moves the box")
        // Click edits it.
        let c2 = CGPoint(x: moved.midX, y: moved.midY)
        canvas.pointerDown(ev(.leftMouseDown, c2), on: pv)
        canvas.pointerUp(ev(.leftMouseUp, c2))
        expect(canvas.textEditor?.textView.string == "Shopping list", "text tool click opens the box for editing")
        canvas.endTextEditing()

        // Auto-answer with a stand-in recogniser: write strokes then "=" → answer appears.
        tools.tool = .pen
        tools.autoSolve = true
        canvas.mathRecognizer = { _ in "12 x (3+4)" }
        for (x0, x1) in [(100, 118), (124, 140), (150, 170)] as [(CGFloat, CGFloat)] {
            gesture(0, on: pv, in: window, canvas: canvas, n: 12) { u in (x0 + (x1 - x0) * u, 700 + sin(u * 6) * 6, 0.6) }
        }
        gesture(0, on: pv, in: window, canvas: canvas, n: 10) { u in (180 + u * 22, 696, 0.6) }
        gesture(0, on: pv, in: window, canvas: canvas, n: 10) { u in (181 + u * 21, 705, 0.6) }
        // (The test itself runs on the main queue, so the 0.7 s delayed check can't fire here: run it directly.)
        expect(canvas.autoSolveWork.map { !$0.isCancelled } ?? false, "'=' detected: answer scheduled for the pause")
        canvas.autoSolveWork?.perform()
        let answer = page().elements.last { $0.text == "84" }
        expect(answer != nil && answer?.textStyle?.font == .hand && (answer?.frame.minX ?? 0) > 200, "answer '84' written after '=' (\(page().elements.compactMap(\.text)))")
        let count = page().elements.count
        canvas.autoSolve(on: pv)
        expect(page().elements.count == count, "each sum is answered once")
        canvas.mathRecognizer = nil

        // The real on-device recogniser reads glyph-traced "12+7" as a sum.
        let traced = glyphStrokes("12+7", font: "Noteworthy-Bold", size: 60, at: CGPoint(x: 100, y: 200))
        let read = HandwritingRecognizer.recognize(strokes: traced, languageCorrection: false)
        let solved = MathEval.solve(read)
        FileHandle.standardError.write("vision-math: read \"\(read)\" → \(solved?.formatted ?? "nil")\n".data(using: .utf8)!)
        expect(solved?.formatted == "19", "Vision reads 12+7 (read \"\(read)\")")

        // Shift: a straight line at a 15° multiple.
        let n0 = page().strokes.count
        canvas.pointerDown(ev(.leftMouseDown, CGPoint(x: 300, y: 400)), on: pv)
        for i in 1...20 { canvas.pointerDragged(ev(.leftMouseDragged, CGPoint(x: 300 + CGFloat(i) * 8, y: 400 + CGFloat(i) * 2.2 + (i % 2 == 0 ? 3 : -3)), mods: .shift)) }
        canvas.pointerUp(ev(.leftMouseUp, CGPoint(x: 460, y: 444), mods: .shift))
        if page().strokes.count == n0 + 1, let s = page().strokes.last, let a = s.points.first, let b = s.points.last {
            let deg = atan2(Double(b.y - a.y), Double(b.x - a.x)) * 180 / .pi
            expect(abs(deg - (deg / 15).rounded() * 15) < 0.01, "Shift line snapped to 15° (\(deg)°)")
        } else { fails.append("Shift line drawn") }

        // Esc cancels a lasso in progress.
        tools.tool = .lasso
        canvas.pointerDown(ev(.leftMouseDown, CGPoint(x: 90, y: 90)), on: pv)
        for i in 1...10 { canvas.pointerDragged(ev(.leftMouseDragged, CGPoint(x: 90 + CGFloat(i) * 30, y: 90 + CGFloat(i % 3) * 40))) }
        let esc = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: t, windowNumber: window.windowNumber,
                                   context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
        canvas.keyDown(with: esc)
        if case .none = canvas.gesture {} else { fails.append("Esc cancelled the lasso") }
        canvas.pointerUp(ev(.leftMouseUp, CGPoint(x: 400, y: 120)))
        expect(!canvas.hasSelection, "nothing selected after Esc")
        tools.tool = .pen

        // Page Down / Up.
        if canvas.pageViews.count > 1 {
            let pd = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: t, windowNumber: window.windowNumber,
                                      context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 121)!
            canvas.scrollToPage(0)
            canvas.keyDown(with: pd)
            expect(session.currentPageIndex == 1, "Page Down → page 2")
            let pu = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: t, windowNumber: window.windowNumber,
                                      context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 116)!
            canvas.keyDown(with: pu)
            expect(session.currentPageIndex == 0, "Page Up → page 1")
        }

        // Smart zoom in, then back to fit.
        let m0 = canvas.scrollView.magnification
        canvas.smartZoom(at: ev(.leftMouseDown, CGPoint(x: 300, y: 300)))
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        let m1 = canvas.scrollView.magnification
        canvas.smartZoom(at: ev(.leftMouseDown, CGPoint(x: 300, y: 300)))
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        expect(m1 > m0 * 1.5 && abs(canvas.scrollView.magnification - m0) < 0.05, "smart zoom in/out (\(m0) → \(m1) → \(canvas.scrollView.magnification))")
        return fails
    }

    /// PDF workflow: highlight snapping to text lines, table of contents → bookmarks, .inkwell import,
    /// and pen-only mode still letting the mouse select.
    static func exercisePDF(on pv: PageView, in window: NSWindow, canvas: CanvasView, tools: ToolState,
                            session: NotebookSession, store: LibraryStore) -> [String] {
        var fails: [String] = []
        func expect(_ c: Bool, _ m: String) { if !c { fails.append(m) } }
        // A 2-page PDF: lines of 14 pt text at known baselines, plus a table of contents.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("inkwell-pdftest.pdf")
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let ctx = CGContext(url as CFURL, mediaBox: &box, nil)!
        let font = CTFontCreateWithName("Helvetica" as CFString, 14, nil)
        for p in 0..<2 {
            ctx.beginPDFPage(nil)
            for (i, text) in ["Photosynthesis converts light energy into chemical energy.",
                              "Chlorophyll absorbs mostly blue and red wavelengths.",
                              "The Calvin cycle fixes carbon dioxide into sugars."].enumerated() {
                let line = CTLineCreateWithAttributedString(NSAttributedString(string: "\(p + 1).\(i + 1) " + text,
                                                                             attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]))
                ctx.textPosition = CGPoint(x: 72, y: 700 - CGFloat(i) * 40) // PDF y-up baselines
                CTLineDraw(line, ctx)
            }
            ctx.endPDFPage()
        }
        ctx.closePDF()
        guard let doc = PDFDocument(url: url) else { return ["test PDF"] }
        let root = PDFOutline()
        for (i, label) in ["Chapter 1: Light", "Chapter 2: Carbon"].enumerated() {
            let item = PDFOutline()
            item.label = label
            item.destination = PDFDestination(page: doc.page(at: i)!, at: CGPoint(x: 0, y: 792))
            root.insertChild(item, at: i)
        }
        doc.outlineRoot = root
        guard let data = doc.dataRepresentation() else { return ["PDF with outline"] }

        let before = session.notebook.pages.count
        do { try canvas.insertPDFPages(data, title: "Bio") } catch { return ["insert PDF: \(error)"] }
        let added = Array(session.notebook.pages.suffix(from: min(before, session.notebook.pages.count)))
        let inserted = session.notebook.pages.filter { if case .pdf = $0.background { return $0.documentText?.contains("Photosynthesis") == true } else { return false } }
        expect(inserted.count == 2, "PDF pages inserted with their text (\(inserted.count))")
        expect(inserted.map { $0.bookmark ?? "" } == ["Chapter 1: Light", "Chapter 2: Carbon"], "table of contents → bookmarks (\(inserted.map { $0.bookmark ?? "nil" }))")
        _ = added
        guard let page = inserted.first, let ppv = canvas.pageViews.first(where: { $0.page.id == page.id }) else { return fails + ["PDF page view"] }
        let lines = canvas.pdfText.lines(on: page, in: page.rect)
        expect(lines.count == 3, "three text lines found on the PDF page (\(lines.count))")

        // A wobbly, slightly slanted highlighter swipe over the middle line snaps onto it.
        tools.tool = .highlighter
        tools.snapHighlights = true
        canvas.scrollToPage(canvas.pageViews.firstIndex { $0 === ppv } ?? 0)
        guard lines.count == 3 else { return fails }
        let target = lines.sorted { $0.minY < $1.minY }[1]
        let n0 = ppv.page.strokes.count
        gesture(0, on: ppv, in: window, canvas: canvas, n: 30) { u in
            (target.minX + 10 + u * 200, target.midY - 3 + u * 6 + sin(u * 20) * 2, 0.5)
        }
        let made = Array(ppv.page.strokes.suffix(from: n0))
        if made.count == 1, let s = made.first, let a = s.points.first, let b = s.points.last {
            expect(a.y == b.y && abs(CGFloat(a.y) - target.midY) < 0.5, "highlight straight and on the line (y \(a.y) vs \(target.midY))")
            expect(CGFloat(s.width) >= target.height, "covers the line height")
            // The visible ends (endpoint ± round cap) land on word edges, not inside or past words.
            let r = CGFloat(s.width) / 2
            let visibleStart = CGFloat(a.x) - r, visibleEnd = CGFloat(b.x) + r
            let startWord = canvas.pdfText.word(at: CGPoint(x: visibleStart + 3, y: target.midY), on: ppv.page)
            let endWord = canvas.pdfText.word(at: CGPoint(x: visibleEnd - 3, y: target.midY), on: ppv.page)
            expect(startWord.map { abs($0.minX - visibleStart) < 2 } ?? false, "highlight starts at a word edge")
            expect(endWord.map { abs($0.maxX - visibleEnd) < 2 } ?? false, "highlight ends at a word edge (end \(visibleEnd) vs \(endWord?.maxX ?? -1))")
        } else { fails.append("one snapped highlight (\(made.count))") }
        // Off-text (empty margin) highlight stays as drawn.
        let n1 = ppv.page.strokes.count
        gesture(0, on: ppv, in: window, canvas: canvas, n: 20) { u in (100 + u * 150, 500 + u * 4, 0.5) }
        expect(ppv.page.strokes.count == n1 + 1 && (ppv.page.strokes.last?.points.count ?? 0) > 2, "highlight on blank area stays freehand")

        // Pen-only mode: a mouse drag with the lasso selects instead of panning.
        tools.penOnly = true
        tools.tool = .lasso
        gesture(0, on: ppv, in: window, canvas: canvas, n: 40) { u in
            let a = u * 2 * .pi
            return (ppv.bounds.midX + cos(a) * 280, target.midY + sin(a) * 60, 0.5)
        }
        expect(canvas.hasSelection, "pen-only mode: mouse lasso still selects")
        canvas.clearSelection()
        tools.penOnly = false
        tools.tool = .pen

        // .inkwell from elsewhere: imported once, a second identical import doesn't duplicate.
        session.flush()
        let src = FileManager.default.temporaryDirectory.appendingPathComponent("\(session.notebook.id.uuidString).inkwell")
        try? FileManager.default.removeItem(at: src)
        try? FileManager.default.copyItem(at: store.url(for: session.notebook.id), to: src)
        let sameID = try? store.importNotebookFile(src)
        expect(sameID == session.notebook.id, "identical file already in the library isn't duplicated")
        var other = session.notebook
        other.title = "Changed elsewhere"
        if let changed = try? NotebookCodec.encode(other) { try? changed.write(to: src) }
        let newID = try? store.importNotebookFile(src)
        expect(newID != nil && newID != session.notebook.id && store.exists(id: newID!), "a different version imports as a copy")
        if let n = newID { try? store.trash(id: n) }
        return fails
    }

    /// Big-PDF stress test: builds a text-heavy PDF, imports it, opens it, scrolls through, reports timings.
    static func perfPDF(appDelegate: AppDelegate) {
        func ms(_ t: Date) -> String { String(format: "%.0f ms", Date().timeIntervalSince(t) * 1000) }
        func mb() -> Double {
            var info = task_vm_info_data_t()
            var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
            _ = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) } }
            return Double(info.phys_footprint) / 1_048_576
        }
        let pages = Int(ProcessInfo.processInfo.environment["INKWELL_PERF"] ?? "") ?? 300
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("inkwell-perf.pdf")
        var t = Date()
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let ctx = CGContext(url as CFURL, mediaBox: &box, nil)!
        let para = String(repeating: "The mitochondrion is the powerhouse of the cell; ATP synthase couples proton flow to phosphorylation. ", count: 40)
        for i in 0..<pages {
            ctx.beginPDFPage(nil)
            let attr = NSAttributedString(string: "Page \(i + 1)\n" + para, attributes: [.font: NSFont.systemFont(ofSize: 10)])
            let fs = CTFramesetterCreateWithAttributedString(attr)
            CTFrameDraw(CTFramesetterCreateFrame(fs, CFRange(location: 0, length: 0), CGPath(rect: box.insetBy(dx: 50, dy: 50), transform: nil), nil), ctx)
            ctx.endPDFPage()
        }
        ctx.closePDF()
        let data = try! Data(contentsOf: url)
        FileHandle.standardError.write("perf: built \(pages)-page PDF (\(data.count / 1024) KB) in \(ms(t))\n".data(using: .utf8)!)
        t = Date()
        var nb = try! Importer.notebook(fromPDF: data, title: "Perf")
        if let a = nb.assets.keys.first { PDFText.fill(&nb.pages, pdfAsset: a, data: data) }
        try! appDelegate.store.save(nb)
        FileHandle.standardError.write("perf: import + text + save \(ms(t))\n".data(using: .utf8)!)
        let m0 = mb()
        t = Date()
        appDelegate.openNotebook(nb.id)
        guard let c = appDelegate.notebookController(nb.id), let w = c.window else { return }
        w.displayIfNeeded()
        FileHandle.standardError.write("perf: open + first display \(ms(t)), memory +\(Int(mb() - m0)) MB\n".data(using: .utf8)!)
        t = Date()
        var worst = 0.0
        for i in stride(from: 0, to: pages, by: max(1, pages / 60)) {
            let f = Date()
            c.canvas.scrollToPage(i)
            w.displayIfNeeded()
            worst = max(worst, Date().timeIntervalSince(f))
        }
        FileHandle.standardError.write(String(format: "perf: scrolled through in %@, worst frame %.0f ms, memory +%d MB\n", ms(t), worst * 1000, Int(mb() - m0)).data(using: .utf8)!)
        // Ink on a heavy page: 2,000 strokes, then time one more stroke's commit + redraw.
        if let pv = c.canvas.pageViews.first {
            var strokes: [Stroke] = []
            for i in 0..<2000 {
                var pts: [InkPoint] = []
                for k in 0..<40 {
                    let x = Float(20 + (i % 50) * 11 + k % 9), y = Float(20 + (i / 50) * 18 + k / 9)
                    pts.append(InkPoint(x: x, y: y, pressure: 0.5, time: Float(k) * 0.004))
                }
                if let st = Stroke(kind: .pen, color: RGBA(0, 0, 0), width: 2, points: pts) { strokes.append(st) }
            }
            c.session.addStrokes(strokes, to: pv.page.id)
            w.displayIfNeeded()
            let f = Date()
            if let one = Stroke(kind: .pen, color: RGBA(0, 0, 0), width: 2, points: (0..<60).map { InkPoint(x: Float(100 + $0 * 3), y: 400, pressure: 0.6, time: Float($0) * 0.004) }) {
                c.session.addStrokes([one], to: pv.page.id)
                pv.displayIfNeeded()
            }
            FileHandle.standardError.write("perf: commit 1 stroke on a 2,000-stroke page \(ms(f))\n".data(using: .utf8)!)
            let u = Date()
            c.session.undoManager.undo()
            pv.displayIfNeeded()
            FileHandle.standardError.write("perf: undo on that page \(ms(u))\n".data(using: .utf8)!)
        }
        c.close()
    }

    /// Runs a full synthetic Pen Lab session: every exercise, results, recommendation, saved file, apply.
    static func exercisePenLab(appDelegate: AppDelegate) -> [String] {
        var fails: [String] = []
        func expect(_ c: Bool, _ m: String) { if !c { fails.append(m) } }
        appDelegate.showPenLab()
        guard let ctl = appDelegate.penLabController, let window = ctl.window else { return ["pen lab window"] }
        RunLoop.current.run(until: Date().addingTimeInterval(0.3)) // let SwiftUI place the board
        let board = ctl.board
        guard board.window === window else { return ["board in window"] }
        let model = ctl.model
        var t = ProcessInfo.processInfo.systemUptime
        func ev(_ type: NSEvent.EventType, _ p: CGPoint, _ pressure: Float) -> NSEvent {
            t += 1.0 / 266
            return NSEvent.mouseEvent(with: type, location: board.convert(p, to: nil), modifierFlags: [], timestamp: t,
                                      windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: pressure)!
        }
        func stroke(_ pts: [CGPoint], _ pressure: (Double) -> Float) {
            guard let f = pts.first, let l = pts.last else { return }
            board.mouseDown(with: ev(.leftMouseDown, f, pressure(0)))
            for (i, p) in pts.enumerated().dropFirst().dropLast() { board.mouseDragged(with: ev(.leftMouseDragged, p, pressure(Double(i) / Double(pts.count)))) }
            board.mouseUp(with: ev(.leftMouseUp, l, pressure(1)))
        }
        func line(_ a: CGPoint, _ b: CGPoint, n: Int = 80) -> [CGPoint] {
            (0...n).map { i in CGPoint(x: a.x + (b.x - a.x) * CGFloat(i) / CGFloat(n), y: a.y + (b.y - a.y) * CGFloat(i) / CGFloat(n) + CGFloat(i % 2) * 0.4) }
        }
        for ex in PenExercise.allCases {
            model.exercise = ex
            switch ex {
            case .hover:
                for c in PenLabModel.hoverTargets { board.mouseMoved(with: ev(.mouseMoved, c, 0)) }
            case .ramp:
                for (a, b) in PenLabModel.guideLines(.ramp) { stroke(line(a, b)) { Float(0.05 + 0.85 * $0) } }
            case .light, .normal, .firm:
                let p: Float = ex == .light ? 0.15 : ex == .normal ? 0.4 : 0.8
                for (a, b) in PenLabModel.guideLines(ex) { stroke(line(a, b)) { _ in p } }
            case .taps:
                for d in PenLabModel.tapDots { stroke([d, CGPoint(x: d.x + 0.5, y: d.y), CGPoint(x: d.x + 1, y: d.y)]) { _ in 0.35 } }
            case .lines:
                for (a, b) in PenLabModel.guideLines(.lines) { stroke(line(a, b)) { _ in 0.4 } }
            case .circles:
                for (c, r) in PenLabModel.circles {
                    stroke((0...90).map { i in let a = CGFloat(i) / 90 * 2 * .pi; return CGPoint(x: c.x + cos(a) * r, y: c.y + sin(a) * r) }) { _ in 0.4 }
                }
            case .speed:
                stroke((0...40).map { i in CGPoint(x: 80 + CGFloat(i) * 17, y: i % 2 == 0 ? 100 : 380) }) { _ in 0.5 }
            case .handwriting:
                for k in 0..<12 {
                    let x0 = 70 + CGFloat(k) * 60
                    stroke((0...30).map { i in CGPoint(x: x0 + CGFloat(i) * 1.5, y: 200 - sin(CGFloat(i) / 5) * 25) }) { _ in 0.4 }
                }
            case .buttons:
                board.rightMouseDown(with: ev(.rightMouseDown, CGPoint(x: 280, y: 220), 1))
                board.rightMouseUp(with: ev(.rightMouseUp, CGPoint(x: 280, y: 220), 0))
                board.otherMouseDown(with: ev(.otherMouseDown, CGPoint(x: 580, y: 220), 1))
                board.otherMouseUp(with: ev(.otherMouseUp, CGPoint(x: 580, y: 220), 0))
            }
            expect(model.isDone(ex), "\(ex.rawValue) completes (\(model.progress(ex))/\(ex.required))")
        }
        model.finish()
        let s = model.summary()
        expect(abs((s.reportRate ?? 0) - 266) < 3, "report rate measured (\(s.reportRate ?? -1))")
        expect(abs((s.light ?? 0) - 0.15) < 0.01 && abs((s.firm ?? 0) - 0.8) < 0.01, "light/firm medians")
        expect((s.circleJitter ?? 9) < 0.5, "circle jitter small for traced circles (\(s.circleJitter ?? -1))")
        expect(model.buttonsSeen == [1, 2], "both pen buttons seen")
        guard let r = model.recommendation else { return fails + ["recommendation"] }
        expect(r.curve.isSane && abs(r.curve.apply(s.normal ?? 0.4) - 0.55) < 0.03, "normal maps to ~55% (\(r.curve))")
        let latest = PenLabModel.folder.appendingPathComponent("latest.json")
        if let data = try? Data(contentsOf: latest) {
            let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
            let report = try? dec.decode(PenLabReport.self, from: data)
            expect(report?.samples["circles"]?.count ?? 0 > 200 && report?.recommendation == r, "saved report decodes with samples + recommendation")
        } else { fails.append("latest.json written") }
        let tools = model.tools
        let (feel, curve, smoothing) = (tools.pressureFeel, tools.personalCurve, tools.smoothing)
        model.apply()
        expect(tools.pressureFeel == .personal && tools.personalCurve == r.curve && tools.smoothing == r.smoothing, "apply sets personal settings")
        // Restore the user's own settings: the self-test must never change real preferences.
        tools.personalCurve = curve; tools.smoothing = smoothing; tools.pressureFeel = feel
        window.makeKeyAndOrderFront(nil)
        // Faithful offscreen render of the results page (window snapshots can't capture SwiftUI text reliably).
        MainActor.assumeIsolated {
            let renderer = ImageRenderer(content: PenLabView(model: model, board: board, unscrolled: true)
                .frame(width: 1160, height: 680)
                .background(Color(nsColor: .windowBackgroundColor)))
            renderer.scale = 1
            if let cg = renderer.cgImage {
                try? PageRenderer.writePNG(cg, to: FileManager.default.temporaryDirectory.appendingPathComponent("inkwell-penlab-render.png"))
            }
        }
        FileHandle.standardError.write("penlab-window: \(window.windowNumber)\n".data(using: .utf8)!)
        // Long enough for an external `screencapture -l` of the real window.
        RunLoop.current.run(until: Date().addingTimeInterval(ProcessInfo.processInfo.environment["INKWELL_HOLD"].flatMap(Double.init) ?? 1.5))
        return fails
    }

    static func write(on pv: PageView, in window: NSWindow, canvas: CanvasView, tools: ToolState) {
        func stroke(_ f: (Double) -> (CGFloat, CGFloat, Float), n: Int = 90) {
            gesture(0, on: pv, in: window, canvas: canvas, n: n, f)
        }
        tools.tool = .pen
        tools.penColor = ToolState.penPalette[0]
        // Cursive-ish loops on the ruled lines.
        stroke { u in (CGFloat(100 + u * 380), CGFloat(140 + sin(u * .pi * 9) * 14), 0.7) }
        tools.penColor = ToolState.penPalette[1]
        stroke { u in let a = u * .pi * 5; return (CGFloat(180 + cos(a) * (10 + u * 40)), CGFloat(260 + sin(a) * (10 + u * 40)), 0.6) }
        tools.penColor = ToolState.penPalette[2]
        stroke { u in (CGFloat(320 + u * 200), CGFloat(300 - sin(u * .pi) * 60), 0.8) }
        tools.tool = .highlighter
        stroke { u in (CGFloat(96 + u * 390), CGFloat(140 + u * 2), 0.5) }
        tools.tool = .pen
    }
}
