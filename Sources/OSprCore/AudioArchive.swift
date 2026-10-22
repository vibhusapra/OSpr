import Foundation

public struct ArchivedAudio: Sendable {
    public let name: String
    public let url: URL
    public let bytes: Int64
    public let evicted: Set<String>
}

/// OSpr-owned snapshots only. Active inference leases survive quota/prune work;
/// callers release or discard them after committing the associated transcript.
public actor AudioArchive {
    public nonisolated let directory: URL
    private var leased = Set<String>()
    private let formats: Set<String> = ["wav"]
    private let uploadFormats: Set<String> = ["wav", "mp3", "m4a", "flac", "ogg", "opus", "aac", "aif", "aiff"]
    private struct Entry { let name: String; let url: URL; let bytes: Int64; let date: Date }

    public init(directory: URL) throws {
        self.directory = directory
        guard directory.isFileURL else { throw OSprError.message("Audio storage requires a local directory.") }
        // Optional audio storage must not prevent the app from opening when its
        // folder needs repair. Filesystem checks run on the actor at first use.
    }

    private func checkRoot() throws {
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        let values = try directory.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        guard values.isSymbolicLink != true, values.isDirectory == true else { throw OSprError.message("Audio archive directory changed; no files were modified.") }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }
    private func owned(_ name: String) -> Bool {
        let url = URL(fileURLWithPath: name)
        return name == url.lastPathComponent && formats.contains(url.pathExtension) && UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil
    }
    private func entries() throws -> [Entry] {
        try checkRoot()
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey], options: [.skipsHiddenFiles]).compactMap { url in
            guard owned(url.lastPathComponent) else { return nil }
            let value = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey])
            guard value.isRegularFile == true, value.isSymbolicLink != true else { return nil }
            return Entry(name: url.lastPathComponent, url: url, bytes: Int64(value.fileSize ?? 0), date: value.contentModificationDate ?? .distantPast)
        }
    }

    public func newStagingURL() throws -> URL {
        try checkRoot()
        return directory.appendingPathComponent(".stage-" + UUID().uuidString + ".wav")
    }
    /// Short-lived copy for a compliant compressed BYOK upload. Normalization
    /// and upload consume the same immutable source; it never becomes history.
    public func snapshotUploadSource(_ source: URL, limitBytes: Int64) throws -> URL? {
        try checkRoot(); try Task.checkCancellation()
        guard source.isFileURL else { throw OSprError.message("Upload snapshots require a local file.") }
        let input = source.resolvingSymlinksInPath()
        guard uploadFormats.contains(input.pathExtension.lowercased()) else { return nil }
        let values = try input.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, let bytes = values.fileSize, bytes > 0, Int64(bytes) < limitBytes else { return nil }
        let output = directory.appendingPathComponent(".source-" + UUID().uuidString + "." + input.pathExtension.lowercased())
        do {
            try FileManager.default.copyItem(at: input, to: output)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: output.path)
            try Task.checkCancellation()
            guard Int64(try output.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) < limitBytes else { throw OSprError.message("Source grew beyond the upload limit while copying.") }
            return output
        } catch { try? FileManager.default.removeItem(at: output); throw error }
    }
    public func discardUploadSource(_ url: URL) throws {
        try checkRoot()
        let name = url.deletingPathExtension().lastPathComponent
        guard url.isFileURL, url.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL,
              uploadFormats.contains(url.pathExtension), name.hasPrefix(".source-"), UUID(uuidString: String(name.dropFirst(8))) != nil else { throw OSprError.message("Invalid private upload snapshot path.") }
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
    private func validStaging(_ url: URL) -> Bool {
        let name = url.deletingPathExtension().lastPathComponent
        return url.isFileURL && url.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL && url.pathExtension == "wav" && name.hasPrefix(".stage-") && UUID(uuidString: String(name.dropFirst(7))) != nil
    }
    public func discardStaging(_ url: URL) throws {
        try checkRoot()
        guard validStaging(url) else { throw OSprError.message("Invalid audio staging path.") }
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
    public func adoptPrepared(_ staging: URL, id: UUID, limitBytes: Int64) throws -> ArchivedAudio {
        try checkRoot(); try Task.checkCancellation()
        guard validStaging(staging), limitBytes > 0 else { throw OSprError.message("Invalid prepared audio path or budget.") }
        let value = try staging.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        let size = Int64(value.fileSize ?? 0)
        guard value.isRegularFile == true, value.isSymbolicLink != true, size > 0, size <= limitBytes else { throw OSprError.message("Prepared audio is invalid or exceeds the storage budget.") }
        let active = try entries().filter { leased.contains($0.name) }.reduce(Int64(0)) { $0 + $1.bytes }
        guard active <= limitBytes - size else { throw OSprError.message("Active recordings occupy this audio budget; retry after they finish.") }
        let name = id.uuidString.lowercased() + ".wav"
        let destination = directory.appendingPathComponent(name)
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw OSprError.message("Retained recording ID already exists.") }
        try FileManager.default.setAttributes([.posixPermissions: 0o600, .modificationDate: Date()], ofItemAtPath: staging.path)
        try FileManager.default.moveItem(at: staging, to: destination)
        leased.insert(name)
        do { return ArchivedAudio(name: name, url: destination, bytes: size, evicted: try trimToBudget(limitBytes)) }
        catch { leased.remove(name); try? FileManager.default.removeItem(at: destination); throw error }
    }

    public func eraseAll() throws {
        try checkRoot()
        let names = Set(try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).map(\.lastPathComponent).filter { owned($0) })
        try remove(names)
        _ = try reconcile(keeping: [], limitBytes: 0)
    }

    public func resolve(name: String, id: UUID) throws -> URL? {
        try checkRoot()
        guard owned(name), URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent.lowercased() == id.uuidString.lowercased() else { return nil }
        let url = directory.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let value = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        return value.isRegularFile == true && value.isSymbolicLink != true ? url : nil
    }

    public func finishLease(_ name: String, keep: Bool) throws {
        leased.remove(name)
        if !keep { try remove([name]) }
    }
    public func remove(_ names: Set<String>) throws {
        try checkRoot()
        for name in names where owned(name) {
            leased.remove(name)
            let url = directory.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        }
    }
    /// Run once at launch before admitting a recording. Preserve files when the
    /// history index could not be read; explicit deletion is handled separately.
    public func reconcile(keeping: Set<String>, limitBytes: Int64) throws -> Set<String> {
        let abandoned = Set(try entries().map(\.name)).subtracting(keeping).subtracting(leased)
        try remove(abandoned)
        // A previous crash can leave a staging copy. Only the private archive
        // owns these names; normal app admission waits for launch maintenance.
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isSymbolicLinkKey]) where url.lastPathComponent.hasPrefix(".stage-") && url.pathExtension == "wav" {
            let stem = url.deletingPathExtension().lastPathComponent.dropFirst(7)
            if UUID(uuidString: String(stem)) != nil { try FileManager.default.removeItem(at: url) }
        }
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) where url.lastPathComponent.hasPrefix(".source-") && uploadFormats.contains(url.pathExtension) {
            let stem = url.deletingPathExtension().lastPathComponent.dropFirst(8)
            if UUID(uuidString: String(stem)) != nil { try discardUploadSource(url) }
        }
        return try abandoned.union(trimToBudget(limitBytes))
    }
    public func trimToBudget(_ limitBytes: Int64) throws -> Set<String> {
        let all = try entries().sorted { $0.date == $1.date ? $0.name < $1.name : $0.date < $1.date }
        let active = all.filter { leased.contains($0.name) }.reduce(Int64(0)) { $0 + $1.bytes }
        guard active <= max(0, limitBytes) else { throw OSprError.message("Active recordings exceed this audio budget; retry after they finish.") }
        var bytes = all.reduce(Int64(0)) { $0 + $1.bytes }
        var removed = Set<String>()
        for entry in all where bytes > max(0, limitBytes) && !leased.contains(entry.name) {
            try FileManager.default.removeItem(at: entry.url)
            removed.insert(entry.name); bytes -= entry.bytes
        }
        guard bytes <= max(0, limitBytes) else { throw OSprError.message("The audio budget is occupied by active recordings. Retry after they finish.") }
        return removed
    }
    public func bytesUsed() throws -> Int64 { try entries().reduce(0) { $0 + $1.bytes } }
}
