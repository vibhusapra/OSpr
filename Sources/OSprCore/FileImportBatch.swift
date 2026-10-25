import Foundation

/// Stable result identities bridge the history-commit/checkpoint crash boundary.
/// Source files are never changed; retry never creates a new identity for a job.
public struct FileImportBatch: Codable, Sendable {
    public enum State: String, Codable, Sendable { case queued, processing, completed, warning, failed, cancelled, unavailable }
    public struct Item: Identifiable, Codable, Sendable {
        public let id: UUID
        public let url: URL
        public let resultID: UUID
        public var state: State = .queued
        public var transcriptID: UUID?
        public var message: String?
        public var historyCommitted = false
        public var name: String { url.lastPathComponent }
        init(id: UUID, url: URL) { self.id = id; self.url = url; resultID = UUID() }
    }
    public let id: UUID
    public let created: Date
    public private(set) var updated: Date
    public private(set) var items: [Item]
    public init(urls: [URL]) { id = UUID(); created = Date(); updated = created; items = urls.map { Item(id: UUID(), url: $0) } }
    public var remaining: [Item] { items.filter { $0.state == .queued } }
    public var completedCount: Int { items.filter { [.completed, .warning].contains($0.state) }.count }
    public var retryCount: Int { items.filter { [.failed, .cancelled].contains($0.state) }.count }
    public var active: Bool { items.contains { [.queued, .processing].contains($0.state) } }
    public mutating func begin(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }), items[index].state == .queued else { return }
        items[index].state = .processing
        updated = Date()
    }
    public mutating func finish(_ id: UUID, transcriptID: UUID?, message: String?) {
        guard let index = items.firstIndex(where: { $0.id == id }), items[index].state == .processing else { return }
        items[index].transcriptID = transcriptID
        items[index].message = message
        items[index].state = transcriptID == nil ? .failed : message == nil ? .completed : .warning
        updated = Date()
    }
    public mutating func noteTranscript(_ id: UUID, transcriptID: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }), items[index].state == .processing else { return }
        items[index].transcriptID = transcriptID
    }
    public mutating func confirmStored(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }), items[index].transcriptID != nil else { return }
        items[index].historyCommitted = true
    }
    public mutating func cancelRemaining() {
        var changed = false
        for index in items.indices where [.queued, .processing].contains(items[index].state) {
            changed = true
            items[index].state = items[index].transcriptID == nil ? .cancelled : .warning
            items[index].message = items[index].transcriptID == nil ? "Import cancelled. Source file is unchanged." : "Transcript available in History; remaining processing was interrupted."
        }
        if changed { updated = Date() }
    }
    public mutating func prepareRetry() {
        guard !active else { return }
        for index in items.indices where [.failed, .cancelled].contains(items[index].state) {
            items[index].state = .queued; items[index].message = nil; items[index].transcriptID = nil; items[index].historyCommitted = false
        }
        updated = Date()
    }
    /// Reconcile against saved history before offering an explicit resume.
    /// A committed result wins over an older processing checkpoint. A result
    /// removed by history retention/deletion is never silently regenerated.
    public mutating func recover(existing: Set<UUID>) {
        for index in items.indices {
            if existing.contains(items[index].resultID) {
                items[index].transcriptID = items[index].resultID
                items[index].historyCommitted = true
                if ![.completed, .warning].contains(items[index].state) {
                    items[index].state = .warning
                    items[index].message = "Transcript was saved before the import was interrupted."
                }
            } else if items[index].historyCommitted || items[index].state == .unavailable {
                items[index].state = .unavailable; items[index].transcriptID = nil
                items[index].message = "Transcript is no longer in saved History. It may have been deleted or expired. Import the source again if needed."
            } else if [.queued, .processing, .completed, .warning].contains(items[index].state) {
                items[index].state = .cancelled; items[index].transcriptID = nil
                items[index].message = "Interrupted before a confirmed save. Resume reads the current source file."
            }
        }
    }
}
