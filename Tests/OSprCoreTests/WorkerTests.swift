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
}

private final class ProgressCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Int] = []
    func append(_ value: Int) { lock.lock(); defer { lock.unlock() }; storage.append(value) }
    var values: [Int] { lock.lock(); defer { lock.unlock() }; return storage }
}
