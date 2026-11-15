import Foundation

/// Inkwell notebook file (`.inkwell`), version 2 (version 3 = password-protected). All integers little-endian.
/// v2 added page elements (text, images, links), PDF backgrounds, assets and search text; v1 files
/// read as v2 with those empty. v1 readers refuse v2 files, so they can never save and drop the new data.
///
///     0  "INKW"            magic
///     4  u16 version       readers refuse versions newer than they understand
///     6  u16 flags         bit 0: payload encrypted (see NotebookCrypto); written as version 3
///     8  u32 metaLength
///    12  u32 payloadLength
///    16  u32 crc32         over meta + payload
///    20  meta              JSON NotebookMetadata (uncompressed, for fast library listing)
///     …  payload           LZFSE-compressed binary property list of Notebook
enum NotebookCodec {
    static let magic = Data("INKW".utf8)
    /// Newest format this build reads. Plain notebooks are written as 2; locked ones as 3, so builds that
    /// predate encryption refuse them cleanly instead of failing to decompress.
    static let version: UInt16 = 3
    static let plainVersion: UInt16 = 2
    static let flagEncrypted: UInt16 = 1
    static let headerSize = 20
    /// Guards against absurd lengths in damaged headers before allocating.
    static let maxSectionSize = 1 << 30
    static let maxMetadataSize = 8 << 20

    enum CodecError: LocalizedError, Equatable {
        case notANotebook
        case newerVersion(UInt16)
        case truncated
        case checksumMismatch
        case undecodable(String)
        case locked

        var errorDescription: String? {
            switch self {
            case .locked: return "This notebook is locked with a password."
            case .notANotebook: return "This file isn’t an Inkwell notebook."
            case .newerVersion(let v): return "This notebook was saved by a newer version of Inkwell (format \(v)). Update Inkwell to open it."
            case .truncated: return "The notebook file is incomplete."
            case .checksumMismatch: return "The notebook file is damaged (checksum mismatch)."
            case .undecodable(let why): return "The notebook couldn’t be read: \(why)"
            }
        }
    }

    static func encode(_ notebook: Notebook, password: String? = nil) throws -> Data {
        var metadata = notebook.metadata
        let encrypted = !(password ?? "").isEmpty
        if encrypted {
            metadata.pageTexts = nil // search text would leak the contents
            metadata.locked = true
        }
        let meta = try JSONEncoder.inkwell.encode(metadata)
        let plist = PropertyListEncoder()
        plist.outputFormat = .binary
        let raw = try plist.encode(notebook)
        var payload = try (raw as NSData).compressed(using: .lzfse) as Data
        if encrypted, let pw = password { payload = try NotebookCrypto.seal(payload, password: pw) }

        var out = Data(capacity: headerSize + meta.count + payload.count)
        out.append(magic)
        out.appendLE(encrypted ? version : plainVersion)
        out.appendLE(encrypted ? flagEncrypted : UInt16(0))
        out.appendLE(UInt32(meta.count))
        out.appendLE(UInt32(payload.count))
        var body = meta
        body.append(payload)
        out.appendLE(CRC32.checksum(body))
        out.append(body)
        return out
    }

    struct Header {
        var version: UInt16
        var flags: UInt16
        var metaLength: Int
        var payloadLength: Int
        var crc: UInt32
    }

    static func readHeader(_ data: Data) throws -> Header {
        guard data.count >= 4, data.prefix(4) == magic else { throw CodecError.notANotebook }
        guard data.count >= headerSize else { throw CodecError.truncated }
        let v: UInt16 = data.readLE(at: 4)
        guard v <= version else { throw CodecError.newerVersion(v) }
        guard v >= 1 else { throw CodecError.notANotebook }
        let metaLen = Int(data.readLE(at: 8) as UInt32)
        let payLen = Int(data.readLE(at: 12) as UInt32)
        guard metaLen <= maxSectionSize, payLen <= maxSectionSize else { throw CodecError.truncated }
        return Header(version: v, flags: data.readLE(at: 6), metaLength: metaLen, payloadLength: payLen, crc: data.readLE(at: 16))
    }

