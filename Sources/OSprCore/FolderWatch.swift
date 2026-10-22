import Foundation

public struct FolderWatchSettings: Codable, Sendable {
    public var enabled = false
    public var directory = ""
    public var ignoreExisting = true
    public init() {}
}

public struct MediaCandidate: Equatable, Sendable {
    public var url: URL
    public var bytes: Int
    public var modified: Date
    public var fingerprint: String { "\(url.lastPathComponent.utf8.count):\(url.lastPathComponent):\(bytes):\(modified.timeIntervalSince1970)" }
    public init(url: URL, bytes: Int, modified: Date) { self.url = url; self.bytes = bytes; self.modified = modified }
    public static func scan(directory: URL) throws -> [MediaCandidate] {
        let extensions: Set<String> = ["wav", "flac", "mp3", "m4a", "mp4", "mov", "webm", "ogg", "aac", "aiff", "caf", "opus"]
        return try FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey], options: [.skipsHiddenFiles])
            .filter { extensions.contains($0.pathExtension.lowercased()) }
            .compactMap { url in
                let attributes = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey])
                guard attributes.isRegularFile == true, attributes.isSymbolicLink != true,
                      let bytes = attributes.fileSize, let modified = attributes.contentModificationDate else { return nil }
                return MediaCandidate(url: url, bytes: bytes, modified: modified)
            }.sorted { $0.url.lastPathComponent < $1.url.lastPathComponent }
    }
}

/// Poll stability twice and deduplicate by source metadata. Failed files back off;
/// changed files are a new candidate. No uploads or recursive directory traversal.
public struct FolderWatchQueue {
    private var observed: Set<String> = []
    private var retryAfter: [String: Date] = [:]
    public private(set) var completed: [String: Date]
    public init(completed: [String: Date] = [:]) { self.completed = completed }
    public mutating func ready(_ files: [MediaCandidate], now: Date = Date()) -> [MediaCandidate] {
        let current = Set(files.map(\.fingerprint))
        // Prune files that left the directory, never still-present completed
        // files: a fixed ledger cap would reprocess old audio in a loop.
        completed = completed.filter { current.contains($0.key) }
        defer { observed = current; retryAfter = retryAfter.filter { current.contains($0.key) } }
        return files.filter { file in
            file.bytes > 0 && observed.contains(file.fingerprint) && completed[file.fingerprint] == nil &&
            now.timeIntervalSince(file.modified) >= 2 && (retryAfter[file.fingerprint] ?? .distantPast) <= now
        }
    }
    public mutating func finish(_ file: MediaCandidate, success: Bool, now: Date = Date()) {
        if success { completed[file.fingerprint] = now } else { retryAfter[file.fingerprint] = now.addingTimeInterval(60) }

    }
    public mutating func ignore(_ files: [MediaCandidate], now: Date = Date()) {
        for file in files { finish(file, success: true, now: now) }
    }
}
