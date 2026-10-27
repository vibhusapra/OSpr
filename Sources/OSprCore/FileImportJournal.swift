import Darwin
import Foundation

/// Recognition/writing settings only. No keys, focused fields, audio, profiles,
/// microphone IDs, checkout paths or unrelated capture preferences are retained.
public struct FileImportSnapshot: Codable, Sendable {
    public let version: Int
    public var batch: FileImportBatch
    public let settings: OSprSettings
    public init(batch: FileImportBatch, settings: OSprSettings) {
        version = 1; self.batch = batch
        var saved = OSprSettings()
        saved.model = settings.model; saved.language = settings.language; saved.mode = settings.mode
        saved.transcriptionProvider = settings.transcriptionProvider; saved.transcriptionURL = settings.transcriptionURL
        saved.transcriptionModel = settings.transcriptionModel
        saved.rewriteProvider = settings.rewriteProvider; saved.rewriteURL = settings.rewriteURL; saved.rewriteModel = settings.rewriteModel
        saved.customPrompt = settings.customPrompt; saved.translationLanguage = settings.translationLanguage
        saved.vocabulary = settings.vocabulary; saved.replacements = settings.replacements
        saved.spokenPunctuation = settings.spokenPunctuation; saved.silenceTrim = settings.silenceTrim
        saved.neuralEdgeTrim = settings.neuralEdgeTrim; saved.silenceThreshold = settings.silenceThreshold
        saved.speakerLabels = settings.speakerLabels; saved.keepAudio = settings.keepAudio; saved.audioBudgetMB = settings.audioBudgetMB
        saved.autoPaste = false
        self.settings = saved.validated()
    }
    public var needsProviderConfirmation: Bool {
        if settings.transcriptionProvider != "local" { return true }
        if settings.mode == .verbatim || ["none", "local", "local-9b"].contains(settings.rewriteProvider) { return false }
        let host = URL(string: settings.rewriteURL)?.host?.lowercased() ?? ""
        return !["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)
    }
    /// A recovery decision needs the actual saved destination and model. Never
    /// echo credentials/query strings from an invalid endpoint into the UI.
    public static func providerDescription(for config: OSprSettings) -> String {
        func remote(_ provider: String, _ base: String, _ model: String) -> String {
            let endpoint = (try? ProviderClient.endpoint(base: base, path: ""))?.absoluteString ?? "invalid saved endpoint"
            return provider + " · " + endpoint + " · " + (model.isEmpty ? "model not set" : model)
        }
        let speech = config.transcriptionProvider == "local" ? "Local · \(config.model)"
            : remote(config.transcriptionProvider, config.transcriptionURL, config.transcriptionModel)
        let rewrite: String
        if config.mode == .verbatim || config.rewriteProvider == "none" { rewrite = "off" }
        else if ["local", "local-9b"].contains(config.rewriteProvider) { rewrite = config.rewriteProvider }
        else { rewrite = remote(config.rewriteProvider, config.rewriteURL, config.rewriteModel) }
        return speech + " · " + config.mode.title + " · rewrite: " + rewrite
    }
    public var providerDescription: String { Self.providerDescription(for: settings) }
    public func validate() throws {
        guard version == 1 else { throw OSprError.message("The saved import queue needs a newer OSpr. It was preserved.") }
        let rows = batch.items
        guard !rows.isEmpty, rows.count <= 10_000,
              Set(rows.map(\.id)).count == rows.count, Set(rows.map(\.resultID)).count == rows.count,
              batch.created.timeIntervalSinceReferenceDate.isFinite, batch.updated.timeIntervalSinceReferenceDate.isFinite,
              rows.allSatisfy({ $0.url.isFileURL && $0.url.path.hasPrefix("/") && ($0.url.host == nil || $0.url.host == "localhost") && ($0.transcriptID == nil || $0.transcriptID == $0.resultID) }) else {
            throw OSprError.message("The saved import queue is invalid. It was preserved; dismiss it before starting a new batch.")
        }
    }
}

/// One owner-only latest batch. All IO belongs to this actor, never the UI
/// executor. Revision fencing prevents an older cancel/save task resurrecting
/// metadata after a privacy clear, dismissal or replacement by a newer batch.
/// The application owner must retain AppInstanceLock for this directory.
public actor FileImportJournal {
    public static let fileName = "file-import.json"
    private static let maximumBytes = 8 * 1024 * 1024
    private let directory: URL
    private let beforePublish: @Sendable () throws -> Void
    private var revision: UInt64 = 0
    private var inspected = false
    private var protected = false
    public init(directory: URL) { self.directory = directory; beforePublish = {} }
    init(directory: URL, beforePublish: @escaping @Sendable () throws -> Void) {
        self.directory = directory; self.beforePublish = beforePublish
    }
    private var url: URL { directory.appendingPathComponent(Self.fileName) }

    public func load() throws -> FileImportSnapshot? {
        inspected = true
        do {
            try cleanOrphanStages()
            let fd = Darwin.open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
            if fd < 0, errno == ENOENT { protected = false; return nil }
            guard fd >= 0 else { throw failure() }
            let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            defer { try? file.close() }
            var metadata = stat()
            guard fstat(fd, &metadata) == 0, metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
                  metadata.st_size <= Self.maximumBytes else { throw failure() }
            let data = try file.read(upToCount: Self.maximumBytes + 1) ?? Data()
            guard data.count <= Self.maximumBytes else { throw failure() }
            let snapshot = try JSONDecoder().decode(FileImportSnapshot.self, from: data)
            try snapshot.validate(); protected = false
            return snapshot
        } catch { protected = true; throw OSprError.message("Import recovery could not be read. The saved queue was preserved; dismiss it to start a new batch.") }
    }

    @discardableResult public func save(_ snapshot: FileImportSnapshot, revision next: UInt64) throws -> Bool {
        guard next > revision else { return false }; revision = next
        if !inspected { _ = try load() }
        guard !protected else { throw failure() }
        try snapshot.validate()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(snapshot)
        guard data.count <= Self.maximumBytes else { throw OSprError.message("This import queue is too large to recover. Split it into smaller batches.") }
        _ = try LocalStore(directory: directory)
        try requireRegularFileIfPresent()
        let stage = directory.appendingPathComponent(".import-batch-stage-v1-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: stage) }
        let payload = stage.appendingPathComponent("payload")
        let fd = Darwin.open(payload.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw failure() }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? file.close() }
        try file.write(contentsOf: data); try file.synchronize()
        try beforePublish()
        try requireRegularFileIfPresent()
        guard Darwin.rename(payload.path, url.path) == 0 else { throw failure() }
        return true
    }

    @discardableResult public func clear(revision next: UInt64) throws -> Bool {
        guard next > revision else { return false }; revision = next
        try cleanOrphanStages()
        if try requireRegularFileIfPresent() {
            guard Darwin.unlink(url.path) == 0 else { throw failure() }
        }
        inspected = true; protected = false
        return true
    }

    private func cleanOrphanStages() throws {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        for child in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            let prefix = ".import-batch-stage-v1-"
            guard child.lastPathComponent.hasPrefix(prefix), UUID(uuidString: String(child.lastPathComponent.dropFirst(prefix.count))) != nil else { continue }
            var attributes = stat()
            guard lstat(child.path, &attributes) == 0, attributes.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else { throw failure() }
            let entries = try FileManager.default.contentsOfDirectory(atPath: child.path)
            guard entries.isEmpty || entries == ["payload"] else { throw failure() }
            if !entries.isEmpty {
                let payload = child.appendingPathComponent("payload")
                guard lstat(payload.path, &attributes) == 0, attributes.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
                      Darwin.unlink(payload.path) == 0 else { throw failure() }
            }
            guard Darwin.rmdir(child.path) == 0 else { throw failure() }
        }
    }

    @discardableResult private func requireRegularFileIfPresent() throws -> Bool {
        var metadata = stat()
        if lstat(url.path, &metadata) == 0 {
            guard metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { throw failure() }
            return true
        }
        if errno == ENOENT { return false }
        throw failure()
    }
    private func failure() -> OSprError {
        OSprError.message("Import recovery could not be saved or cleared. Existing data was preserved; check local storage and retry.")
    }
}
