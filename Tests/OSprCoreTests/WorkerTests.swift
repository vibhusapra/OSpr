import XCTest
@testable import OSprCore

final class WorkerTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("OSpr-worker-test-" + UUID().uuidString)
        let backend = directory.appendingPathComponent("backend/ospr_backend")
        let bin = directory.appendingPathComponent(".venv/bin")
        try FileManager.default.createDirectory(at: backend, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let launcher = bin.appendingPathComponent("python")
        try Data("#!/bin/sh\nexec /usr/bin/python3 \"$@\"\n".utf8).write(to: launcher)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: launcher.path)
        try Data().write(to: backend.appendingPathComponent("__init__.py"))
        let source = """
        import json, sys, time, signal, os
        for line in sys.stdin:
            request = json.loads(line)
            if request.get('action') == 'ignore-termination':
                signal.signal(signal.SIGTERM, signal.SIG_IGN)
                time.sleep(30)
            if request.get('action') == 'sleep': time.sleep(5)
            print(json.dumps({'id': request['id'], 'ok': True, 'result': {'value': request.get('value', 'ready'), 'pid': os.getpid()}}), flush=True)
        """
        try Data(source.utf8).write(to: backend.appendingPathComponent("worker.py"))
    }
    override func tearDown() { try? FileManager.default.removeItem(at: directory) }
    func testConcurrentRequestsAreSerializedWithoutResponseMixups() async throws {
        let worker = WorkerClient(root: directory.path)
        defer { worker.shutdown() }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<30 {
                group.addTask {
                    let result = try await worker.request(["action": "ping", "value": index])
                    XCTAssertEqual(result["value"] as? Int, index)
                }
            }
            try await group.waitForAll()
        }
    }
    func testProgressFramesCannotBeMistakenForFinalReplies() async throws {
        let source = directory.appendingPathComponent("backend/ospr_backend/worker.py")
        let workerSource = """
        import json, sys
        for line in sys.stdin:
            request = json.loads(line)
            if request.get('action') == 'download_model':
                for n in range(4):
                    print(json.dumps({'id': request['id'], 'event': 'progress', 'progress': {'completed_bytes': n}}))
            print(json.dumps({'id': request['id'], 'ok': True, 'result': {'complete': True}}), flush=True)
        """
        try workerSource.write(to: source, atomically: true, encoding: .utf8)
        let worker = WorkerClient(root: directory.path)
        defer { worker.shutdown() }
        let received = ProgressCollector()
        let result = try await worker.request(["action": "download_model"], progress: { event in received.append(event["completed_bytes"] as? Int ?? -1) })
        XCTAssertEqual(received.values, [0, 1, 2, 3])
        XCTAssertEqual(result["complete"] as? Bool, true)
        let next = try await worker.request(["action": "ping"])
        XCTAssertEqual(next["complete"] as? Bool, true)
    }

    func testProgressWithWrongRequestIDIsRejected() async throws {
        let source = directory.appendingPathComponent("backend/ospr_backend/worker.py")
        let workerSource = """
        import json, sys
        for line in sys.stdin:
            request = json.loads(line)
            if request.get('action') == 'download_model':
                print(json.dumps({'id': 'stale', 'event': 'progress', 'progress': {}}), flush=True)
            else:
                print(json.dumps({'id': request['id'], 'ok': True, 'result': {}}), flush=True)
        """
        try workerSource.write(to: source, atomically: true, encoding: .utf8)
        let worker = WorkerClient(root: directory.path)
        defer { worker.shutdown() }
        do { _ = try await worker.request(["action": "download_model"]); XCTFail("Expected protocol rejection") }
        catch { XCTAssertEqual(error.localizedDescription, "Invalid local engine response.") }
    }
    func testIdleShutdownCannotReuseTheTerminatingChild() async throws {
        let worker = WorkerClient(root: directory.path)
        defer { worker.shutdown() }
        let first = try await worker.request(["action": "ping"])
        worker.shutdown()
        let second = try await worker.request(["action": "ping"])
        XCTAssertNotEqual(first["pid"] as? Int, second["pid"] as? Int)
    }
    func testAudioPreparationRejectionKeepsWarmWorkerButInferenceFailureRestarts() async throws {
        let source = directory.appendingPathComponent("backend/ospr_backend/worker.py")
        try """
        import json, sys, os
        for line in sys.stdin:
            request = json.loads(line)
            if request.get('action') in ['prepare_review', 'warm']:
                print(json.dumps({'id': request['id'], 'ok': False, 'error': 'expected rejection'}), flush=True)
            else:
                print(json.dumps({'id': request['id'], 'ok': True, 'result': {'pid': os.getpid()}}), flush=True)
        """.write(to: source, atomically: true, encoding: .utf8)
        let worker = WorkerClient(root: directory.path)
        defer { worker.shutdown() }
        let original = try await worker.request(["action": "ping"])
        do { _ = try await worker.request(["action": "prepare_review"]); XCTFail("Expected size/codec rejection") }
        catch { XCTAssertEqual(error.localizedDescription, "expected rejection") }
        let preserved = try await worker.request(["action": "ping"])
        XCTAssertEqual(preserved["pid"] as? Int, original["pid"] as? Int)
        do { _ = try await worker.request(["action": "warm"]); XCTFail("Expected inference failure") }
        catch { XCTAssertEqual(error.localizedDescription, "expected rejection") }
        let restarted = try await worker.request(["action": "ping"])
        XCTAssertNotEqual(restarted["pid"] as? Int, original["pid"] as? Int)
    }
    func testMalformedPreparationReplyStillRestartsWorker() async throws {
        let source = directory.appendingPathComponent("backend/ospr_backend/worker.py")
        try """
        import json, sys, os
        for line in sys.stdin:
            request = json.loads(line)
            result = 'malformed' if request.get('action') == 'prepare_review' else {'pid': os.getpid()}
            print(json.dumps({'id': request['id'], 'ok': True, 'result': result}), flush=True)
        """.write(to: source, atomically: true, encoding: .utf8)
        let worker = WorkerClient(root: directory.path)
        defer { worker.shutdown() }
        let first = try await worker.request(["action": "ping"])
        do { _ = try await worker.request(["action": "prepare_review"]); XCTFail("Expected malformed reply rejection") }
        catch { XCTAssertEqual(error.localizedDescription, "Invalid local engine response.") }
        let next = try await worker.request(["action": "ping"])
        XCTAssertNotEqual(first["pid"] as? Int, next["pid"] as? Int)
    }
    func testTextOutputLimitKeepsWarmWorkerOnlyForTextActions() async throws {
        let source = directory.appendingPathComponent("backend/ospr_backend/worker.py")
        try """
        import json, sys, os
        for line in sys.stdin:
            request = json.loads(line)
            if request.get('action') == 'ping':
                response = {'id': request['id'], 'ok': True, 'result': {'pid': os.getpid()}}
            else:
                response = {'id': request['id'], 'ok': False, 'error': 'Original retained.', 'error_kind': request.get('kind')}
            print(json.dumps(response), flush=True)
        """.write(to: source, atomically: true, encoding: .utf8)
        let worker = WorkerClient(root: directory.path)
        defer { worker.shutdown() }
        for (action, kind, preserve) in [
            ("rewrite", "text-output-limit", true),
            ("notes", "text-output-limit", true),
            ("summary", "text-output-limit", true),
            ("rewrite", "text-model-not-prepared", true),
            ("summary", "text-model-not-prepared", false),
            ("transcribe", "text-model-not-prepared", false),
            ("transcribe", "text-output-limit", false),
            ("warm", "text-output-limit", false),
            ("rewrite", "runtime", false),
            ("summary", "", false)
        ] {
            let before = try await worker.request(["action": "ping"])
            do {
                _ = try await worker.request(["action": action, "kind": kind])
                XCTFail("Expected rejection for \(action)")
            } catch { XCTAssertEqual(error.localizedDescription, "Original retained.") }
            let after = try await worker.request(["action": "ping"])
            XCTAssertEqual(before["pid"] as? Int == after["pid"] as? Int, preserve, "\(action) / \(kind)")
        }
    }
    func testAlreadyCancelledInferenceNeverStartsWorker() async throws {
        let source = directory.appendingPathComponent("backend/ospr_backend/worker.py")
        let original = try String(contentsOf: source, encoding: .utf8)
        try ("open(__file__ + '.started', 'w').write('started')\n" + original).write(to: source, atomically: true, encoding: .utf8)
        let worker = WorkerClient(root: directory.path)
        defer { worker.shutdown() }
        let pair = AsyncStream<Void>.makeStream()
        defer { pair.continuation.finish() }
        let task = Task { () throws -> [String: Any] in
            for await _ in pair.stream {}
            return try await worker.request(["action": "transcribe"])
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation before process admission") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path + ".started"))
    }
    func testCancelledPreviewStillFeedsItsAdmittedPacket() async throws {
        let worker = WorkerClient(root: directory.path)
        defer { worker.shutdown() }
        let pair = AsyncStream<Void>.makeStream()
        defer { pair.continuation.finish() }
        let task = Task { () throws -> [String: Any] in
            for await _ in pair.stream {}
            return try await worker.request(["action": "stream_feed", "value": "admitted packet"])
        }
        task.cancel()
        let response = try await task.value
        XCTAssertEqual(response["value"] as? String, "admitted packet")
    }
    func testHungStartupHasItsOwnDeadline() async throws {
        let source = directory.appendingPathComponent("backend/ospr_backend/worker.py")
        let original = try String(contentsOf: source, encoding: .utf8)
        try ("import time; time.sleep(10)\n" + original).write(to: source, atomically: true, encoding: .utf8)
        let worker = WorkerClient(root: directory.path, timeout: 30, startupTimeout: 0.3)
        defer { worker.shutdown() }
        let start = Date()
        do { _ = try await worker.request(["action": "ping"]); XCTFail("Expected startup timeout") }
        catch { XCTAssertTrue(error.localizedDescription.contains("stopped or timed out")) }
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
    }
    func testWorkerIgnoringTerminationIsKilledAndRestarted() async throws {
        let worker = WorkerClient(root: directory.path, timeout: 0.5)
        defer { worker.shutdown() }
        _ = try await worker.request(["action": "ping"])
        let start = Date()
        do { _ = try await worker.request(["action": "ignore-termination"]); XCTFail("Expected forced termination") }
        catch { XCTAssertTrue(error.localizedDescription.contains("stopped or timed out")) }
        XCTAssertGreaterThan(Date().timeIntervalSince(start), 1)
        XCTAssertLessThan(Date().timeIntervalSince(start), 4)
        let reply = try await worker.request(["action": "ping"])
        XCTAssertEqual(reply["value"] as? String, "ready")
    }
    func testTimeoutReapsWorkerAndNextRequestRestarts() async throws {
        let worker = WorkerClient(root: directory.path, timeout: 0.4)
        defer { worker.shutdown() }
        let start = Date()
        do { _ = try await worker.request(["action": "sleep"]); XCTFail("Expected timeout") }
        catch { XCTAssertTrue(error.localizedDescription.contains("stopped or timed out")) }
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
        let result = try await worker.request(["action": "ping"])
        XCTAssertEqual(result["value"] as? String, "ready")
    }
    func testLongRequestOverrideDoesNotDisableTheNextDefaultDeadline() async throws {
        let source = directory.appendingPathComponent("backend/ospr_backend/worker.py")
        var code = try String(contentsOf: source, encoding: .utf8)
        code = code.replacingOccurrences(of: "if request.get('action') == 'sleep': time.sleep(5)", with: "if request.get('action') == 'short-sleep': time.sleep(1)\n    if request.get('action') == 'sleep': time.sleep(5)")
        try code.write(to: source, atomically: true, encoding: .utf8)
        let worker = WorkerClient(root: directory.path, timeout: 0.5)
        defer { worker.shutdown() }
        _ = try await worker.request(["action": "ping"], timeout: 3)
        let result = try await worker.request(["action": "short-sleep"], timeout: 3)
        XCTAssertEqual(result["value"] as? String, "ready")
        do { _ = try await worker.request(["action": "sleep"]); XCTFail("Default deadline should still apply") }
        catch { XCTAssertTrue(error.localizedDescription.contains("timed out")) }
        let next = try await worker.request(["action": "ping"], timeout: 3)
        XCTAssertNotEqual(next["pid"] as? Int, result["pid"] as? Int)
    }
    func testInvalidRequestDeadlinesFailBeforeStartingAWorker() async throws {
        let source = directory.appendingPathComponent("backend/ospr_backend/worker.py")
        let marker = directory.appendingPathComponent("started")
        let code = "import pathlib\npathlib.Path(" + String(reflecting: marker.path) + ").touch()\n" + (try String(contentsOf: source, encoding: .utf8))
        try code.write(to: source, atomically: true, encoding: .utf8)
        let worker = WorkerClient(root: directory.path)
        defer { worker.shutdown() }
        for invalid in [0.0, -1, Double.nan, Double.infinity, 3601] {
            do { _ = try await worker.request(["action": "ping"], timeout: invalid); XCTFail("Invalid deadline accepted") }
            catch { XCTAssertEqual(error.localizedDescription, "Invalid worker request deadline.") }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        _ = try await worker.request(["action": "ping"], timeout: 3)
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
    }

}

private final class ProgressCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Int] = []
    func append(_ value: Int) { lock.lock(); defer { lock.unlock() }; storage.append(value) }
    var values: [Int] { lock.lock(); defer { lock.unlock() }; return storage }
}