    static func decodeMetadata(_ data: Data) throws -> NotebookMetadata {
        let h = try readHeader(data)
        let start = data.startIndex + headerSize
        guard data.count >= headerSize + h.metaLength else { throw CodecError.truncated }
        do {
            return try JSONDecoder.inkwell.decode(NotebookMetadata.self, from: data[start..<(start + h.metaLength)])
        } catch {
            throw CodecError.undecodable("metadata")
        }
    }

    /// Header, lengths and checksum are all good (doesn't decrypt or decode).
    static func isIntact(_ data: Data) -> Bool {
        guard let h = try? readHeader(data) else { return false }
        let total = headerSize + h.metaLength + h.payloadLength
        guard data.count >= total else { return false }
        return CRC32.checksum(data[(data.startIndex + headerSize)..<(data.startIndex + total)]) == h.crc
    }

    static func isEncrypted(_ data: Data) -> Bool {
        ((try? readHeader(data))?.flags ?? 0) & flagEncrypted != 0
    }

    static func decode(_ data: Data, password: String? = nil) throws -> Notebook {
        let h = try readHeader(data)
        let total = headerSize + h.metaLength + h.payloadLength
        guard data.count >= total else { throw CodecError.truncated }
        let body = data[(data.startIndex + headerSize)..<(data.startIndex + total)]
        guard CRC32.checksum(body) == h.crc else { throw CodecError.checksumMismatch }
        var payload = Data(body.suffix(h.payloadLength))
        if h.flags & flagEncrypted != 0 {
            guard let pw = password, !pw.isEmpty else { throw CodecError.locked }
            payload = try NotebookCrypto.open(payload, password: pw) // throws .wrongPassword
        }
        do {
            let raw = try (Data(payload) as NSData).decompressed(using: .lzfse) as Data
            return try PropertyListDecoder().decode(Notebook.self, from: raw)
        } catch {
            throw CodecError.undecodable(error.localizedDescription)
        }
    }
}

/// Reads and writes notebooks in a library folder. Thread-safe: all file work runs on one serial queue.
final class LibraryStore {
    static let fileExtension = "inkwell"

    let folder: URL
    private let queue = DispatchQueue(label: "inkwell.library.io", qos: .userInitiated)
    private let fm = FileManager.default

    init(folder: URL) throws {
        self.folder = folder
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    static func defaultFolder() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Inkwell/Notebooks", isDirectory: true)
    }

    /// iCloud Drive's Inkwell folder, or nil when iCloud Drive is off on this Mac.
    static func iCloudFolder() -> URL? {
        let docs = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        guard FileManager.default.fileExists(atPath: docs.path) else { return nil }
        return docs.appendingPathComponent("Inkwell", isDirectory: true)
    }

    /// Google Drive for desktop's "My Drive"/Inkwell, or nil when Google Drive isn't installed and signed in.
    static func googleDriveFolder() -> URL? {
        let cloud = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/CloudStorage", isDirectory: true)
        let mounts = (try? FileManager.default.contentsOfDirectory(at: cloud, includingPropertiesForKeys: nil)) ?? []
        guard let drive = mounts.filter({ $0.lastPathComponent.hasPrefix("GoogleDrive-") }).sorted(by: { $0.path < $1.path }).first else { return nil }
        let myDrive = drive.appendingPathComponent("My Drive", isDirectory: true)
        let base = FileManager.default.fileExists(atPath: myDrive.path) ? myDrive : drive
        return base.appendingPathComponent("Inkwell", isDirectory: true)
    }

    struct MoveReport { var moved = 0; var keptNewer = 0; var failed: [String] = [] }

