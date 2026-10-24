import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// A private, exclusive workspace. PID naming also permits the local worker's
/// next-use orphan cleanup after an abrupt app/CLI exit.
public final class ProviderUploadWorkspace: @unchecked Sendable {
    public let url: URL
    private let lock = NSLock()
    private var closed = false
    public init() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("OSpr-Engine", isDirectory: true)
        if mkdir(root.path, 0o700) != 0 && errno != EEXIST { throw POSIXError(.EACCES) }
        var attributes = stat()
        guard lstat(root.path, &attributes) == 0, attributes.st_mode & S_IFMT == S_IFDIR,
              attributes.st_uid == getuid(), chmod(root.path, 0o700) == 0 else {
            throw OSprError.message("Private upload storage has an unexpected owner or type.")
        }
        var template = Array(root.appendingPathComponent("\(getpid())-upload-XXXXXX").path.utf8CString)
        let path = template.withUnsafeMutableBufferPointer { buffer -> String? in
            guard let directory = mkdtemp(buffer.baseAddress!) else { return nil }
            return String(cString: directory)
        }
        guard let path else { throw POSIXError(.EIO) }
        url = URL(fileURLWithPath: path, isDirectory: true)
    }
    public func close() {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }; closed = true
        try? FileManager.default.removeItem(at: url)
    }
    deinit { close() }
}

public struct ProviderAudioPart: Sendable {
    public let file: URL
    public let startFrame: Int
    public let frames: Int
    public var start: Double { Double(startFrame) / 16000 }
    public var duration: Double { Double(frames) / 16000 }
}

/// Validate the entire worker manifest before transmitting the first byte.
/// Paths cannot escape the workspace; integer frame offsets must cover the
/// complete timeline exactly once. Provider parts are at most ten minutes.
public struct ProviderUploadPlan: Sendable {
    public let parts: [ProviderAudioPart]
    public let frames: Int
    public var duration: Double { Double(frames) / 16000 }
    public init(_ manifest: [String: Any], directory: URL) throws {
        guard manifest["sample_rate"] as? Int == 16000, let total = manifest["frames"] as? Int,
              total > 0, total <= 4 * 3600 * 16000,
              let entries = manifest["parts"] as? [[String: Any]], !entries.isEmpty, entries.count <= 64 else {
            throw OSprError.message("Invalid prepared upload timeline.")
        }
        let root = directory.resolvingSymlinksInPath().standardizedFileURL
        var output: [ProviderAudioPart] = [], expected = 0
        for (index, entry) in entries.enumerated() {
            guard let path = entry["path"] as? String, let start = entry["start_frame"] as? Int,
                  let count = entry["frames"] as? Int, start == expected, count > 0,
                  count <= 600 * 16000, count <= total - expected else {
                throw OSprError.message("Prepared upload contains missing or overlapping audio.")
            }
            let file = URL(fileURLWithPath: path).standardizedFileURL
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard file.deletingLastPathComponent().resolvingSymlinksInPath() == root,
                  file.lastPathComponent == String(format: "part-%04d.wav", index),
                  values.isRegularFile == true, values.isSymbolicLink != true,
                  let size = values.fileSize, size > 0, size < ProviderClient.maximumUploadBytes else {
                throw OSprError.message("Prepared upload file is missing, oversized or outside private storage.")
            }
            output.append(ProviderAudioPart(file: file, startFrame: start, frames: count)); expected += count
        }
        guard expected == total else { throw OSprError.message("Prepared upload does not contain the complete recording.") }
        parts = output; frames = total
    }
}

extension ProviderClient {
    /// Serial requests bound memory and quota pressure. A failure/cancel throws
    /// before any assembled result is returned; no partial transcript is saved.
    public static func transcribe(plan: ProviderUploadPlan, base: String, model: String, key: String,
                                  language: String, vocabulary: String,
                                  provider: String = "compatible",
                                  progress: (@Sendable (Int, Int) -> Void)? = nil) async throws -> [String: Any] {
        _ = try speechEndpoint(base: base, provider: provider)
        let began = Date()
        var texts: [String] = [], segments: [[String: Any]] = [], words: [[String: Any]] = []
        var allWordTimes = true, coarseTiming = false, languages = Set<String>()
        var warnings: [String] = []
        for (index, part) in plan.parts.enumerated() {
            try Task.checkCancellation(); progress?(index + 1, plan.parts.count)
            let result = try await transcribe(file: part.file, base: base, model: model, key: key, language: language, vocabulary: vocabulary, provider: provider)
            try Task.checkCancellation()
            let text = result["text"] as? String ?? ""
            if let warning = result["warning"] as? String, !warning.isEmpty { warnings.append(warning) }
            if let tag = result["language"] as? String, !tag.isEmpty { languages.insert(tag) }
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            texts.append(text)
            if (result["timestamp_source"] as? String)?.contains("coarse") == true { coarseTiming = true }
            if let timed = shiftedTimes(result["segments"], part: part, words: false), !timed.isEmpty { segments += timed }
            else { coarseTiming = true; segments.append(["start": part.start, "end": part.start + part.duration, "text": text]) }
            if let timed = shiftedTimes(result["words"], part: part, words: true), !timed.isEmpty { words += timed }
            else { allWordTimes = false }
        }
        try Task.checkCancellation()
        var result: [String: Any] = ["text": texts.joined(separator: "\n"), "segments": segments,
            "audio_seconds": plan.duration, "model": model, "upload_parts": plan.parts.count,
            "timestamp_source": coarseTiming ? "provider-or-coarse-upload-part" : "provider",
            "language": languages.count == 1 ? languages.first! : languages.isEmpty ? language : "mul",
            "total_ms": Date().timeIntervalSince(began) * 1000]
        if allWordTimes && !words.isEmpty { result["words"] = words }
        if !warnings.isEmpty { result["warning"] = warnings.joined(separator: "\n") }
        return result
    }
    private static func shiftedTimes(_ value: Any?, part: ProviderAudioPart, words: Bool) -> [[String: Any]]? {
        guard let entries = value as? [[String: Any]] else { return nil }
        var output: [[String: Any]] = [], last = 0.0
        for entry in entries {
            guard let start = entry["start"] as? Double, let end = entry["end"] as? Double,
                  let text = (entry["text"] ?? (words ? entry["word"] : nil)) as? String,
                  start.isFinite, end.isFinite, start >= last, end >= start, end <= part.duration + 0.25 else { return nil }
            var normalized: [String: Any] = ["start": part.start + min(start, part.duration),
                "end": part.start + min(end, part.duration), "text": text]
            // A provider's generic channel numbering is not stable across jobs.
            // Do not invent speaker continuity when assembling independent calls.
            if words { normalized["word"] = text }
            output.append(normalized); last = start
        }
        return output
    }
}
