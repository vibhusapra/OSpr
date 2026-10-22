import Foundation

/// Serial, coalescing history writes. The JSON encoder belongs to this queue;
/// settings writes use a different LocalStore and never share encoder state.
/// Call flush before orderly termination to commit the newest admitted snapshot.
public final class HistoryPersistence: @unchecked Sendable {
    public typealias Completion = @Sendable (String?) -> Void
    private struct Pending {
        let revision: UInt64
        let items: [Transcript]
        let completion: Completion?
    }
    private let queue = DispatchQueue(label: "app.ospr.history", qos: .utility)
    private let write: @Sendable ([Transcript]) throws -> Void
    private let validate: @Sendable () throws -> Void
    private var revision: UInt64 = 0
    private var pending: Pending?
    private var scheduled: DispatchWorkItem?
    private var validated = false
    private var resetAuthorized = false
    private var committedWrites = 0
    private var failedWrites = 0

    public init(directory: URL) throws {
        // This instance is private to the persistence queue after initialization.
        let store = try LocalStore(directory: directory)
        write = { items in try store.write(items, name: "history.json") }
        validate = { _ = try store.read([Transcript].self, name: "history.json") }
    }

    // Injectable filesystem boundary for ordering, slow-write and failure tests.
    init(write: @escaping @Sendable ([Transcript]) throws -> Void,
         validate: @escaping @Sendable () throws -> Void = {}) {
        self.write = write; self.validate = validate
    }

    public func submit(_ items: [Transcript], delay: TimeInterval = 0,
                       allowReset: Bool = false, completion: Completion? = nil) {
        queue.async { [self] in
            revision &+= 1
            let current = revision
            // An explicit clear/disable remains authorized if a newer snapshot
            // arrives before its pending write; old data is never resurrected.
            resetAuthorized = resetAuthorized || allowReset
            pending = Pending(revision: current, items: items, completion: completion)
            scheduled?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.pending?.revision == current else { return }
                _ = try? self.commitPending()
            }
            scheduled = work
            queue.asyncAfter(deadline: .now() + max(0, delay.isFinite ? delay : 0), execute: work)
        }
    }

    public func flush() throws {
        try queue.sync {
            scheduled?.cancel(); scheduled = nil
            try commitPending()
        }
    }

    public func flushAsync() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                scheduled?.cancel(); scheduled = nil
                do { try commitPending(); continuation.resume() }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    public func statistics() -> (committed: Int, failed: Int) {
        queue.sync { (committedWrites, failedWrites) }
    }

    private func commitPending() throws {
        guard let current = pending else { return }
        do {
            if !validated && !resetAuthorized {
                do { try validate() }
                catch { throw OSprError.message("Saved history is unreadable and was preserved. Export new transcripts, or use Delete all history to reset storage explicitly.") }
            }
            try write(current.items)
            committedWrites += 1
            validated = true; resetAuthorized = false; pending = nil
            current.completion?(nil)
        } catch {
            failedWrites += 1
            // Keep the newest snapshot for an explicit flush or subsequent retry.
            current.completion?(error.localizedDescription)
            throw error
        }
    }
}
