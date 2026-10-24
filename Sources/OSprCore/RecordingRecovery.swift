import Foundation

public struct RecoveredTrack: Codable, Sendable {
    public var name: String
    public var start: Double
}
public struct RecoveryTrackSource: Sendable {
    public var url: URL
    public var start: Double
    public init(url: URL, start: Double) { self.url = url; self.start = start }
}
public struct PendingRecording: Codable, Sendable {
    public var created: Date
    public var duration: Double
    public var settings: OSprSettings
    public var mode: WritingMode
    public var tracks: [RecoveredTrack]?
    public var captureWarning: String?
}

/// Owner-only completed audio survives worker failure/restart. A meeting can
/// retain its raw clocked tracks before mixing, including on a missing decoder.
/// No credentials or UI targets are persisted. Retry never inserts in an old field.
public final class RecordingRecovery {
    private let store: LocalStore
    public var directory: URL { store.directory }
    public var audioURL: URL { directory.appendingPathComponent("pending.wav") }
    private var metadataURL: URL { directory.appendingPathComponent("pending.json") }
    public var managedAudio: [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []).filter {
            ["pending.wav", "track-0.wav", "track-1.wav"].contains($0.lastPathComponent) ||
            ($0.lastPathComponent.hasPrefix(".pending-copy-") && $0.pathExtension == "wav")
        }
    }
    public var exists: Bool { !managedAudio.isEmpty }
    public var needsMix: Bool { !FileManager.default.fileExists(atPath: audioURL.path) }
    public init(directory: URL) throws { store = try LocalStore(directory: directory) }
    public func load() throws -> PendingRecording? {
        guard exists else { return nil }
        guard let pending = try store.read(PendingRecording.self, name: "pending.json") else {
            throw OSprError.message("Unfinished audio has no readable metadata. Export or discard it before recording again.")
        }
        if needsMix {
            guard let tracks = pending.tracks, (1...2).contains(tracks.count) else {
                throw OSprError.message("The unfinished audio copy did not complete. Export remaining audio or discard it.")
            }
            for track in tracks {
                guard ["track-0.wav", "track-1.wav"].contains(track.name), track.start.isFinite,
                      FileManager.default.fileExists(atPath: directory.appendingPathComponent(track.name).path) else {
                    throw OSprError.message("An unfinished meeting track is missing or invalid. Export remaining audio or discard it.")
                }
            }
        }
        return pending
    }
    private func copyAtomically(_ source: URL, to destination: URL) throws {
        let stage = directory.appendingPathComponent(".pending-copy-" + UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: stage) }
        // FileManager can clone on APFS; avoid allocating an entire long take.
        try FileManager.default.copyItem(at: source, to: stage)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stage.path)
        try FileManager.default.moveItem(at: stage, to: destination)
    }
    @discardableResult public func preserve(audio: URL, duration: Double, settings: OSprSettings, mode: WritingMode, warning: String? = nil) throws -> PendingRecording {
        guard !exists else { throw OSprError.message("Retry or discard the unfinished recording first.") }
        let pending = PendingRecording(created: Date(), duration: duration, settings: settings, mode: mode, captureWarning: warning)
        try store.write(pending, name: "pending.json")
        try copyAtomically(audio, to: audioURL)
        return pending
    }
    @discardableResult public func preserveTracks(_ sources: [RecoveryTrackSource], duration: Double, settings: OSprSettings, warning: String? = nil) throws -> PendingRecording {
        guard !exists, (1...2).contains(sources.count), sources.allSatisfy({ $0.start.isFinite }) else {
            throw OSprError.message("Cannot replace existing recovery audio or use invalid meeting tracks.")
        }
        let tracks = sources.enumerated().map { RecoveredTrack(name: "track-\($0.offset).wav", start: $0.element.start) }
        let pending = PendingRecording(created: Date(), duration: duration, settings: settings, mode: .verbatim, tracks: tracks, captureWarning: warning)
        try store.write(pending, name: "pending.json")
        for (source, track) in zip(sources, tracks) { try copyAtomically(source.url, to: directory.appendingPathComponent(track.name)) }
        return pending
    }
    public func mixSources() throws -> [RecoveryTrackSource] {
        guard let tracks = try load()?.tracks else { throw OSprError.message("No recoverable meeting tracks.") }
        return tracks.map { RecoveryTrackSource(url: directory.appendingPathComponent($0.name), start: $0.start) }
    }
    public func replaceWithMix(_ audio: URL) throws {
        guard needsMix, var pending = try load() else { throw OSprError.message("No unfinished meeting to mix.") }
        try copyAtomically(audio, to: audioURL)
        let previous = pending.tracks ?? []; pending.tracks = nil
        try store.write(pending, name: "pending.json")
        for track in previous { try? FileManager.default.removeItem(at: directory.appendingPathComponent(track.name)) }
    }
    public func discard() throws {
        for url in managedAudio + [metadataURL] where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
}
