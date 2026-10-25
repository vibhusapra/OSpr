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
        let kind: String?
        var errorDescription: String? { message }
    }
    private let queue = DispatchQueue(label: "app.ospr.worker", qos: .userInitiated)
    private var process: Process?
    private var guardian: Process?
    private let guardianExecutable: URL?
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
    public init(root: String, timeout: TimeInterval = 600, startupTimeout: TimeInterval = 20, guardianExecutable: URL? = nil) {
        self.root = root; self.timeout = timeout; self.startupTimeout = startupTimeout
        self.guardianExecutable = guardianExecutable
    }
    deinit { Self.terminate(process); try? log?.close() }

    public func request(_ body: [String: Any], progress: (@Sendable ([String: Any]) -> Void)? = nil, timeout requestTimeout: TimeInterval? = nil) async throws -> [String: Any] {
        let deadline = requestTimeout ?? timeout
        guard deadline.isFinite, deadline > 0, (requestTimeout == nil || deadline <= 3600) else {
            throw OSprError.message("Invalid worker request deadline.")
        }
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
                watchdog.schedule(deadline: .now() + deadline)
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
                    let started = try startIfNeeded(handshakeTimeout: deadline)
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
                    // Completed output-budget stops leave the decoder healthy.
                    // Keep warm ASR after these or expected audio preparation
                    // rejections; all other inference/protocol failures restart.
                    let rejection = error as? EngineRejection
                    let action = body["action"] as? String ?? ""
                    let preparationRejection = rejection != nil && ["prepare_review", "prepare_upload", "prepare_upload_parts"].contains(action)
                    let textRejection = Self.retainsTextModels(after: error, action: action)
                    let mediaRejection = rejection?.kind == "media-read" && ["transcribe", "meeting", "analyze_speech"].contains(action)
                    if !preparationRejection && !textRejection && !mediaRejection { self.stopOnQueue() }
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// These typed rejections leave the serial decoder healthy. Callers can keep
    /// speech readiness; unknown/runtime/protocol failures still drop residency.
    public static func retainsTextModels(after error: Error, action: String) -> Bool {
        guard let rejection = error as? EngineRejection else { return false }
        return (rejection.kind == "text-output-limit" && ["rewrite", "notes", "summary", "warm_text"].contains(action)) ||
            (rejection.kind == "text-model-not-prepared" && ["rewrite", "warm_text"].contains(action))
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
                throw EngineRejection(message: message, kind: response["error_kind"] as? String)
            }
            guard let result = response["result"] as? [String: Any] else { throw OSprError.message("Invalid local engine response.") }
            return result
        }
    }
    private static func terminate(_ child: Process?) {
        guard let child, child.isRunning else { return }
        if let group = OwnedWorkerGroup(child.processIdentifier) {
            group.terminate()
        } else if let identity = WorkerProcessIdentity(child.processIdentifier), identity.parent == getpid() {
            identity.signal(SIGTERM)
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) { identity.signal(SIGKILL) }
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
        // The guardian outlives the leader briefly to finish descendant cleanup.
        guardian = nil
        try? input?.close(); try? output?.close(); try? log?.close()
        input = nil; output = nil; log = nil
        pending.removeAll(keepingCapacity: false)
    }
    private func startIfNeeded(handshakeTimeout: TimeInterval) throws -> Bool {
        lifecycle.lock(); let currentEpoch = epoch; lifecycle.unlock()
        if processEpoch == currentEpoch && process?.isRunning == true && guardian?.isRunning == true { return false }
        stopOnQueue()
        let python = URL(fileURLWithPath: root).appendingPathComponent(".venv/bin/python")
        guard FileManager.default.isExecutableFile(atPath: python.path) else {
            throw OSprError.message("Set up the local engine first. Run scripts/setup.sh in the OSpr checkout, then select that folder in Settings.")
        }
        guard let guardianURL = guardianExecutable ?? WorkerGuardian.executableURL(),
              FileManager.default.isExecutableFile(atPath: guardianURL.path) else {
            throw OSprError.message("Local engine lifetime helper is missing. Rebuild OSpr with scripts/build-app.sh or reinstall the complete app.")
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
        try startGuardian(executable: guardianURL, child: child, timeout: handshakeTimeout)
        return true
    }

    private func startGuardian(executable: URL, child: Process, timeout: TimeInterval) throws {
        let helper = Process(), ready = Pipe()
        helper.executableURL = executable
        helper.arguments = [String(getpid()), String(child.processIdentifier)]
        helper.currentDirectoryURL = URL(fileURLWithPath: "/")
        helper.environment = [:]
        helper.standardInput = FileHandle.nullDevice
        helper.standardOutput = ready
        helper.standardError = FileHandle.nullDevice
        // A lost guardian must never leave a warm, unprotected worker reusable.
        // This handler does not wait behind the serial inference/read queue.
        helper.terminationHandler = { _ in Self.terminate(child) }
        try helper.run()
        guardian = helper
        let watchdog = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        watchdog.schedule(deadline: .now() + min(startupTimeout, timeout, 5))
        watchdog.setEventHandler {
            Self.terminate(child)
            if helper.isRunning { helper.terminate() }
        }
        watchdog.resume()
        defer { watchdog.cancel(); try? ready.fileHandleForReading.close() }
        let response = ready.fileHandleForReading.availableData
        guard response == Data("READY\n".utf8), helper.isRunning, child.isRunning else {
            Self.terminate(child)
            if helper.isRunning { helper.terminate() }
            throw OSprError.message("Local engine lifetime helper could not start. Rebuild or reinstall the complete app, then retry.")
        }
    }

}
