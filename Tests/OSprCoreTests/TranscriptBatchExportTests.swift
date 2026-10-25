import XCTest
@testable import OSprCore

final class TranscriptBatchExportTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("OSpr-bulk-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }; return url
    }
    private func record(_ n: Int) -> Transcript {
        Transcript(rawText: "Original \(n)", text: "Edited \(n)", model: "fixture", mode: .verbatim, duration: 1, latencyMS: 1,
            segments: [Segment(start: 0, end: 1, text: "Original \(n)")], source: "same.wav")
    }
    private func index(_ url: URL) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url.appendingPathComponent("index.json"))) as? [String: Any])
    }
    func testExportIncludesUnloadedPagesPendingEditsDeletesAndSessionOnlyRecords() async throws {
        let root = try directory(), data = root.appendingPathComponent("data")
        let repository = HistoryRepository(directory: data, saveHistory: false)
        var records = (0..<235).map(record)
        for value in records { repository.submit(value, delay: 60) }
        records[0].text = "Last edit before export"
        repository.submit(records[0], delay: 60); repository.remove(ids: [records[1].id])
        let destination = root.appendingPathComponent("all")
        let result = try await repository.export(to: destination, format: .json)
        XCTAssertEqual(result.count, 234)
        let manifest = try index(destination)
        XCTAssertEqual(manifest["count"] as? Int, 234)
        XCTAssertEqual(manifest["audio_included"] as? Bool, false)
        let encoder = JSONDecoder(); encoder.dateDecodingStrategy = .iso8601
        let saved = try encoder.decode(Transcript.self, from: Data(contentsOf: destination.appendingPathComponent(TranscriptExport.filename(records[0], format: .json))))
        XCTAssertEqual(saved.text, "Last edit before export"); XCTAssertEqual(saved.rawText, "Original 0")
        XCTAssertFalse(try HistoryDatabase.storageExists(directory: data))
        let entries = try XCTUnwrap(manifest["records"] as? [[String: Any]])
        XCTAssertEqual(Set(entries.compactMap { $0["file"] as? String }).count, 234)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: destination.path)[.posixPermissions] as? Int, 0o700)
        for entry in entries {
            let name = try XCTUnwrap(entry["file"] as? String)
            XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: destination.appendingPathComponent(name).path)[.posixPermissions] as? Int, 0o600)
        }
    }
    func testSearchUsesCompleteArchiveAndSubtitlesKeepOriginalTiming() async throws {
        let root = try directory(), repository = HistoryRepository(directory: root.appendingPathComponent("data"))
        for n in 0..<205 { repository.submit(record(n), delay: 60) }
        let result = try await repository.export(to: root.appendingPathComponent("match"), format: .srt, query: "Original 0")
        XCTAssertEqual(result.count, 1)
        let manifest = try index(result.directory), entries = try XCTUnwrap(manifest["records"] as? [[String: Any]])
        let name = try XCTUnwrap(entries.first?["file"] as? String)
        let text = try String(contentsOf: result.directory.appendingPathComponent(name), encoding: .utf8)
        XCTAssertTrue(text.contains("00:00:00,000 --> 00:00:01,000")); XCTAssertTrue(text.contains("Original 0")); XCTAssertFalse(text.contains("Edited"))
    }
    func testCancellationAndEncodingFailurePublishNothingAndRemoveStaging() throws {
        let root = try directory(), destination = root.appendingPathComponent("cancelled")
        var checks = 0
        XCTAssertThrowsError(try TranscriptBatchExport.write(to: destination, format: .txt, query: "", checkCancellation: {
            checks += 1; if checks > 1 { throw CancellationError() }
        }, enumerate: { visit in try visit(self.record(0)); try visit(self.record(1)) }))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        var broken = record(1); broken.duration = .infinity
        XCTAssertThrowsError(try TranscriptBatchExport.write(to: destination, format: .json, query: "", checkCancellation: {}, enumerate: {
            try $0(self.record(0)); try $0(broken)
        }))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }
    func testExistingDestinationIncludingPublishRaceRemainsIntact() throws {
        let root = try directory(), destination = root.appendingPathComponent("existing")
        XCTAssertThrowsError(try TranscriptBatchExport.write(to: destination, format: .txt, query: "", checkCancellation: {}, enumerate: {
            try $0(self.record(0))
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
            try Data("keep".utf8).write(to: destination.appendingPathComponent("sentinel"))
        }))
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("sentinel"), encoding: .utf8), "keep")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["existing"])
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: destination)
        XCTAssertThrowsError(try TranscriptBatchExport.write(to: link, format: .txt, query: "", checkCancellation: {}, enumerate: { try $0(self.record(0)) }))
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("sentinel"), encoding: .utf8), "keep")
    }
    func testFilenameCannotTraverseAndDuplicateSourcesStayDistinct() throws {
        var first = record(0), second = record(1)
        first.source = "../../\u{202e}evil:\n.wav"; second.source = first.source
        let name = TranscriptExport.filename(first, format: .txt)
        XCTAssertFalse(name.contains("/")); XCTAssertFalse(name.contains(":")); XCTAssertFalse(name.contains("\n")); XCTAssertFalse(name.contains("\u{202e}"))
        XCTAssertNotEqual(name, TranscriptExport.filename(second, format: .txt))
        first.source = String(repeating: "界", count: 1000) + ".wav"
        XCTAssertLessThan(TranscriptExport.filename(first, format: .json).utf8.count, 180)
        XCTAssertEqual(String(data: try TranscriptExport.data(first, format: .txt), encoding: .utf8), first.text)
        XCTAssertTrue(String(data: try TranscriptExport.data(first, format: .vtt), encoding: .utf8)!.hasPrefix("WEBVTT"))
    }

    func testFailedPendingCommitCannotExportStaleText() async throws {
        let root = try directory(), data = root.appendingPathComponent("data")
        let database = try HistoryDatabase(directory: data)
        var value = record(0); try database.upsert([value]); database.close()
        let repository = HistoryRepository(open: { try HistoryDatabase(directory: data) }, reset: { try HistoryDatabase.reset(directory: data) },
            beforeCommit: { throw OSprError.message("disk fixture failure") })
        value.text = "Unsaved newer text"; repository.submit(value, delay: 60)
        do { _ = try await repository.export(to: root.appendingPathComponent("export"), format: .json); XCTFail("Must not export stale disk payload") } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("export").path))
        let pending = try await repository.record(id: value.id)
        XCTAssertEqual(pending?.text, "Unsaved newer text")
    }

    func testRepositoryCancellationDuringCommitDoesNotPublishAndRetainsAdmittedText() async throws {
        let root = try directory(), data = root.appendingPathComponent("data")
        let started = expectation(description: "export commit held"), gate = DispatchSemaphore(value: 0)
        let repository = HistoryRepository(open: { try HistoryDatabase(directory: data) },
            reset: { try HistoryDatabase.reset(directory: data) }, beforeCommit: { started.fulfill(); gate.wait() })
        let item = record(0); repository.submit(item, delay: 60)
        let task = Task { try await repository.export(to: root.appendingPathComponent("cancel"), format: .txt) }
        await fulfillment(of: [started], timeout: 2)
        task.cancel(); gate.signal()
        do { _ = try await task.value; XCTFail("Cancelled export must reject") } catch is CancellationError {} catch { XCTFail("Wrong error: \(error)") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("cancel").path))
        let retained = try await repository.record(id: item.id)
        XCTAssertEqual(retained?.text, item.text)
    }
}
