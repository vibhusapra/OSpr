import Foundation
import Darwin

public enum OSprError: LocalizedError {
    case message(String)
    public var errorDescription: String? { if case .message(let message) = self { return message }; return nil }
}

/// A serial IPC executor. All pipe and process state lives on one queue; decoding
/// cannot interleave when UI preview, warming and finalization arrive together.
public final class WorkerClient: @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.ospr.worker", qos: .userInitiated)
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var log: FileHandle?
    private var root: String
    private var pending = Data()
    private let lifecycle = NSLock()
    private var epoch: UInt64 = 0
    private var activeRequest: UUID?
    private let timeout: TimeInterval
    private let startupTimeout: TimeInterval
    public init(root: String, timeout: TimeInterval = 600, startupTimeout: TimeInterval = 20) {
        self.root = root; self.timeout = timeout; self.startupTimeout = startupTimeout
    }
    deinit { process?.terminate(); try? log?.close() }

    public func request(_ body: [String: Any]) async throws -> [String: Any] {
        lifecycle.lock(); let requestedEpoch = epoch; lifecycle.unlock()
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
                    let result = try readResult(id: id)
                    continuation.resume(returning: result)
                } catch {
                    // A failed inference has a valid protocol response, but restart
                    // after any error so broken pipes cannot poison subsequent work.
                    self.stopOnQueue()
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func readResult(id: String) throws -> [String: Any] {
        while !pending.contains(10) {
            guard let handle = output else { throw OSprError.message("Local engine pipe is unavailable.") }
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                throw OSprError.message("Local engine stopped or timed out. Check the engine log and macOS folder permissions. Try choosing the checkout again in Settings.")
            }
            pending.append(chunk)
            guard pending.count < 32 * 1024 * 1024 else { throw OSprError.message("Engine response exceeded size limit.") }
        }
        let newline = pending.firstIndex(of: 10)!
        let data = pending.prefix(upTo: newline); pending.removeSubrange(...newline)
        guard let response = try JSONSerialization.jsonObject(with: data) as? [String: Any], response["id"] as? String == id else {
            throw OSprError.message("Invalid local engine response.")
        }
        guard response["ok"] as? Bool == true, let result = response["result"] as? [String: Any] else {
            throw OSprError.message(response["error"] as? String ?? "Inference failed.")
        }
        return result
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
        if process?.isRunning == true { return false }
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
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (env["PATH"] ?? "")
        child.environment = env
        let logDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("OSpr")
        try FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        let logURL = logDir.appendingPathComponent("engine.log")
        if !FileManager.default.fileExists(atPath: logURL.path) { FileManager.default.createFile(atPath: logURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
        log = try FileHandle(forWritingTo: logURL); try log?.seekToEnd()
        child.standardInput = stdin; child.standardOutput = stdout; child.standardError = log
        try child.run()
        lifecycle.lock(); process = child; lifecycle.unlock()
        input = stdin.fileHandleForWriting; output = stdout.fileHandleForReading
        return true
    }
}
