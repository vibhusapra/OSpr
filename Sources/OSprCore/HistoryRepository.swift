import Foundation

/// Serial asynchronous admission for paged history. Construction performs no IO;
/// the database, migration, queries, callbacks and commits run on a private queue.
/// The GUI must retain AppInstanceLock for this repository's lifetime.
public final class HistoryRepository: @unchecked Sendable {
    public struct WriteResult: Sendable {
        public let orphanedAudio: Set<String>
        public let failure: String?
    }
    public typealias Completion = @Sendable (WriteResult) -> Void
    private struct Pending {
        let ordinal: UInt64
        let record: Transcript? // nil is a tombstone, never a missing dictionary key.
    }
    private let queue = DispatchQueue(label: "app.ospr.history.repository", qos: .utility)
    private let queueKey = DispatchSpecificKey<Bool>()
    private let open: @Sendable () throws -> HistoryDatabase
    private let reset: @Sendable () throws -> HistoryDatabase
    private let beforeCommit: @Sendable () throws -> Void
    private var database: HistoryDatabase?
    private var pending: [UUID: Pending] = [:]
    private var ordinal: UInt64 = 0
    private var revision: UInt64 = 0
    private var clearRequested = false
    private var audioRemoval: HistoryAudioRemoval?
    private var maintenanceRequested = false
    private var retentionDays = 0
    private var completion: Completion?
    private var scheduled: DispatchWorkItem?

    public convenience init(directory: URL) {
        self.init(open: { try HistoryDatabase(directory: directory) },
                  reset: { try HistoryDatabase.reset(directory: directory) })
    }

    // Injectable boundaries for slow-open, ordering and failure tests. Both
    // closures must create/return connections confined to this repository.
    init(open: @escaping @Sendable () throws -> HistoryDatabase,
         reset: @escaping @Sendable () throws -> HistoryDatabase,
         beforeCommit: @escaping @Sendable () throws -> Void = {}) {
        self.open = open; self.reset = reset; self.beforeCommit = beforeCommit
        queue.setSpecific(key: queueKey, value: true)
    }

    deinit {
        // SQLite destruction also belongs off the UI executor. The queue owns
        // the last connection reference once this repository is released.
        let connection = database
        queue.async { withExtendedLifetime(connection) {} }
    }

    /// Coalesce repeated edits to an ID; preserve the first admission order of
    /// different new IDs. The latest completion observes the entire batch.
    /// On failure it is called again after an explicit successful flush/retry.
    public func submit(_ record: Transcript, delay: TimeInterval = 0, completion: Completion? = nil) {
        queue.async { [self] in
            admit(id: record.id, record: record)
            schedule(delay: delay, completion: completion)
        }
    }

    /// Mutate the latest complete payload on the queue, so a stale UI detail
    /// cannot restore evicted audio or overwrite newly generated notes.
    public func updateText(id: UUID, text: String, delay: TimeInterval = 0.3, completion: Completion? = nil) {
        update(id: id, delay: delay, completion: completion) { $0.text = text }
    }

    public func updateNotes(id: UUID, notes: MeetingNotes, expectedRawText: String, completion: Completion? = nil) {
        update(id: id, delay: 0, completion: completion) { record in
            guard record.rawText == expectedRawText, notes.matches(record.rawText) else {
                throw OSprError.message("The original transcript changed. Notes were not applied.")
            }
            record.notes = notes
        }
    }

    /// Deletion replaces any uncommitted edit with a retained tombstone. A failed
    /// commit cannot later resurrect that edit during flush or another save.
    public func remove(ids: [UUID], completion: Completion? = nil) {
        queue.async { [self] in
            for id in ids { admit(id: id, record: nil) }
            schedule(delay: 0, completion: completion)
        }
    }

    /// An explicit reset supersedes older pending changes, including failed ones.
    /// New admissions after this barrier survive in the cleared archive.
    public func clear(completion: Completion? = nil) {
        queue.async { [self] in
            pending.removeAll(); clearRequested = true; audioRemoval = nil
            schedule(delay: 0, completion: completion)
        }
    }

    public func setRetention(days: Int, completion: Completion? = nil) {
        queue.async { [self] in
            retentionDays = max(0, days); maintenanceRequested = true
            schedule(delay: 0, completion: completion)
        }
    }

    public func stripAudio(_ removal: HistoryAudioRemoval = .all, completion: Completion? = nil) {
        queue.async { [self] in
            switch (audioRemoval, removal) {
            case (.all?, _), (_, .all): audioRemoval = .all
            case (.names(let old)?, .names(let new)): audioRemoval = .names(old.union(new))
            case (nil, _): audioRemoval = removal
            }
            schedule(delay: 0, completion: completion)
        }
    }

