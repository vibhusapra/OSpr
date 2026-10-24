import XCTest
@testable import OSpr
@testable import OSprCore

@MainActor private final class SummaryResponseGate {
    var continuation: CheckedContinuation<[String: Any], Never>?
    func wait() async -> [String: Any] { await withCheckedContinuation { continuation = $0 } }
    func finish(_ response: [String: Any]) { continuation?.resume(returning: response); continuation = nil }
}

final class MeetingSummaryLifecycleTests: XCTestCase {
    private func directory() throws -> URL {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("OSpr-summary-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: path) }; return path
    }
    @MainActor private func settle(_ condition: () -> Bool) async throws {
        for _ in 0..<400 {
            if condition() { return }; try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Summary state did not settle")
    }
    private func record(_ text: String) -> Transcript { .init(rawText: text, text: "Edited: " + text, model: "fixture", mode: .clean, duration: 1, latencyMS: 2) }
    private func payload(_ text: String) -> [String: Any] {
        ["items": [["section": "decisions", "text": "Hold the Friday release.", "source_ids": [0]]],
         "excerpts": [["id": 0, "text": text]], "model": "local-fixture", "chunks": 1]
    }
    @MainActor func testCompletedSummaryUpdatesItsRecordAfterSelectionMovesWithoutChangingTextOrExcerpts() async throws {
        let path = try directory(), gate = SummaryResponseGate(), source = "Do not ship Friday."
        var first = record(source); let second = record("Other transcript.")
        first.notes = try MeetingNotes(source: source, excerpts: [.init(id: 0, text: source)], model: "extractive")
        let app = AppModel(instanceLock: try AppInstanceLock(directory: path), directory: path, enableServices: false,
                           summaryRequest: { text in XCTAssertEqual(text, source); return await gate.wait() })
        try await settle { !app.audioMaintenance }
        app.historyState.submit(first, select: true); app.historyState.submit(second, select: false)
        try await app.historyState.flush()
        app.generateSummary(first); try await settle { gate.continuation != nil }
        app.selection = second.id; try await settle { app.selected?.id == second.id }
        gate.finish(payload(source)); try await settle { app.phase == "idle" }
        XCTAssertTrue(app.error.isEmpty, app.error)
        let loaded = try await app.historyState.record(id: first.id)
        XCTAssertEqual(loaded?.text, first.text); XCTAssertEqual(loaded?.rawText, source)
        XCTAssertEqual(loaded?.notes?.model, "extractive"); XCTAssertEqual(loaded?.summary?.items.first?.text, "Hold the Friday release.")
        XCTAssertEqual(app.selected?.id, second.id)
        try await app.prepareForTermination()
        let disk = try HistoryDatabase(directory: path)
        XCTAssertEqual(try disk.record(id: first.id)?.summary?.model, "local-fixture")
    }
    @MainActor func testCancelledLateResponseAndInvalidCitationsPreservePriorSummary() async throws {
        let path = try directory(), gate = SummaryResponseGate(), source = "Do not ship Friday."
        var first = record(source)
        first.summary = try MeetingSummary(source: source, items: [.init(section: .decisions, text: "Friday release is held.", sourceIDs: [0])], excerpts: [.init(id: 0, text: source)], model: "previous", chunks: 1)
        let app = AppModel(instanceLock: try AppInstanceLock(directory: path), directory: path, enableServices: false,
                           summaryRequest: { _ in await gate.wait() })
        try await settle { !app.audioMaintenance }
        app.historyState.submit(first, select: true); try await app.historyState.flush()
        app.generateSummary(first); try await settle { gate.continuation != nil }
        app.cancel(); gate.finish(payload(source))
        try await Task.sleep(for: .milliseconds(30)); try await app.historyState.flush()
        var loaded = try await app.historyState.record(id: first.id)
        XCTAssertEqual(loaded?.summary?.model, "previous")
        app.generateSummary(first); try await settle { gate.continuation != nil }
        gate.finish(payload("Fabricated quote")); try await settle { app.phase == "idle" }
        XCTAssertFalse(app.error.isEmpty)
        XCTAssertEqual(app.status, "Summary not saved · previous notes retained")
        loaded = try await app.historyState.record(id: first.id)
        XCTAssertEqual(loaded?.summary?.model, "previous"); XCTAssertEqual(loaded?.text, first.text)
        try await app.prepareForTermination()
    }
}