    /// Moves every notebook (and backups and the folder index) into `dest`. When a notebook exists in
    /// both places, the more recently modified copy wins and the other is kept as a .bak.
    static func moveLibrary(from src: URL, to dest: URL) -> MoveReport {
        var report = MoveReport()
        let fm = FileManager.default
        do { try fm.createDirectory(at: dest, withIntermediateDirectories: true) } catch { report.failed.append(error.localizedDescription); return report }
        let files = (try? fm.contentsOfDirectory(at: src, includingPropertiesForKeys: nil)) ?? []
        for f in files where f.pathExtension == fileExtension || f.lastPathComponent.hasSuffix(".\(fileExtension).bak") || f.lastPathComponent == "folders.json" {
            let target = dest.appendingPathComponent(f.lastPathComponent)
            do {
                if fm.fileExists(atPath: target.path) {
                    func modified(_ u: URL) -> Date {
                        (try? Data(contentsOf: u)).flatMap { try? NotebookCodec.decodeMetadata($0).modified } ?? .distantPast
                    }
                    if f.pathExtension == fileExtension && modified(f) > modified(target) {
                        let bak = dest.appendingPathComponent(f.lastPathComponent + ".bak")
                        try? fm.removeItem(at: bak)
                        try fm.moveItem(at: target, to: bak)
                        try fm.moveItem(at: f, to: target)
                        report.moved += 1
                    } else {
                        report.keptNewer += 1 // destination copy is newer (or not a notebook): leave the source in place
                    }
                } else {
                    try fm.moveItem(at: f, to: target)
                    if f.pathExtension == fileExtension { report.moved += 1 }
                }
            } catch {
                report.failed.append("\(f.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return report
    }

    func url(for id: UUID) -> URL { folder.appendingPathComponent("\(id.uuidString).\(Self.fileExtension)") }
    private func backupURL(for id: UUID) -> URL { folder.appendingPathComponent("\(id.uuidString).\(Self.fileExtension).bak") }

    struct Listing {
        var notebooks: [NotebookMetadata]
        /// Files that couldn't be read at all, with the reason, so the UI can say so instead of hiding them.
        var problems: [(file: String, reason: String)]
    }

    /// Lists notebooks newest-first using only each file's metadata block.
    func list() -> Listing {
        queue.sync {
            var items: [NotebookMetadata] = []
            var problems: [(String, String)] = []
            let files = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            // iCloud placeholders (".<name>.inkwell.icloud"): ask iCloud to download them; they appear once ready.
            for file in files where file.lastPathComponent.hasPrefix(".") && file.lastPathComponent.hasSuffix(".\(Self.fileExtension).icloud") {
                try? fm.startDownloadingUbiquitousItem(at: file)
            }
            for file in files where file.pathExtension == Self.fileExtension {
                do {
                    let head = try readPrefix(of: file, maxBytes: NotebookCodec.maxMetadataSize)
                    var meta = try NotebookCodec.decodeMetadata(head)
                    // The file name is authoritative: a renamed copy must not alias another notebook.
                    if let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent) { meta.id = id }
                    items.append(meta)
                } catch {
                    // Fall back to the backup's metadata so a damaged notebook still appears and can be recovered.
                    if let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent),
                       let bak = try? readPrefix(of: backupURL(for: id), maxBytes: NotebookCodec.maxMetadataSize),
                       var meta = try? NotebookCodec.decodeMetadata(bak) {
                        meta.id = id
                        items.append(meta)
                    } else {
                        problems.append((file.lastPathComponent, error.localizedDescription))
                    }
                }
            }
            items.sort { $0.modified > $1.modified }
            return Listing(notebooks: items, problems: problems)
        }
    }

    struct Loaded {
        var notebook: Notebook
        /// True when the main file was damaged and the previous good save was used instead.
        var recoveredFromBackup: Bool
    }

    func load(id: UUID, password: String? = nil) throws -> Loaded {
        try queue.sync {
            do {
                var nb = try NotebookCodec.decode(Data(contentsOf: url(for: id)), password: password)
                nb.id = id
                return Loaded(notebook: nb, recoveredFromBackup: false)
            } catch let mainError {
                // Never silently use a backup for a version or password problem: the main file is fine.
                if case NotebookCodec.CodecError.newerVersion = mainError { throw mainError }
                if case NotebookCodec.CodecError.locked = mainError { throw mainError }
                if mainError as? NotebookCrypto.CryptoError == .wrongPassword { throw mainError }
                guard let bak = try? Data(contentsOf: backupURL(for: id)), var nb = try? NotebookCodec.decode(bak, password: password) else {
                    throw mainError
                }
                nb.id = id
                return Loaded(notebook: nb, recoveredFromBackup: true)
            }
        }
    }

    /// Saves atomically. The previous file is kept as `.bak` only if it is itself valid, so a damaged
    /// file can never overwrite the last good backup.
    func save(_ notebook: Notebook, password: String? = nil) throws {
        let data = try NotebookCodec.encode(notebook, password: password)
        try queue.sync {
            let dest = url(for: notebook.id)
            // Checksum-level validation: works for locked files too, without needing their password.
            if let existing = try? Data(contentsOf: dest), NotebookCodec.isIntact(existing) {
                try? existing.write(to: backupURL(for: notebook.id), options: .atomic)
            }
            try data.write(to: dest, options: .atomic)
        }
    }

    /// Copies a `.inkwell` file from elsewhere into the library. Keeps the notebook's id unless the library
    /// already has that id, in which case the copy gets a new one (the file name is authoritative).
    func importNotebookFile(_ src: URL) throws -> UUID {
        let data = try Data(contentsOf: src)
        guard NotebookCodec.isIntact(data) else { throw NotebookCodec.CodecError.checksumMismatch }
        _ = try NotebookCodec.decodeMetadata(data)
        var id = UUID(uuidString: src.deletingPathExtension().lastPathComponent) ?? UUID()
        if exists(id: id) {
            if (try? Data(contentsOf: url(for: id))) == data { return id } // same file: already in the library
            id = UUID()
        }
        try queue.sync { try data.write(to: url(for: id), options: .atomic) }
        return id
    }

    /// Moves a notebook (and its backup) to the Trash so deletion can be undone from Finder.
    func trash(id: UUID) throws {
        try queue.sync {
            for u in [url(for: id), backupURL(for: id)] where fm.fileExists(atPath: u.path) {
                try fm.trashItem(at: u, resultingItemURL: nil)
            }
        }
    }

    func exists(id: UUID) -> Bool { queue.sync { fm.fileExists(atPath: url(for: id).path) } }

    private func readPrefix(of url: URL, maxBytes: Int) throws -> Data {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        let head = try h.read(upToCount: NotebookCodec.headerSize) ?? Data()
        // Read exactly header + metadata when the header is sane; otherwise just the cap.
        if let header = try? NotebookCodec.readHeader(head) {
            let rest = try h.read(upToCount: min(header.metaLength, maxBytes)) ?? Data()
            return head + rest
        }
        return head
    }
}

// MARK: - Small binary helpers

enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func checksum<D: DataProtocol>(_ data: D) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for region in data.regions {
            region.withUnsafeBytes { buf in
                for b in buf { crc = table[Int((crc ^ UInt32(b)) & 0xFF)] ^ (crc >> 8) }
            }
        }
        return crc ^ 0xFFFF_FFFF
    }
}

extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ v: T) {
        Swift.withUnsafeBytes(of: v.littleEndian) { append(contentsOf: $0) }
    }

    func readLE<T: FixedWidthInteger>(at offset: Int) -> T {
        var v: T = 0
        let range = (startIndex + offset)..<(startIndex + offset + MemoryLayout<T>.size)
        Swift.withUnsafeMutableBytes(of: &v) { dst in _ = copyBytes(to: dst, from: range) }
        return T(littleEndian: v)
    }
}

extension JSONEncoder {
    static var inkwell: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        return e
    }
}

extension JSONDecoder {
    static var inkwell: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }
}
