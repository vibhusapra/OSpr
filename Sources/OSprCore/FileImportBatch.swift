import Foundation

/// Latest import queue, retained only for the current app session. Source files
/// are never changed; retries reuse failed/cancelled entries, not successes.
public struct FileImportBatch: Sendable {
    public enum State: String, Sendable { case queued, processing, completed, warning, failed, cancelled }
    public struct Item: Identifiable, Sendable {
        public let id: UUID
        public let url: URL
        public var state: State = .queued
        public var transcriptID: UUID?
        public var message: String?
        public var name: String { url.lastPathComponent }
    }
    public private(set) var items: [Item]
    public init(urls: [URL]) { items = urls.map { Item(id: UUID(), url: $0) } }
    public var remaining: [Item] { items.filter { $0.state == .queued } }
    public var completedCount: Int { items.filter { [.completed, .warning].contains($0.state) }.count }
    public var retryCount: Int { items.filter { [.failed, .cancelled].contains($0.state) }.count }
    public var active: Bool { items.contains { [.queued, .processing].contains($0.state) } }
    public mutating func begin(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }), items[index].state == .queued else { return }
        items[index].state = .processing
    }
    public mutating func finish(_ id: UUID, transcriptID: UUID?, message: String?) {
        guard let index = items.firstIndex(where: { $0.id == id }), items[index].state == .processing else { return }
        items[index].transcriptID = transcriptID
        items[index].message = message
        items[index].state = transcriptID == nil ? .failed : message == nil ? .completed : .warning
    }
    public mutating func noteTranscript(_ id: UUID, transcriptID: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }), items[index].state == .processing else { return }
        items[index].transcriptID = transcriptID
    }
    public mutating func cancelRemaining() {
        for index in items.indices where [.queued, .processing].contains(items[index].state) {
            items[index].state = items[index].transcriptID == nil ? .cancelled : .warning
            items[index].message = items[index].transcriptID == nil ? "Import cancelled. Source file is unchanged." : "Transcript available in History; remaining processing was interrupted."
        }
    }
    public mutating func prepareRetry() {
        guard !active else { return }
        for index in items.indices where [.failed, .cancelled].contains(items[index].state) {
            items[index].state = .queued; items[index].message = nil; items[index].transcriptID = nil
        }
    }
}
