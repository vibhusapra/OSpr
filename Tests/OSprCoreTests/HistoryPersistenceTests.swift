import XCTest
@testable import OSprCore

final class HistoryPersistenceTests: XCTestCase {
    private func record(_ text: String) -> Transcript {
        Transcript(rawText: text, text: text, model: "fixture", mode: .verbatim, duration: 1, latencyMS: 1)
    }
    private func temporary() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("OSpr-history-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    func testRapidEditsCoalesceOffTheCallingThreadAndFlushLatest() async throws {
        let received = WriteCapture()
        let writer = HistoryPersistence(write: { items in received.append(items.map(\.text), main: Thread.isMainThread) })
        var item = record("initial")
        for index in 0..<100 {
            item.text = "Edit \(index)"
            writer.submit([item], delay: 60)
        }
        try await writer.flushAsync()
        XCTAssertEqual(received.rows, [["Edit 99"]])
        XCTAssertFalse(received.usedMainThread)
    }

    func testClearAfterInFlightSaveCannotResurrectDeletedHistory() throws {
        let received = WriteCapture()
        let started = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let writer = HistoryPersistence(write: { items in
            if !items.isEmpty { started.signal(); _ = release.wait(timeout: .now() + 5) }
            received.append(items.map(\.text), main: Thread.isMainThread)
        })
        writer.submit([record("private")])
        XCTAssertEqual(started.wait(timeout: .now() + 2), .success)
        writer.submit([], allowReset: true)
        release.signal()
        try writer.flush()
        XCTAssertEqual(received.rows, [["private"], []])
    }

    func testUnreadableHistoryIsPreservedUntilExplicitReset() throws {
        let directory = try temporary()
        let path = directory.appendingPathComponent("history.json")
        try Data("original unreadable bytes".utf8).write(to: path)
        let writer = try HistoryPersistence(directory: directory)
        writer.submit([record("new words")], delay: 60)
        XCTAssertThrowsError(try writer.flush())
        XCTAssertEqual(try String(contentsOf: path, encoding: .utf8), "original unreadable bytes")
        writer.submit([], delay: 60, allowReset: true)
        try writer.flush()
        XCTAssertTrue(try XCTUnwrap(LocalStore(directory: directory).read([Transcript].self, name: "history.json")).isEmpty)
        let mode = try FileManager.default.attributesOfItem(atPath: path.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
    }

    func testFailedWriteRetainsNewestSnapshotForAsyncRetry() async throws {
        let capture = WriteCapture()
        let writer = HistoryPersistence(write: { items in
            if capture.failOnce() { throw OSprError.message("Simulated disk failure") }
            capture.append(items.map(\.text), main: Thread.isMainThread)
        })
        writer.submit([record("keep this latest version")], delay: 60)
        do { try writer.flush(); XCTFail("Expected write failure") }
        catch { XCTAssertEqual(error.localizedDescription, "Simulated disk failure") }
        try await writer.flushAsync()
        XCTAssertEqual(capture.rows, [["keep this latest version"]])
    }

    func testCancelledDebounceCannotOverwriteNewerSnapshot() async throws {
        let directory = try temporary()
        let writer = try HistoryPersistence(directory: directory)
        writer.submit([record("old")], delay: 0.05)
        writer.submit([record("new")])
        try await writer.flushAsync()
        try await Task.sleep(nanoseconds: 100_000_000)
        let saved = try XCTUnwrap(LocalStore(directory: directory).read([Transcript].self, name: "history.json"))
        XCTAssertEqual(saved.map(\.text), ["new"])
        withExtendedLifetime(writer) {}
    }
}

private final class WriteCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [[String]] = []
    private var main = false
    private var shouldFail = true
    func append(_ row: [String], main: Bool) { lock.lock(); defer { lock.unlock() }; values.append(row); self.main = self.main || main }
    func failOnce() -> Bool { lock.lock(); defer { lock.unlock() }; let value = shouldFail; shouldFail = false; return value }
    var rows: [[String]] { lock.lock(); defer { lock.unlock() }; return values }
    var usedMainThread: Bool { lock.lock(); defer { lock.unlock() }; return main }
}
