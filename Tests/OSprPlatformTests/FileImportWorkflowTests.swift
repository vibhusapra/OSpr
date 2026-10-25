import XCTest
import AppKit
@testable import OSpr
@testable import OSprCore

final class FileImportWorkflowTests: XCTestCase {
    @MainActor func testDropCollectsEveryURLInOrderBeforeAdmission() async throws {
        let urls = ["first.wav", "second.wav", "first.wav"].map { URL(fileURLWithPath: "/tmp/" + $0) }
        let providers = urls.map { NSItemProvider(object: $0 as NSURL) }
        let collected = try await FileDropImport.urls(from: providers)
        XCTAssertEqual(collected, urls)
    }
    @MainActor func testUnreadableOrRemoteDropRejectsWholeBatch() async throws {
        for invalid in [NSItemProvider(), NSItemProvider(object: URL(string: "https://example.com/audio.wav")! as NSURL)] {
            let valid = NSItemProvider(object: URL(fileURLWithPath: "/tmp/valid.wav") as NSURL)
            do { _ = try await FileDropImport.urls(from: [valid, invalid]); XCTFail("Do not import a subset") }
            catch { XCTAssertTrue(error.localizedDescription.contains("No files were imported")) }
        }
    }
    @MainActor private func fixture(saving: Bool = false) throws -> (AppModel, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("OSpr-import-ui-" + UUID().uuidString)
        let root = directory.appendingPathComponent("engine"), backend = directory.appendingPathComponent("engine/backend/ospr_backend")
        let bin = root.appendingPathComponent(".venv/bin")
        try FileManager.default.createDirectory(at: backend, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try "#!/bin/sh\nexec /usr/bin/python3 \"$@\"\n".write(to: bin.appendingPathComponent("python"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: bin.appendingPathComponent("python").path)
        try Data().write(to: backend.appendingPathComponent("__init__.py"))
        let code = """
        import json,sys,pathlib,time,os
        base=pathlib.Path(__file__).resolve().parents[2]
        for line in sys.stdin:
            r=json.loads(line); a=r.get('action'); value={}; ok=True
            if a=='ping':value={'pid':os.getpid()}
            if a=='transcribe':
                name=pathlib.Path(r['path']).name
                with (base/'requests.jsonl').open('a') as f:f.write(json.dumps({'name':name,'model':r['model'],'language':r['language']})+'\\n')
                if name=='slow.wav':
                    (base/'slow-admitted').touch();time.sleep(0.5)
                if name=='bad.wav' and not (base/'allow-bad').exists():ok=False
                value={'text':'Public fixture '+name,'model':r['model'],'audio_seconds':1}
            response={'id':r['id'],'ok':ok,'result':value}
            if not ok:response={'id':r['id'],'ok':False,'error':'Invalid fixture audio'}
            print(json.dumps(response),flush=True)
        """
        try code.write(to: backend.appendingPathComponent("worker.py"), atomically: true, encoding: .utf8)
        var settings = OSprSettings(); settings.rootPath = root.path; settings.saveHistory = saving
        settings.mode = .verbatim; settings.autoPaste = false; settings.model = "whisper-small"; settings.retentionDays = 0
        try JSONEncoder().encode(settings).write(to: directory.appendingPathComponent("settings.json"))
        let app = AppModel(instanceLock: try AppInstanceLock(directory: directory), directory: directory, enableServices: false)
        return (app, directory)
    }
    @MainActor private func settle(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(6)
        while !predicate() && Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(predicate())
    }
    private func copiedProfile(_ directory: URL) throws -> URL {
        let path = directory.appendingPathComponent("relaunch-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
        for name in ["settings.json", HistoryDatabase.fileName, FileImportJournal.fileName] {
            let source = directory.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: source.path) { try FileManager.default.copyItem(at: source, to: path.appendingPathComponent(name)) }
        }
        return path
    }

    @MainActor func testSavedBatchRestoresWithoutInferenceAndRetriesOnlyFailureUsingOriginalSettings() async throws {
        let (app, directory) = try fixture(saving: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await settle { !app.busy }
        app.importFiles([directory.appendingPathComponent("one.wav"), directory.appendingPathComponent("bad.wav")])
        try await settle { !app.busy }
        let first = try XCTUnwrap(app.importBatch?.items[0]), second = try XCTUnwrap(app.importBatch?.items[1])
        XCTAssertTrue(app.importQueueSaved); try await app.prepareForTermination()
        let copy = try copiedProfile(directory)
        let reopened = AppModel(instanceLock: try AppInstanceLock(directory: copy), directory: copy, enableServices: false)
        try await settle { !reopened.busy }
        XCTAssertTrue(reopened.importRecovered)
        XCTAssertEqual(reopened.importBatch?.items.map(\.state), [.completed, .failed])
        XCTAssertEqual(reopened.importBatch?.items[0].transcriptID, first.resultID)
        let before = try String(contentsOf: directory.appendingPathComponent("engine/requests.jsonl"), encoding: .utf8)
        XCTAssertEqual(before.split(separator: "\n").count, 2)
        reopened.settings.model = "parakeet-v3"; reopened.settings.language = "fr"
        try Data().write(to: directory.appendingPathComponent("engine/allow-bad"))
        reopened.retryImports(); try await settle { !reopened.busy }
        XCTAssertEqual(reopened.importBatch?.completedCount, 2)
        XCTAssertEqual(reopened.importBatch?.items[0].transcriptID, first.resultID)
        XCTAssertEqual(reopened.importBatch?.items[1].transcriptID, second.resultID)
        let requests = try String(contentsOf: directory.appendingPathComponent("engine/requests.jsonl"), encoding: .utf8).split(separator: "\n").map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
        XCTAssertEqual(requests.compactMap { $0["name"] as? String }, ["one.wav", "bad.wav", "bad.wav"])
        XCTAssertTrue(requests.allSatisfy { $0["model"] as? String == "whisper-small" && $0["language"] as? String == "" })
        try await reopened.prepareForTermination()
    }

    @MainActor func testHistoryOffPurgesSavedQueueAndLaterSessionRetryCannotRecreateIt() async throws {
        let (app, directory) = try fixture(saving: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await settle { !app.busy }
        app.importFiles([directory.appendingPathComponent("one.wav"), directory.appendingPathComponent("bad.wav")])
        try await settle { !app.busy }
        let journal = directory.appendingPathComponent(FileImportJournal.fileName)
        XCTAssertTrue(FileManager.default.fileExists(atPath: journal.path))
        app.settings.saveHistory = false; app.saveOSprSettings(); try await settle { !app.busy }
        XCTAssertFalse(FileManager.default.fileExists(atPath: journal.path))
        try Data().write(to: directory.appendingPathComponent("engine/allow-bad"))
        app.retryImports(); try await settle { !app.busy }
        XCTAssertEqual(app.importBatch?.completedCount, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: journal.path))
        XCTAssertEqual(try HistoryDatabase(directory: directory).statistics().records, 0)
        try await app.prepareForTermination()
        XCTAssertFalse(FileManager.default.fileExists(atPath: journal.path))
    }

    @MainActor func testCorruptRecoverySurvivesQuitAndBlocksReplacementUntilExplicitDismissal() async throws {
        let (app, directory) = try fixture(saving: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await settle { !app.busy }; try await app.prepareForTermination()
        let copy = try copiedProfile(directory), file = copy.appendingPathComponent(FileImportJournal.fileName), bytes = Data("{invalid queue".utf8)
        try bytes.write(to: file)
        let reopened = AppModel(instanceLock: try AppInstanceLock(directory: copy), directory: copy, enableServices: false)
        try await settle { !reopened.busy }
        XCTAssertFalse(reopened.importPersistenceError.isEmpty)
        reopened.importFiles([directory.appendingPathComponent("one.wav")])
        XCTAssertNil(reopened.importBatch); XCTAssertEqual(try Data(contentsOf: file), bytes)
        try await reopened.prepareForTermination(); XCTAssertEqual(try Data(contentsOf: file), bytes)
        reopened.cancelTermination(); reopened.dismissImportBatch()
        try await settle { reopened.importPersistenceError.isEmpty && !FileManager.default.fileExists(atPath: file.path) }
        reopened.importFiles([directory.appendingPathComponent("one.wav")]); try await settle { !reopened.busy }
        XCTAssertEqual(reopened.importBatch?.completedCount, 1)
        try await reopened.prepareForTermination()
    }

    @MainActor func testSavedProviderRecoveryWaitsForConfirmationAndDoesNotUseNewGlobalLocalRoute() async throws {
        let (app, directory) = try fixture(saving: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await settle { !app.busy }; try await app.prepareForTermination()
        let copy = try copiedProfile(directory)
        var settings = OSprSettings(); settings.transcriptionProvider = "compatible"; settings.transcriptionURL = "http://127.0.0.1:1/v1"
        let snapshot = FileImportSnapshot(batch: FileImportBatch(urls: [directory.appendingPathComponent("one.wav")]), settings: settings)
        try await FileImportJournal(directory: copy).save(snapshot, revision: 1)
        let reopened = AppModel(instanceLock: try AppInstanceLock(directory: copy), directory: copy, enableServices: false)
        try await settle { !reopened.busy }
        XCTAssertTrue(reopened.importRecovered)
        reopened.retryImports(); XCTAssertTrue(reopened.confirmImportResume); XCTAssertFalse(reopened.busy)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("engine/requests.jsonl").path))
        reopened.retryImports(confirmedRecovery: true); try await settle { !reopened.busy }
        XCTAssertEqual(reopened.importBatch?.items[0].state, .failed)
        XCTAssertEqual(reopened.settings.transcriptionProvider, "local")
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("engine/requests.jsonl").path))
        try await reopened.prepareForTermination()
    }

    @MainActor func testExpiredRecoveryIsRemovedWithoutInference() async throws {
        let (app, directory) = try fixture(saving: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await settle { !app.busy }; try await app.prepareForTermination()
        let copy = try copiedProfile(directory)
        var settings = try XCTUnwrap(LocalStore(directory: copy).read(OSprSettings.self, name: "settings.json")); settings.retentionDays = 1
        try LocalStore(directory: copy).write(settings, name: "settings.json")
        let snapshot = FileImportSnapshot(batch: FileImportBatch(urls: [directory.appendingPathComponent("one.wav")]), settings: settings)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any])
        var batch = try XCTUnwrap(json["batch"] as? [String: Any]); batch["created"] = 0; batch["updated"] = 0; json["batch"] = batch
        let file = copy.appendingPathComponent(FileImportJournal.fileName); try JSONSerialization.data(withJSONObject: json).write(to: file)
        let reopened = AppModel(instanceLock: try AppInstanceLock(directory: copy), directory: copy, enableServices: false)
        try await settle { !reopened.busy }
        XCTAssertNil(reopened.importBatch); XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("engine/requests.jsonl").path))
        try await reopened.prepareForTermination()
    }

    @MainActor func testDismissAndDeleteAllHistoryRemoveQueueButDismissKeepsTranscript() async throws {
        let (app, directory) = try fixture(saving: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await settle { !app.busy }
        app.importFiles([directory.appendingPathComponent("one.wav")]); try await settle { !app.busy }
        let id = try XCTUnwrap(app.importBatch?.items[0].resultID)
        app.dismissImportBatch()
        try await settle { !FileManager.default.fileExists(atPath: directory.appendingPathComponent(FileImportJournal.fileName).path) }
        XCTAssertNil(app.importBatch)
        let kept = try await app.historyState.contains(id: id); XCTAssertTrue(kept)
        app.importFiles([directory.appendingPathComponent("two.wav")]); try await settle { !app.busy }
        app.clearHistory(); try await app.historyState.flush()
        try await settle { !FileManager.default.fileExists(atPath: directory.appendingPathComponent(FileImportJournal.fileName).path) }
        XCTAssertEqual(try HistoryDatabase(directory: directory).statistics().records, 0)
        try await app.prepareForTermination()
    }

    @MainActor func testSavingShorterRetentionPurgesRecoveredQueueImmediately() async throws {
        let (app, directory) = try fixture(saving: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await settle { !app.busy }; try await app.prepareForTermination()
        let copy = try copiedProfile(directory)
        let snapshot = FileImportSnapshot(batch: FileImportBatch(urls: [directory.appendingPathComponent("one.wav")]), settings: app.settings)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any])
        var batch = try XCTUnwrap(json["batch"] as? [String: Any]); batch["created"] = 0; batch["updated"] = 0; json["batch"] = batch
        let file = copy.appendingPathComponent(FileImportJournal.fileName); try JSONSerialization.data(withJSONObject: json).write(to: file)
        let reopened = AppModel(instanceLock: try AppInstanceLock(directory: copy), directory: copy, enableServices: false)
        try await settle { !reopened.busy }; XCTAssertNotNil(reopened.importBatch)
        reopened.settings.retentionDays = 1; reopened.saveOSprSettings(); try await settle { !reopened.busy }
        XCTAssertNil(reopened.importBatch); XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("engine/requests.jsonl").path))
        try await reopened.prepareForTermination()
    }
    @MainActor func testMixedBatchRetriesOnlyFailureWithOriginalConfigurationAndExportsLatestEdit() async throws {
        let (app, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await settle { !app.busy }
        let first = directory.appendingPathComponent("one.wav"), bad = directory.appendingPathComponent("bad.wav"), third = directory.appendingPathComponent("three.wav")
        app.importFiles([first, bad, third]); try await settle { !app.busy }
        XCTAssertEqual(app.importBatch?.items.map(\.state), [.completed, .failed, .completed])
        XCTAssertEqual(app.importBatch?.items[1].message, "Invalid fixture audio")
        let firstID = try XCTUnwrap(app.importBatch?.items[0].transcriptID)
        app.settings.model = "parakeet-v3"; app.settings.language = "fr"
        try Data().write(to: directory.appendingPathComponent("engine/allow-bad"))
        app.retryImports(); try await settle { !app.busy }
        XCTAssertEqual(app.importBatch?.completedCount, 3)
        XCTAssertEqual(app.importBatch?.items[0].transcriptID, firstID)
        let requests = try String(contentsOf: directory.appendingPathComponent("engine/requests.jsonl"), encoding: .utf8).split(separator: "\n").map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
        XCTAssertEqual(requests.compactMap { $0["name"] as? String }, ["one.wav", "bad.wav", "three.wav", "bad.wav"])
        XCTAssertTrue(requests.allSatisfy { $0["model"] as? String == "whisper-small" && $0["language"] as? String == "" })
        app.updateText(firstID, text: "Edited before bulk export")
        let output = directory.appendingPathComponent("export")
        app.beginHistoryExport(to: output, format: .json, query: "")
        try await settle { !app.busy }
        let index = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: output.appendingPathComponent("index.json"))) as? [String: Any])
        XCTAssertEqual(index["count"] as? Int, 3)
        let entries = try XCTUnwrap(index["records"] as? [[String: Any]])
        let entry = try XCTUnwrap(entries.first { ($0["id"] as? String)?.lowercased() == firstID.uuidString.lowercased() })
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: output.appendingPathComponent(entry["file"] as! String))) as? [String: Any])
        XCTAssertEqual(saved["text"] as? String, "Edited before bulk export")
        XCTAssertEqual(saved["source"] as? String, "one.wav")
        try await app.prepareForTermination()
    }
    @MainActor func testCancelStopsUnstartedFilesAndLateWorkerCannotPublishSuccess() async throws {
        let (app, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await settle { !app.busy }
        app.importFiles([directory.appendingPathComponent("slow.wav"), directory.appendingPathComponent("not-started.wav")])
        try await settle { FileManager.default.fileExists(atPath: directory.appendingPathComponent("engine/slow-admitted").path) }
        app.cancel()
        XCTAssertEqual(app.importBatch?.items.map(\.state), [.cancelled, .cancelled])
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertNil(app.historyState.latest)
        let requests = try String(contentsOf: directory.appendingPathComponent("engine/requests.jsonl"), encoding: .utf8)
        XCTAssertFalse(requests.contains("not-started"))
        try await app.prepareForTermination()
    }
    @MainActor func testNonBatchWatchedTranscriptionStillStoresAndExportsWithoutBatchCallbacks() async throws {
        let (app, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await settle { !app.busy }
        let process = try XCTUnwrap(app.folderWatcher.process)
        let result = await process(directory.appendingPathComponent("watched.wav"))
        XCTAssertTrue(result)
        XCTAssertEqual(app.historyState.latest?.source, "watched.wav")
        XCTAssertEqual(app.historyState.latest?.text, "Public fixture watched.wav")
        XCTAssertNil(app.importBatch)
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("OSpr Transcripts").path)
        XCTAssertEqual(Set(files.map { URL(fileURLWithPath: $0).pathExtension }), Set(["txt", "json", "srt", "vtt"]))
        try await app.prepareForTermination()
    }
}
