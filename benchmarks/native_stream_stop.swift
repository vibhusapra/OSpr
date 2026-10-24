// Compile with the unchanged shipping Sources/OSprCore/WorkerClient.swift.
// Public-fixture IPC regression only; does not operate microphone, UI or AX.
import Foundation

private final class PacketTiming: @unchecked Sendable {
    private let lock = NSLock()
    private var began: Double?
    private var ended: Double?
    private var wasCancelled = false
    func start(cancelled: Bool) { lock.lock(); defer { lock.unlock() }; began = ProcessInfo.processInfo.systemUptime; wasCancelled = cancelled }
    func finish() { lock.lock(); defer { lock.unlock() }; ended = ProcessInfo.processInfo.systemUptime }
    func snapshot() -> (Double?, Double?, Bool) { lock.lock(); defer { lock.unlock() }; return (began, ended, wasCancelled) }
}

private struct NativeCase: Decodable {
    let id: String
    let rate: Int
    let packets: [String]
    let changedRateTail: String
    let fullSource: String
    let replacementPackets: [String]
}
private struct Manifest: Decodable { let root: String; let cases: [NativeCase]; let cancelAfterMS: Int }

@main private struct NativeStreamStop {
    static func begin(_ worker: WorkerClient) async throws -> String {
        let state = try await worker.request(["action": "stream_begin", "language": "en"])
        guard let id = state["session_id"] as? String, !id.isEmpty else { throw OSprError.message("Missing stream ID") }
        return id
    }
    static func feed(_ worker: WorkerClient, _ path: String, _ id: String) async throws -> [String: Any] {
        try await worker.request(["action": "stream_feed", "session_id": id, "path": path])
    }
    static func end(_ worker: WorkerClient, _ id: String) async throws -> [String: Any] {
        let result = try await worker.request(["action": "stream_end", "session_id": id])
        guard result["done"] as? Bool == true else { throw OSprError.message("Stream did not finish") }
        return result
    }
    static func pid(_ worker: WorkerClient) async throws -> Int {
        let result = try await worker.request(["action": "ping"])
        guard let value = result["pid"] as? Int else { throw OSprError.message("Missing owned worker PID") }
        return value
    }
    static func run(_ manifest: Manifest) async throws -> [String: Any] {
        guard manifest.cases.count == 2, manifest.cancelAfterMS == 5,
              manifest.cases.allSatisfy({ $0.packets.count == 2 && !$0.replacementPackets.isEmpty }) else {
            throw OSprError.message("Unexpected frozen native-stop protocol")
        }
        let worker = WorkerClient(root: manifest.root, timeout: 120)
        defer { worker.shutdown() }
        var rows = [[String: Any]]()
        for item in manifest.cases {
            var control = ""
            for policy in ["normal", "already-cancelled", "cancel-while-awaiting"] {
                let id = try await begin(worker)
                let before = try await pid(worker)
                let timing = PacketTiming()
                var cancellation = [String: Any]()
                let first: [String: Any]
                if policy == "normal" {
                    timing.start(cancelled: false)
                    first = try await feed(worker, item.packets[0], id)
                    timing.finish()
                } else if policy == "already-cancelled" {
                    let gate = AsyncStream<Void>.makeStream()
                    let task = Task { () throws -> [String: Any] in
                        for await _ in gate.stream {}
                        timing.start(cancelled: Task.isCancelled)
                        let result = try await feed(worker, item.packets[0], id)
                        timing.finish()
                        return result
                    }
                    task.cancel()
                    gate.continuation.finish()
                    first = try await task.value
                    guard timing.snapshot().2 else { throw OSprError.message("Task was not cancelled before request") }
                    cancellation["cancelled_before_request"] = true
                } else {
                    let task = Task { () throws -> [String: Any] in
                        timing.start(cancelled: Task.isCancelled)
                        let result = try await feed(worker, item.packets[0], id)
                        timing.finish()
                        return result
                    }
                    try await Task.sleep(for: .milliseconds(manifest.cancelAfterMS))
                    let at = ProcessInfo.processInfo.systemUptime
                    task.cancel()
                    first = try await task.value
                    let (start, finish, _) = timing.snapshot()
                    cancellation["cancel_at_uptime"] = at
                    cancellation["cancel_between_request_and_return"] = start.map { $0 < at && at < (finish ?? 0) } ?? false
                    // The interval is observed, not assumed: a fast reply can finish
                    // before the timer and is then reported as an unexercised case.
                }
                let tail = try await feed(worker, item.packets[1], id)
                let final = try await end(worker, id)
                let after = try await pid(worker)
                let text = final["text"] as? String ?? ""
                if policy == "normal" { control = text }
                guard !text.isEmpty, text == control, before == after else { throw OSprError.message("Stop path changed text or restarted worker") }
                let (start, finish, _) = timing.snapshot()
                rows.append(["id": item.id, "rate": item.rate, "policy": policy, "worker_pid_before": before,
                    "worker_pid_after": after, "first_request_start_uptime": start ?? 0,
                    "first_request_return_uptime": finish ?? 0, "first_response": first, "tail_response": tail,
                    "final": final, "text_matches_control": text == control, "cancellation": cancellation])
            }
            // Replacement cancels old engine state. A delayed cancel for the old
            // UUID must not clear the new session, including its resampler tail.
            let old = try await begin(worker)
            _ = try await feed(worker, item.packets[0], old)
            let next = try await begin(worker)
            let stale = try await worker.request(["action": "stream_cancel", "session_id": old])
            guard stale["cancelled"] as? Bool == false else { throw OSprError.message("Stale cancel affected new session") }
            for path in item.replacementPackets { _ = try await feed(worker, path, next) }
            let replaced = try await end(worker, next)
            let fresh = try await begin(worker)
            for path in item.replacementPackets { _ = try await feed(worker, path, fresh) }
            let freshResult = try await end(worker, fresh)
            guard replaced["text"] as? String == freshResult["text"] as? String else { throw OSprError.message("Replacement leaked prior text") }
            rows.append(["id": item.id, "rate": item.rate, "policy": "replacement-and-stale-cancel", "stale_cancel": stale,
                         "final": replaced, "fresh_control": freshResult, "text_matches_control": true])

            // WorkerClient deliberately restarts after an inference/protocol
            // rejection. The complete recording must remain usable for fallback.
            let body: [String: Any] = ["action": "transcribe", "path": item.fullSource,
                "model": "nemotron-streaming", "language": "en", "trim": false]
            let fallbackControl = try await worker.request(body)
            let broken = try await begin(worker)
            _ = try await feed(worker, item.packets[0], broken)
            let beforeError = try await pid(worker)
            var rejection = ""
            do { _ = try await feed(worker, item.changedRateTail, broken) }
            catch { rejection = error.localizedDescription }
            guard rejection.contains("sample rate changed") else { throw OSprError.message("Expected native rate rejection") }
            let recovered = try await worker.request(body)
            let afterError = try await pid(worker)
            guard recovered["text"] as? String == fallbackControl["text"] as? String, beforeError != afterError else {
                throw OSprError.message("Full-file fallback failed after worker restart")
            }
            rows.append(["id": item.id, "rate": item.rate, "policy": "rate-error-full-file-fallback", "rejection": rejection,
                "worker_pid_before": beforeError, "worker_pid_after": afterError,
                "final": recovered, "fresh_control": fallbackControl, "text_matches_control": true])
        }
        return ["records": rows, "boundary": "Compiled unchanged shipping WorkerClient plus a standalone public-fixture harness; real owned Python worker and cached Metal Nemotron. No microphone, Capture snapshot, AppModel, UI, insertion or physical device acceptance. Timer cancellation is an observed caller-request interval, not proof of a GPU kernel running at that instant."]
    }
    static func main() async {
        do {
            guard CommandLine.arguments.count == 2 else { throw OSprError.message("Provide native-stop manifest") }
            let file = URL(fileURLWithPath: CommandLine.arguments[1])
            let data = try Data(contentsOf: file)
            guard data.count <= 1024 * 1024 else { throw OSprError.message("Manifest too large") }
            let manifest = try JSONDecoder().decode(Manifest.self, from: data)
            let result = try await run(manifest)
            let bytes = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .prettyPrinted])
            FileHandle.standardOutput.write(bytes + Data([10]))
        } catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
            exit(1)
        }
    }
}
