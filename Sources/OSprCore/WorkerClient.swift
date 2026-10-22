import Foundation
import Darwin

public enum OSprError: LocalizedError {
    case message(String)
    public var errorDescription: String? { if case .message(let message) = self { return message }; return nil }
}

/// A serial IPC executor. All pipe and process state lives on one queue; decoding
/// cannot interleave when UI preview, warming and finalization arrive together.
public final class WorkerClient: @unchecked Sendable {
    private struct EngineRejection: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
    private let queue = DispatchQueue(label: "app.ospr.worker", qos: .userInitiated)
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var log: FileHandle?
    private var root: String
    private var pending = Data()
    private let lifecycle = NSLock()
    private var epoch: UInt64 = 0
    private var processEpoch: UInt64 = 0
    private var activeRequest: UUID?
    private let timeout: TimeInterval
    private let startupTimeout: TimeInterval
    public init(root: String, timeout: TimeInterval = 600, startupTimeout: TimeInterval = 20) {
        self.root = root; self.timeout = timeout; self.startupTimeout = startupTimeout
    }
    deinit { process?.terminate(); try? log?.close() }

    public func request(_ body: [String: Any], progress: (@Sendable ([String: Any]) -> Void)? = nil) async throws -> [String: Any] {
        // Capture has already advanced its packet cursor before stream_feed.
        // Finish that admitted packet even when the preview Task is cancelled
        // for final flushing. Session cleanup must also survive Task cancellation.
        let preserveAdmittedPacket = ["stream_feed", "stream_cancel"].contains(body["action"] as? String ?? "")
        if !preserveAdmittedPacket { try Task.checkCancellation() }
        let requestedEpoch = lifecycle.withLock { epoch }
        if !preserveAdmittedPacket { try Task.checkCancellation() }
        return try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                let operation = UUID()
                let watchdog = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
                watchdog.schedule(deadline: .now() + timeout)
                watchdog.setEventHandler { [weak self] in
                    guard let self else { return }
                    self.lifecycle.lock()
                    let child = self.activeRequest == operation ? self.process : nil
                    self.lifecycle.unlock()
                    Self.terminate(child)
                }
                lifecycle.lock(); activeRequest = operation; lifecycle.unlock()
                watchdog.resume()
                defer {
                    watchdog.cancel()
                    lifecycle.lock(); activeRequest = nil; lifecycle.unlock()
                }
                do {
                    lifecycle.lock(); let cancelled = requestedEpoch != epoch; lifecycle.unlock()
                    guard !cancelled else { throw CancellationError() }
                    let started = try startIfNeeded()
                    lifecycle.lock(); let cancelledAfterStart = requestedEpoch != epoch; lifecycle.unlock()
                    guard !cancelledAfterStart else { throw CancellationError() }
                    if started {
                        let child = process
                        let bootWatchdog = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
                        bootWatchdog.schedule(deadline: .now() + startupTimeout)
                        bootWatchdog.setEventHandler { Self.terminate(child) }
                        bootWatchdog.resume()
                        defer { bootWatchdog.cancel() }
                        let bootID = UUID().uuidString
                        var hello = try JSONSerialization.data(withJSONObject: ["action": "ping", "id": bootID]); hello.append(10)
                        try input?.write(contentsOf: hello)
                        _ = try readResult(id: bootID)
                    }
                    lifecycle.lock(); let cancelledBeforeRequest = requestedEpoch != epoch; lifecycle.unlock()
                    guard !cancelledBeforeRequest else { throw CancellationError() }

                    let id = UUID().uuidString
                    var request = body; request["id"] = id
                    var bytes = try JSONSerialization.data(withJSONObject: request); bytes.append(10)
                    try input?.write(contentsOf: bytes)
                    let result = try readResult(id: id, progress: progress)
                    continuation.resume(returning: result)
                } catch {
                    // A failed inference has a valid protocol response, but restart
                    // after any error so broken pipes cannot poison subsequent work.
                    // Local audio preparation never mutates model state. Keep a
                    // warm ASR after an expected size/codec rejection; malformed
                    // framing, broken pipes and inference errors still restart.
                    if !(error is EngineRejection && ["prepare_review", "prepare_upload", "prepare_upload_parts"].contains(body["action"] as? String ?? "")) { self.stopOnQueue() }
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func readResult(id: String, progress: (@Sendable ([String: Any]) -> Void)? = nil) throws -> [String: Any] {
        while true {
            while !pending.contains(10) {
                guard let handle = output else { throw OSprError.message("Local engine pipe is unavailable.") }
                let chunk = handle.availableData
                guard !chunk.isEmpty else {
                    throw OSprError.message("Local engine stopped or timed out. Check macOS folder permissions, then retry. Diagnostic logging is opt-in with OSPR_DEBUG_LOG=1.")
                }
                pending.append(chunk)
                guard pending.count < 32 * 1024 * 1024 else { throw OSprError.message("Engine response exceeded size limit.") }
            }
            let newline = pending.firstIndex(of: 10)!
            let data = pending.prefix(upTo: newline); pending.removeSubrange(...newline)
            guard let response = try JSONSerialization.jsonObject(with: data) as? [String: Any], response["id"] as? String == id else {
                throw OSprError.message("Invalid local engine response.")
            }
            if response["event"] as? String == "progress" {
                guard let event = response["progress"] as? [String: Any] else { throw OSprError.message("Invalid model progress response.") }
                progress?(event)
                continue
            }
            guard let ok = response["ok"] as? Bool else { throw OSprError.message("Invalid local engine response.") }
            if !ok {
                guard let message = response["error"] as? String else { throw OSprError.message("Invalid local engine response.") }
                throw EngineRejection(message: message)
            }
            guard let result = response["result"] as? [String: Any] else { throw OSprError.message("Invalid local engine response.") }
            return result
        }
    }
    private static func terminate(_ child: Process?) {
        guard let child, child.isRunning else { return }
        let pid = child.processIdentifier
        // The real Python worker starts its own session. Include its FFmpeg
        // descendants, but never signal the app's or another session's group.
        if getpgid(pid) == pid { kill(-pid, SIGTERM) } else { child.terminate() }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) {
            guard child.isRunning else { return }
            if getpgid(pid) == pid { kill(-pid, SIGKILL) } else { kill(pid, SIGKILL) }
        }
    }

    public func shutdown() {
        // Interrupt blocked reads immediately; queue cleanup follows pipe EOF.
        // Used for cancellation and termination; epochs invalidate queued requests.
        lifecycle.lock(); epoch &+= 1; let child = process; lifecycle.unlock()
        Self.terminate(child)
    }

    private func stopOnQueue() {
        lifecycle.lock(); let child = process; process = nil; lifecycle.unlock()
        Self.terminate(child)
        try? input?.close(); try? output?.close(); try? log?.close()
        input = nil; output = nil; log = nil
        pending.removeAll(keepingCapacity: false)
    }
    private func startIfNeeded() throws -> Bool {
        lifecycle.lock(); let currentEpoch = epoch; lifecycle.unlock()
        if processEpoch == currentEpoch && process?.isRunning == true { return false }
        stopOnQueue()
        let python = URL(fileURLWithPath: root).appendingPathComponent(".venv/bin/python")
        guard FileManager.default.isExecutableFile(atPath: python.path) else {
            throw OSprError.message("Set up the local engine first. Run scripts/setup.sh in the OSpr checkout, then select that folder in Settings.")
        }
        let child = Process(), stdin = Pipe(), stdout = Pipe()
        child.executableURL = python
        child.arguments = ["-u", "-m", "ospr_backend.worker"]
        child.currentDirectoryURL = URL(fileURLWithPath: root)
        var env = ProcessInfo.processInfo.environment
        env["PYTHONPATH"] = URL(fileURLWithPath: root).appendingPathComponent("backend").path
        env["TOKENIZERS_PARALLELISM"] = "false"
        env["HF_HUB_DISABLE_PROGRESS_BARS"] = "1"
        env["PYTHONUNBUFFERED"] = "1"
        env["PYTHONDONTWRITEBYTECODE"] = "1"
        env["PYTHONSAFEPATH"] = "1"
        env["HF_HUB_DISABLE_TELEMETRY"] = "1"
        env["DO_NOT_TRACK"] = "1"
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (env["PATH"] ?? "")
        child.environment = env
        if env["OSPR_DEBUG_LOG"] == "1" {
            let logDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("OSpr")
            try FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let logURL = logDir.appendingPathComponent("engine.log")
            if !FileManager.default.fileExists(atPath: logURL.path) { FileManager.default.createFile(atPath: logURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: logURL.path)
            log = try FileHandle(forWritingTo: logURL)
            // A diagnostic session replaces the previous log; it may contain
            // model output or file paths. Never accumulate transcripts by default.
            try log?.truncate(atOffset: 0)
        }
        child.standardInput = stdin; child.standardOutput = stdout; child.standardError = log ?? FileHandle.nullDevice
        try child.run()
        lifecycle.lock(); process = child; processEpoch = currentEpoch; lifecycle.unlock()
        input = stdin.fileHandleForWriting; output = stdout.fileHandleForReading
        return true
    }
}
