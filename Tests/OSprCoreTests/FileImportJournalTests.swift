import Foundation
import Darwin
import XCTest
@testable import OSprCore

final class FileImportJournalTests: XCTestCase {
    private func directory(create: Bool = true) throws -> URL {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("OSpr-import-journal-" + UUID().uuidString)
        if create { try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true) }
        addTeardownBlock { try? FileManager.default.removeItem(at: path) }; return path
    }
    private func snapshot() -> FileImportSnapshot {
        var settings = OSprSettings(); settings.model = "whisper-small"; settings.language = "fr"
        settings.vocabulary = "Café"; settings.rootPath = "/private-checkout-never-retain"
        settings.microphoneID = "private-microphone-never-retain"; settings.launchAtLogin = true
        return FileImportSnapshot(batch: FileImportBatch(urls: [URL(fileURLWithPath: "/tmp/one.wav"), URL(fileURLWithPath: "/tmp/two.wav")]), settings: settings)
    }
    private func fails(_ action: () async throws -> Void) async {
        do { try await action(); XCTFail("Expected refusal") } catch {}
    }

    func testRoundTripPreservesIdentitiesConfigurationAndPrivatePermissions() async throws {
        let path = try directory(), journal = FileImportJournal(directory: path), original = snapshot()
        let saved = try await journal.save(original, revision: 1); XCTAssertTrue(saved)
        let loaded = try await FileImportJournal(directory: path).load(), value = try XCTUnwrap(loaded)
        XCTAssertEqual(value.batch.id, original.batch.id)
        XCTAssertEqual(value.batch.created, original.batch.created)
        XCTAssertEqual(value.batch.items.map(\.id), original.batch.items.map(\.id))
        XCTAssertEqual(value.batch.items.map(\.resultID), original.batch.items.map(\.resultID))
        XCTAssertEqual(value.settings.model, "whisper-small"); XCTAssertEqual(value.settings.language, "fr")
        XCTAssertEqual(value.settings.vocabulary, "Café"); XCTAssertFalse(value.settings.autoPaste)
        XCTAssertEqual(value.settings.rootPath, ""); XCTAssertEqual(value.settings.microphoneID, "")
        XCTAssertFalse(value.settings.launchAtLogin)
        let data = try Data(contentsOf: path.appendingPathComponent(FileImportJournal.fileName))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("never-retain"))
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: path.path)[.posixPermissions] as? Int, 0o700)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: path.appendingPathComponent(FileImportJournal.fileName).path)[.posixPermissions] as? Int, 0o600)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: path.path), [FileImportJournal.fileName])
    }

    func testHistoryCommitBeforeCheckpointIsRecoveredWithoutDuplicateAdmission() async throws {
        let path = try directory(), journal = FileImportJournal(directory: path)
        var original = snapshot(); let first = original.batch.items[0]
        original.batch.begin(first.id); try await journal.save(original, revision: 1)
        let history = try HistoryDatabase(directory: path)
        var record = Transcript(rawText: "Public fixture", text: "Public fixture", model: "fixture", mode: .verbatim, duration: 1, latencyMS: 1)
        record.id = first.resultID; try history.upsert([record])
        // Disk checkpoint is still processing, as if the process died here.
        let loaded = try await journal.load(); var recovered = try XCTUnwrap(loaded).batch
        XCTAssertEqual(recovered.items[0].state, .processing)
        let existing = try Set(recovered.items.filter { try history.contains(id: $0.resultID) }.map(\.resultID))
        recovered.recover(existing: existing); recovered.prepareRetry()
        XCTAssertEqual(recovered.items[0].state, .warning)
        XCTAssertEqual(recovered.items[0].transcriptID, first.resultID)
        XCTAssertEqual(recovered.remaining.map(\.id), [original.batch.items[1].id])
        XCTAssertEqual(try history.statistics().records, 1)
    }

    func testUncommittedResultCanResumeWithSameIDButDeletedCompletionCannot() throws {
        var batch = snapshot().batch; let first = batch.items[0], second = batch.items[1]
        for item in [first, second] { batch.begin(item.id); batch.noteTranscript(item.id, transcriptID: item.resultID); batch.finish(item.id, transcriptID: item.resultID, message: nil) }
        batch.confirmStored(first.id)
        batch.recover(existing: [])
        XCTAssertEqual(batch.items.map(\.state), [.unavailable, .cancelled])
        XCTAssertEqual(batch.retryCount, 1)
        batch.prepareRetry()
        XCTAssertEqual(batch.remaining.map(\.resultID), [second.resultID])
        XCTAssertNil(batch.items[0].transcriptID)
    }

    func testPrivacyClearFencesOlderAndEqualRevisionWritesAndReplacements() async throws {
        let path = try directory(), journal = FileImportJournal(directory: path), original = snapshot()
        try await journal.save(original, revision: 1); try await journal.clear(revision: 4)
        let stale = try await journal.save(original, revision: 3), equal = try await journal.save(original, revision: 4)
        XCTAssertFalse(stale); XCTAssertFalse(equal)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.appendingPathComponent(FileImportJournal.fileName).path))
        let replacement = snapshot(); try await journal.save(replacement, revision: 6)
        let staleClear = try await journal.clear(revision: 5); XCTAssertFalse(staleClear)
        let loaded = try await journal.load(); XCTAssertEqual(loaded?.batch.id, replacement.batch.id)
    }

    func testFailedAtomicPublicationPreservesPriorBytesAndRemovesStaging() async throws {
        let path = try directory(), original = snapshot()
        try await FileImportJournal(directory: path).save(original, revision: 1)
        let url = path.appendingPathComponent(FileImportJournal.fileName), before = try Data(contentsOf: url)
        let failing = FileImportJournal(directory: path, beforePublish: { throw OSprError.message("Injected checkpoint failure") })
        await fails { try await failing.save(self.snapshot(), revision: 1) }
        XCTAssertEqual(try Data(contentsOf: url), before)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: path.path), [FileImportJournal.fileName])
    }

    func testUnreadableFutureAndInvalidQueuesStayProtectedUntilExplicitClear() async throws {
        for variant in ["broken", "future", "duplicate", "remote"] {
            let path = try directory(), url = path.appendingPathComponent(FileImportJournal.fileName)
            var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot())) as? [String: Any])
            if variant == "future" { json["version"] = 99 }
            if variant == "duplicate" || variant == "remote" {
                var batch = try XCTUnwrap(json["batch"] as? [String: Any]), rows = try XCTUnwrap(batch["items"] as? [[String: Any]])
                if variant == "duplicate" { rows[1] = rows[0] } else { rows[0]["url"] = "https://example.com/private.wav" }
                batch["items"] = rows; json["batch"] = batch
            }
            let data = variant == "broken" ? Data("{broken".utf8) : try JSONSerialization.data(withJSONObject: json)
            try data.write(to: url)
            let journal = FileImportJournal(directory: path)
            await fails { _ = try await journal.load() }
            await fails { try await journal.save(self.snapshot(), revision: 1) }
            XCTAssertEqual(try Data(contentsOf: url), data)
            try await journal.clear(revision: 2); try await journal.save(snapshot(), revision: 3)
            let recovered = try await journal.load(); XCTAssertNotNil(recovered)
        }
    }

    func testSymlinkLoadSaveAndClearNeverTouchTheTarget() async throws {
        let path = try directory(), target = path.appendingPathComponent("external"), bytes = Data("Keep this target".utf8)
        try bytes.write(to: target)
        try FileManager.default.createSymbolicLink(at: path.appendingPathComponent(FileImportJournal.fileName), withDestinationURL: target)
        let journal = FileImportJournal(directory: path)
        await fails { _ = try await journal.load() }
        await fails { try await journal.save(self.snapshot(), revision: 1) }
        await fails { try await journal.clear(revision: 2) }
        XCTAssertEqual(try Data(contentsOf: target), bytes)
    }

    func testNamedPipeCannotBlockStartupRecovery() async throws {
        let path = try directory(), pipe = path.appendingPathComponent(FileImportJournal.fileName)
        XCTAssertEqual(mkfifo(pipe.path, 0o600), 0)
        // Release a regressed blocking open after three seconds so failure is
        // bounded; a valid implementation rejects the FIFO without a writer.
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
            let fd = Darwin.open(pipe.path, O_RDWR | O_NONBLOCK | O_CLOEXEC)
            if fd >= 0 { Darwin.close(fd) }
        }
        let started = Date(), journal = FileImportJournal(directory: path)
        await fails { _ = try await journal.load() }
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    }

    func testAbsentSessionOnlyJournalDoesNotCreateAnyDirectory() async throws {
        let path = try directory(create: false), journal = FileImportJournal(directory: path)
        let loaded = try await journal.load(); XCTAssertNil(loaded)
        try await journal.clear(revision: 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
    }

    func testRestartAndPrivacyClearRemoveOwnedCrashStagesButKeepUnrelatedFiles() async throws {
        let path = try directory(), unrelated = path.appendingPathComponent(".import-batch-stage-v1-not-a-uuid")
        try Data("Keep unrelated data".utf8).write(to: unrelated)
        func stage() throws -> URL {
            let url = path.appendingPathComponent(".import-batch-stage-v1-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            try Data("Sensitive source metadata".utf8).write(to: url.appendingPathComponent("payload")); return url
        }
        let first = try stage(), journal = FileImportJournal(directory: path)
        let loaded = try await journal.load(); XCTAssertNil(loaded)
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
        let second = try stage(); try await journal.clear(revision: 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.path))
        XCTAssertEqual(try Data(contentsOf: unrelated), Data("Keep unrelated data".utf8))
    }

    func testCrashStageSymlinkDoesNotDeleteItsTarget() async throws {
        let path = try directory(), target = path.appendingPathComponent("target"), bytes = Data("External sentinel".utf8)
        try bytes.write(to: target)
        let stage = path.appendingPathComponent(".import-batch-stage-v1-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: stage.appendingPathComponent("payload"), withDestinationURL: target)
        let journal = FileImportJournal(directory: path)
        await fails { _ = try await journal.load() }
        await fails { try await journal.clear(revision: 1) }
        XCTAssertEqual(try Data(contentsOf: target), bytes)
    }

    func testSavedProviderConfirmationSeparatesLocalModelsLoopbackAndHostedRoutes() {
        let batch = snapshot().batch; var settings = OSprSettings()
        XCTAssertFalse(FileImportSnapshot(batch: batch, settings: settings).needsProviderConfirmation)
        settings.rewriteProvider = "ollama"
        XCTAssertFalse(FileImportSnapshot(batch: batch, settings: settings).needsProviderConfirmation)
        settings.rewriteURL = "https://example.com/v1"
        XCTAssertTrue(FileImportSnapshot(batch: batch, settings: settings).needsProviderConfirmation)
        settings.mode = .verbatim
        XCTAssertFalse(FileImportSnapshot(batch: batch, settings: settings).needsProviderConfirmation)
        settings.rewriteProvider = "none"; settings.transcriptionProvider = "compatible"
        XCTAssertTrue(FileImportSnapshot(batch: batch, settings: settings).needsProviderConfirmation)
    }
}