    public func page(query: String = "", before: Int64? = nil, limit: Int = 100) async throws -> HistoryPage {
        try await read { try $0.page(query: query, before: before, limit: limit) }
    }
    public func statistics() async throws -> HistoryStatistics { try await read { try $0.statistics() } }
    public func audioFiles() async throws -> Set<String> { try await read { try $0.audioFiles() } }

    /// Read-your-edit without forcing a disk write per editor keystroke. Details
    /// are always a full Transcript, never reconstructed from a summary row.
    public func record(id: UUID) async throws -> Transcript? {
        try await perform { try self.currentRecord(id: id) }
    }

    /// Blocking quit barrier only. Normal UI paths must use flushAsync.
    @discardableResult public func flush() throws -> Set<String> {
        guard DispatchQueue.getSpecific(key: queueKey) == nil else {
            throw OSprError.message("Use flushAsync from a history callback; blocking flush cannot reenter the repository queue.")
        }
        return try queue.sync { scheduled?.cancel(); scheduled = nil; return try commitPending() }
    }

    @discardableResult public func flushAsync() async throws -> Set<String> {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                scheduled?.cancel(); scheduled = nil
                do { continuation.resume(returning: try commitPending()) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    private func read<T: Sendable>(_ operation: @escaping @Sendable (HistoryDatabase) throws -> T) async throws -> T {
        try await perform {
            _ = try self.commitPending()
            return try operation(self.connection())
        }
    }
    /// Skip queued obsolete searches/details and fence completed results. An
    /// already executing migration or SQL operation finishes safely; cancellation
    /// never interrupts a write transaction or discards admitted persistence.
    private func perform<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
        let cancellation = ReadCancellation()
        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    do {
                        try cancellation.check()
                        let result = try operation()
                        try cancellation.check()
                        continuation.resume(returning: result)
                    } catch { continuation.resume(throwing: error) }
                }
            }
        }, onCancel: { cancellation.cancel() })
    }
    private func admit(id: UUID, record: Transcript?) {
        ordinal &+= 1
        pending[id] = Pending(ordinal: pending[id]?.ordinal ?? ordinal, record: record)
    }
    private func currentRecord(id: UUID) throws -> Transcript? {
        var record: Transcript?
        if let value = pending[id] { record = value.record }
        else if !clearRequested { record = try connection().record(id: id) }
        if let name = record?.audioFile {
            switch audioRemoval {
            case .all?: record?.audioFile = nil
            case .names(let names)? where names.contains(name): record?.audioFile = nil
            default: break
            }
        }
        return record
    }
    private func update(id: UUID, delay: TimeInterval, completion: Completion?,
                        _ transform: @escaping @Sendable (inout Transcript) throws -> Void) {
        queue.async { [self] in
            do {
                guard var record = try currentRecord(id: id) else {
                    throw OSprError.message("This transcript was removed. The edit was not saved.")
                }
                try transform(&record)
                admit(id: id, record: record); schedule(delay: delay, completion: completion)
            } catch { completion?(WriteResult(orphanedAudio: [], failure: error.localizedDescription)) }
        }
    }
    private func schedule(delay: TimeInterval, completion: Completion?) {
        revision &+= 1; let token = revision
        self.completion = completion
        scheduled?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.revision == token else { return }
            _ = try? self.commitPending()
        }
        scheduled = work
        queue.asyncAfter(deadline: .now() + max(0, delay.isFinite ? delay : 0), execute: work)
    }
    private func connection() throws -> HistoryDatabase {
        if let database { return database }
        do { database = try open() }
        catch {
            guard clearRequested else { throw error }
            database = try reset()
        }
        return database!
    }
    @discardableResult private func commitPending() throws -> Set<String> {
        guard !pending.isEmpty || clearRequested || audioRemoval != nil || maintenanceRequested else { return [] }
        do {
            let database = try connection()
            try beforeCommit()
            let values = pending.values.sorted { $0.ordinal < $1.ordinal }.compactMap(\.record)
            let ids = pending.compactMap { $0.value.record == nil ? $0.key : nil }
            let removed = try database.apply(upserts: values, removing: ids, clear: clearRequested,
                stripAudio: audioRemoval, retentionDays: retentionDays)
            pending.removeAll(); clearRequested = false; audioRemoval = nil; maintenanceRequested = false
            let observer = completion; completion = nil
            observer?(WriteResult(orphanedAudio: removed, failure: nil))
            return removed
        } catch {
            completion?(WriteResult(orphanedAudio: [], failure: error.localizedDescription))
            throw error // Keep all pending edits, tombstones and policy requests.
        }
    }

    private final class ReadCancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        func cancel() { lock.lock(); cancelled = true; lock.unlock() }
        func check() throws {
            lock.lock(); let value = cancelled; lock.unlock()
            if value { throw CancellationError() }
        }
    }
}
