import Foundation
import AVFoundation
import CryptoKit
import OSprCore

/// Explicit developer verification; uses a disposable store, never user history.
enum AudioReviewCheck {
    static func run(source: URL, worker: WorkerClient) async throws -> [String: Any] {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("OSpr-review-check-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try LocalStore(directory: directory)
        let archive = try AudioArchive(directory: directory.appendingPathComponent("Audio"))
        let original = try await worker.request(["action": "transcribe", "path": source.path, "model": "parakeet-v3", "language": "en"])
        let before = try await worker.request(["action": "ping"])
        let rejected = try await archive.newStagingURL()
        var budgetRejected = false
        do {
            _ = try await worker.request(["action": "prepare_review", "path": source.path, "output": rejected.path, "limit_bytes": 1024])
        } catch {
            budgetRejected = error.localizedDescription.localizedCaseInsensitiveContains("budget")
        }
        guard budgetRejected, !FileManager.default.fileExists(atPath: rejected.path) else { throw OSprError.message("Tiny-budget preparation did not fail safely.") }
        let after = try await worker.request(["action": "ping"])
        guard before["pid"] as? Int == after["pid"] as? Int else { throw OSprError.message("Preparation rejection unnecessarily restarted the warm engine.") }
        let staging = try await archive.newStagingURL()
        let normalized = try await worker.request(["action": "prepare_review", "path": source.path, "output": staging.path, "limit_bytes": 1024 * 1024 * 1024])
        let id = UUID()
        let audio = try await archive.adoptPrepared(staging, id: id, limitBytes: 1024 * 1024 * 1024)
        let result = try await worker.request(["action": "transcribe", "path": audio.url.path, "model": "parakeet-v3", "language": "en"])
        guard let text = result["text"] as? String, !text.isEmpty, text == original["text"] as? String, result["warm"] as? Bool == true else {
            throw OSprError.message("Retained-audio recognition differs or lost warm residency.")
        }
        var record = Transcript(rawText: text, text: text, model: "parakeet-v3", mode: .verbatim, duration: normalized["audio_seconds"] as? Double ?? 0, latencyMS: 0)
        record.id = id; record.audioFile = audio.name
        let persistence = try HistoryPersistence(directory: directory)
        persistence.submit([record]); try await persistence.flushAsync()
        try await archive.finishLease(audio.name, keep: true)
        let saved = try store.read([Transcript].self, name: "history.json") ?? []
        guard saved.first?.audioFile == audio.name, saved.first?.text == text else { throw OSprError.message("Audio reference did not survive history persistence.") }
        let restarted = try AudioArchive(directory: archive.directory)
        _ = try await restarted.reconcile(keeping: [audio.name], limitBytes: 1024 * 1024 * 1024)
        guard let restored = try await restarted.resolve(name: audio.name, id: id) else { throw OSprError.message("Retained audio did not survive archive restart.") }
        let asset = AVURLAsset(url: restored, options: [AVURLAssetReferenceRestrictionsKey: AVAssetReferenceRestrictions.forbidAll.rawValue])
        let duration = try await asset.load(.duration).seconds
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard abs(duration - record.duration) < 0.01, audioTracks.count == 1, videoTracks.isEmpty else { throw OSprError.message("Retained media duration/tracks differ.") }
        let replay = try await restarted.copyForReprocessing(name: audio.name, id: id)
        try await restarted.remove([audio.name])
        let reprocessed = try await worker.request(["action": "transcribe", "path": replay.path, "model": "parakeet-v3", "language": "en"])
        guard reprocessed["text"] as? String == text else { throw OSprError.message("Private reprocessing copy did not preserve recognition.") }
        try await restarted.discardStaging(replay)
        try await restarted.eraseAll()
        guard !FileManager.default.fileExists(atPath: restored.path), try store.read([Transcript].self, name: "history.json")?.first?.text == text else {
            throw OSprError.message("Audio-only deletion affected transcript text or retained the recording.")
        }
        return ["status": "passed", "timestamp": ISO8601DateFormatter().string(from: Date()), "model": "parakeet-v3",
                "source_sha256": SHA256.hash(data: try Data(contentsOf: source)).map { String(format: "%02x", $0) }.joined(),
                "audio_seconds": duration, "normalized_bytes": audio.bytes, "text": text,
                "warm_worker_survived_budget_rejection": true, "normalized_asr_matches_original": true,
                "reprocess_copy_survived_original_deletion": true,
                "history_and_archive_restart": true, "audio_only_deletion_kept_text": true,
                "avfoundation_audio_tracks": audioTracks.count, "avfoundation_video_tracks": videoTracks.count,
                "boundary": "Swift CLI and Core audio archive/history → owned Python worker normalization and actual local Metal ASR → store restart → AVFoundation duration/tracks. No playback sound, microphone, permissions or SwiftUI interaction."]
    }
}
