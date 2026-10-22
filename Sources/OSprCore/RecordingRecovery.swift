import Foundation

public struct PendingRecording: Codable {
    public var created: Date
    public var duration: Double
    public var settings: OSprSettings
    public var mode: WritingMode
}

/// One owner-only completed take survives a worker failure or application restart.
/// No keys or UI targets are persisted. Retrying never inserts into an old field.
public final class RecordingRecovery {
    private let store: LocalStore
    public var audioURL: URL { store.directory.appendingPathComponent("pending.wav") }
    private var metadataURL: URL { store.directory.appendingPathComponent("pending.json") }
    public init(directory: URL) throws { store = try LocalStore(directory: directory) }
    public func load() throws -> PendingRecording? {
        guard FileManager.default.fileExists(atPath: audioURL.path) else { return nil }
        guard let pending = try store.read(PendingRecording.self, name: "pending.json") else {
            throw OSprError.message("An unfinished recording has no readable metadata. Export or discard it before recording again.")
        }
        return pending
    }
    @discardableResult public func preserve(audio: URL, duration: Double, settings: OSprSettings, mode: WritingMode) throws -> PendingRecording {
        guard !FileManager.default.fileExists(atPath: audioURL.path) else {
            throw OSprError.message("Retry or discard the unfinished recording first.")
        }
        let pending = PendingRecording(created: Date(), duration: duration, settings: settings, mode: mode)
        // Metadata first: if interrupted during the atomic audio write, no partial
        // WAV is offered as recoverable. An orphaned metadata file is harmless.
        try store.write(pending, name: "pending.json")
        try Data(contentsOf: audio).write(to: audioURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: audioURL.path)
        return pending
    }
    public func discard() throws {
        for url in [audioURL, metadataURL] where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
}
