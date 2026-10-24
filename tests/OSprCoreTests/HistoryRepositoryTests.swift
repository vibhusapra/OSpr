import Foundation
import XCTest
@testable import OSprCore

final class HistoryRepositoryTests: XCTestCase {
    private func directory() throws -> URL {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("OSpr-repository-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: path) }
        return path
    }
    private func record(_ text: String, audio: String? = nil) -> Transcript {
        var value = Transcript(rawText: text, text: text, model: "fixture", mode: .clean, duration: 1, latencyMS: 2,
            segments: [Segment(start: 0, end: 1, text: text, speaker: 2)],
            words: [Segment(start: 0.125, end: 0.875, text: text, speaker: 2, overlapSpeakers: [1, 2])])
        value.audioFile = audio; return value
    }
    private func canonical(_ record: Transcript) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return try encoder.encode(record)
    }
    private func repository(_ path: URL, boundary: RepositoryBoundary) -> HistoryRepository {
        HistoryRepository(open: { boundary.didOpen(); return try HistoryDatabase(directory: path) },
            reset: { try HistoryDatabase.reset(directory: path) }, beforeCommit: { try boundary.commit() })
    }

    @MainActor func testConstructionDoesNoIOAndSlowOpeningLeavesUIExecutorFree() async throws {
        let path = try directory(), boundary = RepositoryBoundary(), release = DispatchSemaphore(value: 0)
        let started = expectation(description: "background open")
        let value = HistoryRepository(open: {
            boundary.didOpen(); started.fulfill()
            guard release.wait(timeout: .now() + 3) == .success else { throw OSprError.message("Timed out test gate") }
            return try HistoryDatabase(directory: path)
        }, reset: { try HistoryDatabase.reset(directory: path) })
        XCTAssertEqual(boundary.opens, 0)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: path.path).isEmpty)
        let task = Task { try await value.page() }
        await fulfillment(of: [started], timeout: 2)
        XCTAssertFalse(boundary.usedMainThread)
        // This resumes on MainActor while SQLite's private queue is still gated.
        XCTAssertTrue(Thread.isMainThread)
        release.signal()
        let page = try await task.value
        XCTAssertTrue(page.rows.isEmpty)
    }

    func testRapidEditsCoalesceAndPreserveFullDetailsOffCallingThread() async throws {
        let path = try directory(), boundary = RepositoryBoundary(), value = repository(path, boundary: boundary)
        var item = record("Original with timing", audio: "owned.wav")
        item.notes = try MeetingNotes(source: item.rawText, excerpts: [NoteExcerpt(id: 0, text: item.rawText)], model: "fixture")
        let observed = expectation(description: "latest callback")
        for index in 0..<100 {
            item.text = "Edit \(index)"
            value.submit(item, delay: 60) { result in
                boundary.callback()
                XCTAssertNil(result.failure)
                if index == 99 { observed.fulfill() } else { XCTFail("Superseded observer") }
            }
        }
        let pending = try await value.record(id: item.id)
        XCTAssertEqual(try canonical(XCTUnwrap(pending)), try canonical(item))
        XCTAssertEqual(boundary.commits, 0) // Reading an edit does not force a save.
        try await value.flushAsync()
        await fulfillment(of: [observed], timeout: 2)
        XCTAssertEqual(boundary.commits, 1)
        XCTAssertFalse(boundary.usedMainThread)
        let detail = try await value.record(id: item.id)
        XCTAssertEqual(try canonical(XCTUnwrap(detail)), try canonical(item))
        let stats = try await value.statistics()
        XCTAssertEqual(stats, HistoryStatistics(records: 1, words: 2))
    }

    func testDifferentNewIDsRetainAdmissionOrderWhenAnOlderPendingRowIsEdited() async throws {
        let path = try directory(), value = HistoryRepository(directory: path)
        var first = record("First"), second = record("Second"), third = record("Third")
        second.date = first.date.addingTimeInterval(-100); third.date = second.date.addingTimeInterval(-100)
        value.submit(first, delay: 60); value.submit(second, delay: 60)
        first.text = "Edited oldest"; value.submit(first, delay: 60); value.submit(third, delay: 60)
        // Query is a read-your-writes barrier even before the debounce expires.
        let page = try await value.page()
        XCTAssertEqual(page.rows.map(\.id), [third.id, second.id, first.id])
        let next = try await value.page(query: "Edited")
        XCTAssertEqual(next.rows.map(\.id), [first.id])
    }

    func testFailedWriteRetainsAllPendingRowsAndLatestReplacementForRetry() async throws {
        let path = try directory(), boundary = RepositoryBoundary(), value = repository(path, boundary: boundary)
        var first = record("Old edit")
        let second = record("Keep second")
        boundary.fail = true
        value.submit(first, delay: 60); value.submit(second, delay: 60)
        do { try await value.flushAsync(); XCTFail("Expected simulated failure") } catch {}
        first.text = "Newest edit"; value.submit(first, delay: 60)
        boundary.fail = false
        try await value.flushAsync()
        let page = try await value.page()
        XCTAssertEqual(page.rows.map(\.id), [second.id, first.id])
        let detail = try await value.record(id: first.id)
        XCTAssertEqual(detail?.text, "Newest edit")
        XCTAssertEqual(boundary.commits, 2)
    }

    func testEncodingFailureRollsBackTheWholeBatchAndCanBeCorrected() async throws {
        let path = try directory(), value = HistoryRepository(directory: path)
        var original = record("Before"), invalid = record("Invalid")
        value.submit(original, delay: 60); try await value.flushAsync()
        original.text = "After"; invalid.duration = .infinity
        value.submit(original, delay: 60); value.submit(invalid, delay: 60)
        do { try await value.flushAsync(); XCTFail("Expected nonfinite JSON error") } catch {}
        let observed = try HistoryDatabase(directory: path)
        XCTAssertEqual(try observed.record(id: original.id)?.text, "Before")
        XCTAssertEqual(try observed.statistics().records, 1)
        invalid.duration = 2; value.submit(invalid, delay: 60)
        try await value.flushAsync()
        let detail = try await value.record(id: original.id)
        XCTAssertEqual(detail?.text, "After")
        XCTAssertEqual(try observed.statistics().records, 2)
        try observed.verifyIntegrity()
    }

    func testDeletionSupersedesInvalidPendingEditAndFailureRetainsItsTombstone() async throws {
        let path = try directory(), boundary = RepositoryBoundary(), value = repository(path, boundary: boundary)
        var item = record("Delete me", audio: "owned.wav")
        value.submit(item, delay: 60); try await value.flushAsync()
        item.duration = .nan; value.submit(item, delay: 60)
        boundary.fail = true
        let failed = expectation(description: "failed delete")
        value.remove(ids: [item.id]) { result in
            if result.failure != nil { failed.fulfill() }
        }
        await fulfillment(of: [failed], timeout: 2)
        let pending = try await value.record(id: item.id)
        XCTAssertNil(pending)
        boundary.fail = false
        let audio = try await value.flushAsync()
        XCTAssertEqual(audio, ["owned.wav"])
        let stats = try await value.statistics()
        XCTAssertEqual(stats.records, 0)
    }

    func testClearReplacesFailedPendingDataAndOldDebounceNeverResurrectsIt() async throws {
        let path = try directory(), value = HistoryRepository(directory: path)
        var invalid = record("Private old words"); invalid.duration = .nan
        value.submit(invalid, delay: 0.04)
        do { try await value.flushAsync(); XCTFail("Expected failure") } catch {}
        value.clear(); let fresh = record("Fresh after clear"); value.submit(fresh, delay: 60)
        try await value.flushAsync()
        try await Task.sleep(nanoseconds: 80_000_000)
        let page = try await value.page()
        XCTAssertEqual(page.rows.map(\.id), [fresh.id])
        let old = try await value.page(query: "Private old")
        XCTAssertTrue(old.rows.isEmpty)
    }

    func testClearAfterAnInFlightSaveKeepsOnlyLaterAdmissions() async throws {
        let path = try directory(), boundary = RepositoryBoundary()
        let started = expectation(description: "in-flight save"), release = DispatchSemaphore(value: 0)
        let value = HistoryRepository(open: { try HistoryDatabase(directory: path) }, reset: { try HistoryDatabase.reset(directory: path) }, beforeCommit: {
            if boundary.commits == 0 {
                started.fulfill()
                guard release.wait(timeout: .now() + 3) == .success else { throw OSprError.message("Timed out test gate") }
            }
            try boundary.commit()
        })
        value.submit(record("Old data", audio: "old.wav"))
        await fulfillment(of: [started], timeout: 2)
        value.clear(); let fresh = record("Later data"); value.submit(fresh, delay: 60)
        release.signal(); try await value.flushAsync()
        let page = try await value.page()
        XCTAssertEqual(page.rows.map(\.id), [fresh.id])
        XCTAssertFalse(boundary.usedMainThread)
    }

    func testUnreadableSourcePreservedUntilExplicitClearThenNewRowsCanSave() async throws {
        let path = try directory(), legacy = path.appendingPathComponent("history.json")
        let bytes = Data("Original malformed source".utf8); try bytes.write(to: legacy)
        let value = HistoryRepository(directory: path), unsaved = record("Keep in session")
        value.submit(unsaved, delay: 60)
        do { try await value.flushAsync(); XCTFail("Expected migration failure") } catch {}
        XCTAssertEqual(try Data(contentsOf: legacy), bytes)
        let pending = try await value.record(id: unsaved.id)
        XCTAssertEqual(pending?.text, unsaved.text)
        value.clear(); let fresh = record("After explicit reset"); value.submit(fresh, delay: 60)
        try await value.flushAsync()
        let page = try await value.page()
        XCTAssertEqual(page.rows.map(\.id), [fresh.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
        let mode = try FileManager.default.attributesOfItem(atPath: path.appendingPathComponent(HistoryDatabase.fileName).path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
    }

    func testCompleteArchiveRetentionAndAudioStrippingIncludeUnloadedRows() async throws {
        let path = try directory(), value = HistoryRepository(directory: path)
        var expired = record("Expired", audio: "shared.wav")
        let retained = record("Kept", audio: "shared.wav")
        expired.date = Date().addingTimeInterval(-10 * 86400)
        let items = (0..<240).map { record("Record \($0)", audio: "\($0).wav") }
        for item in [expired, retained] + items { value.submit(item, delay: 60) }
        try await value.flushAsync()
        let firstPage = try await value.page(limit: 5)
        XCTAssertEqual(firstPage.rows.count, 5)
        value.setRetention(days: 1); try await value.flushAsync()
        let old = try await value.record(id: expired.id)
        XCTAssertNil(old)
        let audio = try await value.audioFiles()
        XCTAssertTrue(audio.contains("shared.wav")) // Another row still owns it.
        value.stripAudio(.names(["shared.wav"]))
        try await value.flushAsync() // UI may still hold the old full detail.
        value.updateText(id: retained.id, text: "Edited concurrently", delay: 60)
        try await value.flushAsync()
        let detail = try await value.record(id: retained.id)
        XCTAssertNil(detail?.audioFile)
        value.stripAudio(); try await value.flushAsync()
        let allAudio = try await value.audioFiles()
        XCTAssertTrue(allAudio.isEmpty)
        let stats = try await value.statistics()
        XCTAssertEqual(stats.records, 241)
    }

    func testFieldMutationsPreserveConcurrentTextNotesTimingAndAudioEvictions() async throws {
        let path = try directory(), value = HistoryRepository(directory: path)
        let original = record("Original source", audio: "owned.wav")
        value.submit(original, delay: 60); try await value.flushAsync()
        let notes = try MeetingNotes(source: original.rawText, excerpts: [NoteExcerpt(id: 0, text: original.rawText)], model: "fixture")
        value.updateText(id: original.id, text: "Edited text", delay: 60)
        value.updateNotes(id: original.id, notes: notes, expectedRawText: original.rawText)
        value.stripAudio()
        value.updateText(id: original.id, text: "Latest edit", delay: 60)
        try await value.flushAsync()
        let loaded = try await value.record(id: original.id)
        let detail = try XCTUnwrap(loaded)
        XCTAssertEqual(detail.text, "Latest edit")
        XCTAssertEqual(detail.rawText, original.rawText)
        XCTAssertEqual(detail.words, original.words)
        XCTAssertEqual(detail.segments, original.segments)
        XCTAssertEqual(detail.notes?.excerpts, notes.excerpts)
        XCTAssertNil(detail.audioFile)
    }

    func testStaleNotesAndEditsToDeletedRecordsFailWithoutResurrection() async throws {
        let path = try directory(), value = HistoryRepository(directory: path)
        let item = record("Source"), notes = try MeetingNotes(source: "Wrong source", excerpts: [], model: "fixture")
        value.submit(item, delay: 60); try await value.flushAsync()
        let mismatch = expectation(description: "source mismatch")
        value.updateNotes(id: item.id, notes: notes, expectedRawText: "Wrong source") { result in
            XCTAssertNotNil(result.failure); mismatch.fulfill()
        }
        await fulfillment(of: [mismatch], timeout: 2)
        value.remove(ids: [item.id])
        let removed = expectation(description: "deleted edit")
        value.updateText(id: item.id, text: "Must not resurrect", delay: 60) { result in
            XCTAssertNotNil(result.failure); removed.fulfill()
        }
        await fulfillment(of: [removed], timeout: 2)
        try await value.flushAsync()
        let page = try await value.page()
        XCTAssertTrue(page.rows.isEmpty)
    }

    func testResetPreflightsAllFilesAndNeverFollowsSymlinks() throws {
        let path = try directory(), outside = try directory().appendingPathComponent("preserve.json")
        let bytes = Data("Outside data".utf8); try bytes.write(to: outside)
        let existing = path.appendingPathComponent(HistoryDatabase.fileName)
        try Data("Bad database".utf8).write(to: existing)
        try FileManager.default.createSymbolicLink(at: path.appendingPathComponent("history.json"), withDestinationURL: outside)
        XCTAssertThrowsError(try HistoryDatabase.reset(directory: path))
        XCTAssertEqual(try Data(contentsOf: outside), bytes)
        XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "Bad database")
    }

    func testCallbacksCannotDeadlockByCallingBlockingFlush() async throws {
        let path = try directory(), value = HistoryRepository(directory: path)
        let callback = expectation(description: "callback rejected blocking reentry")
        value.submit(record("One"), delay: 60) { result in
            XCTAssertNil(result.failure)
            do { try value.flush(); XCTFail("Expected blocking reentry rejection") } catch {}
            callback.fulfill()
        }
        try await value.flushAsync()
        await fulfillment(of: [callback], timeout: 2)
    }

    @MainActor func testAlreadyCancelledReadsDoNotOpenOrMigrateStorage() async throws {
        let path = try directory(), boundary = RepositoryBoundary(), value = repository(path, boundary: boundary)
        let task = Task { try await value.page(query: "Obsolete") }
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(boundary.opens, 0)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: path.path).isEmpty)
    }

    @MainActor func testCancelDuringOpeningFencesReadsButKeepsMigrationAndAdmittedWrites() async throws {
        let path = try directory(), started = expectation(description: "opening"), release = DispatchSemaphore(value: 0)
        let initial = (0..<50).map { record("Legacy \($0)") }
        try LocalStore(directory: path).write(initial, name: "history.json")
        let value = HistoryRepository(open: {
            started.fulfill()
            guard release.wait(timeout: .now() + 3) == .success else { throw OSprError.message("Timed out test gate") }
            return try HistoryDatabase(directory: path)
        }, reset: { try HistoryDatabase.reset(directory: path) })
        let first = Task { try await value.page() }
        await fulfillment(of: [started], timeout: 2)
        let queued = Task { try await value.record(id: initial[0].id) }
        await Task.yield()
        first.cancel(); queued.cancel()
        let fresh = record("Keep admitted write")
        value.submit(fresh, delay: 60); release.signal()
        for task in [first] {
            do { _ = try await task.value; XCTFail("Expected in-flight read cancellation") }
            catch { XCTAssertTrue(error is CancellationError) }
        }
        do { _ = try await queued.value; XCTFail("Expected queued read cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        try await value.flushAsync()
        let page = try await value.page()
        XCTAssertEqual(page.rows.map(\.id), [fresh.id] + initial.map(\.id))
        let original = try await value.record(id: initial[0].id)
        XCTAssertEqual(try canonical(XCTUnwrap(original)), try canonical(initial[0]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.appendingPathComponent("history.json").path))
    }

    func testConcurrentAdmissionsAreNotLostAcrossPages() async throws {
        let path = try directory(), value = HistoryRepository(directory: path)
        let records = (0..<450).map { record("Concurrent record \($0)") }
        await withTaskGroup(of: Void.self) { group in
            for item in records { group.addTask { value.submit(item, delay: 60) } }
        }
        try await value.flushAsync()
        var cursor: Int64?, ids: [UUID] = []
        repeat {
            let page = try await value.page(before: cursor, limit: 100)
            ids += page.rows.map(\.id); cursor = page.next
        } while cursor != nil
        XCTAssertEqual(ids.count, records.count)
        XCTAssertEqual(Set(ids), Set(records.map(\.id)))
        let stats = try await value.statistics()
        XCTAssertEqual(stats, HistoryStatistics(records: 450, words: 1350))
    }

    func testRepositoryRetainsTheGUILeaseUntilItsConnectionCloses() async throws {
        let path = try directory()
        var owner: AppInstanceLock? = try AppInstanceLock(directory: path)
        var value: HistoryRepository? = HistoryRepository(directory: path, instanceLock: owner)
        let page = try await value!.page()
        XCTAssertTrue(page.rows.isEmpty)
        owner = nil
        XCTAssertThrowsError(try AppInstanceLock(directory: path))
        value = nil
        var acquired: AppInstanceLock?
        for _ in 0..<100 {
            if let lock = try? AppInstanceLock(directory: path) { acquired = lock; break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertNotNil(acquired)
        withExtendedLifetime(acquired) {}
    }
    func testSummaryMutationKeepsConcurrentTextAudioNotesAndRejectsStaleSource() async throws {
        let path = try directory(), value = HistoryRepository(directory: path)
        var original = record("Do not ship Friday.")
        original.audioFile = original.id.uuidString + ".wav"
        original.notes = try MeetingNotes(source: original.rawText, excerpts: [.init(id: 0, text: original.rawText)], model: "extractive")
        let summary = try MeetingSummary(source: original.rawText,
            items: [.init(section: .decisions, text: "Hold the Friday release.", sourceIDs: [0])],
            excerpts: [.init(id: 0, text: original.rawText)], model: "fixture", chunks: 1)
        value.submit(original, delay: 60); try await value.flushAsync()
        value.updateText(id: original.id, text: "Edited while summarizing", delay: 60)
        value.updateSummary(id: original.id, summary: summary, expectedRawText: original.rawText)
        value.stripAudio(); try await value.flushAsync()
        let loaded = try await value.record(id: original.id)
        let detail = try XCTUnwrap(loaded)
        XCTAssertEqual(detail.text, "Edited while summarizing"); XCTAssertEqual(detail.rawText, original.rawText)
        XCTAssertEqual(detail.summary?.items, summary.items); XCTAssertEqual(detail.notes?.model, "extractive")
        XCTAssertNil(detail.audioFile)
        let rejected = expectation(description: "stale summary")
        value.updateSummary(id: original.id, summary: summary, expectedRawText: "Wrong") { result in
            XCTAssertNotNil(result.failure); rejected.fulfill()
        }
        await fulfillment(of: [rejected], timeout: 2)
        let after = try await value.record(id: original.id)
        XCTAssertEqual(after?.summary?.items, summary.items)
        value.remove(ids: [original.id]); try await value.flushAsync()
        let removed = expectation(description: "removed summary")
        value.updateSummary(id: original.id, summary: summary, expectedRawText: original.rawText) { result in
            XCTAssertNotNil(result.failure); removed.fulfill()
        }
        await fulfillment(of: [removed], timeout: 2)
        let final = try await value.record(id: original.id); XCTAssertNil(final)
    }

}

private final class RepositoryBoundary: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = 0, attempted = 0
    private var main = false, failure = false
    var opens: Int { lock.lock(); defer { lock.unlock() }; return opened }
    var commits: Int { lock.lock(); defer { lock.unlock() }; return attempted }
    var usedMainThread: Bool { lock.lock(); defer { lock.unlock() }; return main }
    var fail: Bool {
        get { lock.lock(); defer { lock.unlock() }; return failure }
        set { lock.lock(); defer { lock.unlock() }; failure = newValue }
    }
    func didOpen() { lock.lock(); defer { lock.unlock() }; opened += 1; main = main || Thread.isMainThread }
    func callback() { lock.lock(); defer { lock.unlock() }; main = main || Thread.isMainThread }
    func commit() throws {
        lock.lock(); defer { lock.unlock() }; attempted += 1; main = main || Thread.isMainThread
        if failure { throw OSprError.message("Simulated repository write failure") }
    }

}
