import Foundation

/// Library folders. Stored as `folders.json` beside the notebooks; a notebook is in at most one folder,
/// and notebooks not in any folder simply show under "All Notebooks".
struct LibraryFolder: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var notebooks: [UUID] = []

    static func cleanName(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: .controlCharacters).joined()
        return t.isEmpty ? "Untitled Folder" : String(t.prefix(80))
    }
}

struct LibraryFolders: Codable, Equatable {
    var folders: [LibraryFolder] = []

    /// Removes duplicate folders/ids, keeps each notebook in its first folder only, and drops notebooks
    /// that no longer exist (when `existing` is given).
    mutating func sanitize(existing: Set<UUID>? = nil) {
        var seenFolders = Set<UUID>(), seenNotebooks = Set<UUID>()
        folders = folders.compactMap { f in
            guard seenFolders.insert(f.id).inserted else { return nil }
            var g = f
            g.name = LibraryFolder.cleanName(f.name)
            g.notebooks = f.notebooks.filter { (existing?.contains($0) ?? true) && seenNotebooks.insert($0).inserted }
            return g
        }
    }

    func folder(of notebook: UUID) -> UUID? { folders.first { $0.notebooks.contains(notebook) }?.id }

    mutating func move(_ notebook: UUID, to folder: UUID?) {
        for i in folders.indices { folders[i].notebooks.removeAll { $0 == notebook } }
        if let folder, let i = folders.firstIndex(where: { $0.id == folder }) { folders[i].notebooks.append(notebook) }
    }
}

extension LibraryStore {
    private var foldersURL: URL { folder.appendingPathComponent("folders.json") }

    /// Missing or unreadable index → no folders (notebooks are never lost; they show under All).
    func loadFolders() -> LibraryFolders {
        guard let data = try? Data(contentsOf: foldersURL), var f = try? JSONDecoder().decode(LibraryFolders.self, from: data) else {
            return LibraryFolders()
        }
        f.sanitize()
        return f
    }

    func saveFolders(_ f: LibraryFolders) throws {
        var clean = f
        clean.sanitize()
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(clean).write(to: foldersURL, options: .atomic)
    }
}
