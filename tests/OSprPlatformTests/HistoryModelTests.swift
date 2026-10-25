import XCTest
@testable import OSpr
@testable import OSprCore

final class HistoryModelTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("OSpr-history-ui-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func record(_ text: String) -> Transcript {
        Transcript(rawText: "Original " + text, text: text, model: "fixture", mode: .clean, duration: 1, latencyMS: 2,
            words: [Segment(start: 0, end: 1, text: text, speaker: 2)])
    }
    @MainActor private func settle(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !predicate() && Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(predicate())
    }

    @MainActor func testBoundedPagesAggregateCountsAndCompleteDetail() async throws {
        let repository = HistoryRepository(directory: try directory())
        var newest: Transcript!
        for n in 0..<235 { newest = record("row \(n) " + String(repeating: "long ", count: 130)); repository.submit(newest, delay: 60) }
        try await repository.flushAsync()
        let model = HistoryModel(repository: repository, saving: true)
        await model.reload()
        try await settle { model.selected != nil }
        XCTAssertEqual(model.rows.count, 100)
        XCTAssertEqual(model.statistics.records, 235)
        XCTAssertEqual(model.statistics.words, 235 * 132)
        XCTAssertLessThan(model.rows[0].preview.count, newest.text.count)
        XCTAssertEqual(model.selected?.text, newest.text)
        XCTAssertEqual(model.selected?.words?.first?.speaker, 2)
        model.loadMore(); try await settle { !model.loading }
        XCTAssertEqual(model.rows.count, 200)
        model.loadMore(); try await settle { !model.loading }
        XCTAssertEqual(model.rows.count, 235); XCTAssertNil(model.next)
        let detail = try await model.record(id: newest.id)
        XCTAssertEqual(detail?.text, newest.text)
    }

    @MainActor func testLatestQueryWinsWithoutLosingOpenedRecord() async throws {
        let repository = HistoryRepository(directory: try directory())
        let apple = record("apple 🍎"), banana = record("banana 🍌")
        repository.submit(apple, delay: 60); repository.submit(banana, delay: 60)
        try await repository.flushAsync()
        let model = HistoryModel(repository: repository, saving: true)
        await model.reload(); try await settle { model.selected?.id == banana.id }
        model.query = "banana"; model.query = "apple"
        try await settle { !model.loading && model.rows.count == 1 }
        XCTAssertEqual(model.rows.first?.id, apple.id)
        XCTAssertEqual(model.selected?.id, banana.id)
        XCTAssertEqual(model.latest?.id, banana.id)
    }

    @MainActor func testFilenameSearchPublishesLabelsWhileKeepingSelectedDetail() async throws {
        let repository = HistoryRepository(directory: try directory(), saveHistory: false)
        var first = record("Same words"), second = record("Same words")
        first.source = "/private-parent/first Café.wav"; second.source = "second.wav"
        repository.submit(first, delay: 60); repository.submit(second, delay: 60)
        try await repository.flushAsync()
        let model = HistoryModel(repository: repository, saving: false)
        await model.reload(); try await settle { model.selected?.id == second.id }
        model.query = "cafe\u{301}"
        try await settle { !model.loading && model.rows.count == 1 }
        XCTAssertEqual(model.rows.first?.id, first.id)
        XCTAssertEqual(model.rows.first?.sourceName, "first Café.wav")
        XCTAssertEqual(model.selected?.id, second.id)
        XCTAssertEqual(model.statistics.records, 2)
    }

    @MainActor func testNewBackgroundResultKeepsSelectionAndEditsKeepTiming() async throws {
        let repository = HistoryRepository(directory: try directory())
        let first = record("first"), second = record("second")
        let model = HistoryModel(repository: repository, saving: true)
        model.submit(first, select: true); try await model.flush()
        try await settle { !model.saving && !model.loading }
        model.submit(second, select: false); try await model.flush()
        try await settle { model.latest?.id == second.id && !model.loading }
        XCTAssertEqual(model.selection, first.id)
        model.updateText(id: first.id, text: "edited original")
        XCTAssertEqual(model.selected?.text, "edited original")
        try await model.flush()
        let saved = try await model.record(id: first.id)
        XCTAssertEqual(saved?.text, "edited original")
        XCTAssertEqual(saved?.words?.first?.speaker, 2)
        XCTAssertEqual(saved?.rawText, first.rawText)
    }

    @MainActor func testSessionPolicyAndReenablePreserveAllRecords() async throws {
        let path = try directory(), repository = HistoryRepository(directory: path)
        let model = HistoryModel(repository: repository, saving: true, pageSize: 7)
        for n in 0..<30 { repository.submit(record("session \(n)"), delay: 60) }
        try await repository.flushAsync(); await model.reload()
        let before = try await repository.contentFingerprint()
        try await model.configure(saving: false, retentionDays: 0)
        let disk = try HistoryDatabase(directory: path)
        XCTAssertEqual(try disk.statistics().records, 0)
        let session = try await repository.contentFingerprint(); XCTAssertEqual(session, before)
        try await model.configure(saving: true, retentionDays: 0)
        XCTAssertEqual(try disk.statistics().records, 30)
        try await settle { !model.loading && model.rows.count == 7 }
        XCTAssertEqual(model.statistics.records, 30)
    }

    @MainActor func testFailedStorageKeepsNewResultAvailableForExport() async throws {
        let path = try directory()
        try Data("broken legacy archive".utf8).write(to: path.appendingPathComponent("history.json"))
        let repository = HistoryRepository(directory: path)
        let model = HistoryModel(repository: repository, saving: true)
        let fresh = record("Keep my complete text " + String(repeating: "word ", count: 200))
        model.submit(fresh, select: true)
        do { try await model.flush(); XCTFail("Expected legacy migration failure") } catch {}
        try await settle { !model.failure.isEmpty }
        XCTAssertEqual(model.selected?.text, fresh.text)
        let pending = try await model.record(id: fresh.id); XCTAssertEqual(pending?.text, fresh.text)
        model.clear(); try await model.flush()
        try await settle { !model.saving && !model.loading }
        XCTAssertNil(model.selected); XCTAssertEqual(model.statistics.records, 0)
    }

    @MainActor func testClearAndDeleteCannotReappearFromQueuedDetail() async throws {
        let repository = HistoryRepository(directory: try directory())
        let model = HistoryModel(repository: repository, saving: true)
        let item = record("remove me")
        model.submit(item, select: true); try await model.flush()
        await model.reload()
        model.remove(id: item.id); try await model.flush()
        try await settle { !model.loading && !model.saving }
        XCTAssertNil(model.selected); XCTAssertTrue(model.rows.isEmpty)
        let saved = try await model.record(id: item.id); XCTAssertNil(saved)
    }

    @MainActor func testNotesDoNotOverwriteAnEditAndRemovedRecordRejectsNotes() async throws {
        let repository = HistoryRepository(directory: try directory())
        let model = HistoryModel(repository: repository, saving: true)
        let item = record("keep source")
        model.submit(item, select: true); try await model.flush()
        let notes = try MeetingNotes(source: item.rawText, excerpts: [NoteExcerpt(id: 0, text: item.rawText)], model: "fixture")
        model.updateText(id: item.id, text: "Edited independently")
        try await model.updateNotes(id: item.id, notes: notes, expectedRawText: item.rawText)
        let saved = try await model.record(id: item.id)
        XCTAssertEqual(saved?.text, "Edited independently")
        XCTAssertEqual(saved?.notes?.excerpts, notes.excerpts)
        model.remove(id: item.id); try await model.flush()
        do {
            try await model.updateNotes(id: item.id, notes: notes, expectedRawText: item.rawText)
            XCTFail("Notes cannot recreate a removed record")
        } catch {}
        let removed = try await model.record(id: item.id); XCTAssertNil(removed)
    }

    @MainActor func testAppStartupMigratesLegacyOffActorAndUsesPagedHistory() async throws {
        let path = try directory(), store = try LocalStore(directory: path)
        var settings = OSprSettings(); settings.retentionDays = 0; settings.autoPaste = false
        try store.write(settings, name: "settings.json")
        let values = (0..<215).map { record("legacy \($0)") }
        try store.write(values, name: "history.json")
        let lease = try AppInstanceLock(directory: path)
        let app = AppModel(instanceLock: lease, directory: path, enableServices: false)
        // No legacy array is synchronously decoded into AppModel.
        XCTAssertTrue(app.historyState.rows.isEmpty)
        try await settle { !app.audioMaintenance && !app.historyState.loading }
        XCTAssertTrue(app.error.isEmpty, app.error)
        XCTAssertEqual(app.historyState.statistics.records, 215)
        XCTAssertEqual(app.historyState.rows.count, 100)
        XCTAssertEqual(app.historyState.latest?.id, values.first?.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.appendingPathComponent("history.json").path))
        app.selection = values[110].id
        try await settle { app.selected?.id == values[110].id }
        XCTAssertEqual(app.selected?.rawText, values[110].rawText)
    }

    @MainActor func testQuitBarrierPersistsPendingEditorText() async throws {
        let path = try directory(), lease = try AppInstanceLock(directory: path)
        let app = AppModel(instanceLock: lease, directory: path, enableServices: false)
        try await settle { !app.audioMaintenance }
        let value = record("before quitting")
        app.historyState.submit(value, select: true)
        app.updateText(value.id, text: "Last keystroke before quit")
        try await app.prepareForTermination()
        let disk = try HistoryDatabase(directory: path)
        XCTAssertEqual(try disk.record(id: value.id)?.text, "Last keystroke before quit")
        XCTAssertTrue(app.quitting)
        app.cancelTermination(); XCTAssertFalse(app.quitting)
    }

    @MainActor func testFailedQuitKeepsUnsavedTranscriptAvailable() async throws {
        let path = try directory(), lease = try AppInstanceLock(directory: path)
        try Data("broken history".utf8).write(to: path.appendingPathComponent("history.json"))
        let app = AppModel(instanceLock: lease, directory: path, enableServices: false)
        try await settle { !app.audioMaintenance }
        let value = record("do not lose me")
        app.historyState.submit(value, select: true)
        do { try await app.prepareForTermination(); XCTFail("Quit must report save failure") } catch {}
        XCTAssertFalse(app.quitting)
        XCTAssertEqual(app.selected?.text, value.text)
        let pending = try await app.historyState.record(id: value.id)
        XCTAssertEqual(pending?.text, value.text)
    }

    @MainActor func testAudioLeaseDecisionDoesNotReadAnUnreadableArchive() async throws {
        let path = try directory()
        try Data("broken history".utf8).write(to: path.appendingPathComponent("history.json"))
        let model = HistoryModel(repository: HistoryRepository(directory: path), saving: true)
        var completed = record("Recognized but not yet durable")
        completed.audioFile = "owned-result.wav"
        let failedTake = UUID()
        // No transcript was admitted for failedTake; it must not leak a lease
        // just because a history read would throw on the corrupt legacy input.
        XCTAssertFalse(model.retainsResultAudio(id: failedTake, name: "failed-take.wav"))
        model.submit(completed, select: true)
        do { try await model.flush(); XCTFail("Expected migration failure") } catch {}
        XCTAssertTrue(model.retainsResultAudio(id: completed.id, name: "owned-result.wav"))
        XCTAssertFalse(model.retainsResultAudio(id: completed.id, name: "different.wav"))
        XCTAssertFalse(model.retainsResultAudio(id: failedTake, name: "failed-take.wav"))
        model.stripAudio(.all)
        XCTAssertFalse(model.retainsResultAudio(id: completed.id, name: "owned-result.wav"))
    }
}
