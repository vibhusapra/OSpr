// Copy temporarily into platform tests. Headless AppModel/IPC process control;
// no native UI, microphone, permissions, real provider or recognition model.
import Foundation
import XCTest
@testable import OSpr
@testable import OSprCore

final class DurableImportProcessTemporary: XCTestCase {
    @MainActor private func settle(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(20)
        while !condition() && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        guard condition() else { throw OSprError.message("Process fixture did not settle.") }
    }
    private func requests(_ root: URL) throws -> [[String: Any]] {
        try String(contentsOf: root.appendingPathComponent("engine/requests.jsonl"), encoding: .utf8)
            .split(separator: "\n").map { try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]) }
    }
    private func emit(_ value: [String: Any], name: String, root: URL) throws {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .prettyPrinted]).write(to: root.appendingPathComponent(name), options: .atomic)
    }
    @MainActor func testStage() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let stage = env["OSPR_BATCH_PROCESS_STAGE"], let path = env["OSPR_BATCH_PROCESS_ROOT"] else { throw XCTSkip("Only the explicit process harness runs this probe.") }
        let root = URL(fileURLWithPath: path)
        guard root.lastPathComponent.hasPrefix("ospr-batch-process-"), ["admit", "resume", "verify", "privacy"].contains(stage) else { throw OSprError.message("Use the process harness and a disposable fixture directory.") }
        if stage == "admit" {
            guard !FileManager.default.fileExists(atPath: path) else { throw OSprError.message("Refusing to replace an existing process fixture.") }
            let store = try LocalStore(directory: root), engine = root.appendingPathComponent("engine"), bin = engine.appendingPathComponent(".venv/bin"), backend = engine.appendingPathComponent("backend/ospr_backend")
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: backend, withIntermediateDirectories: true)
            try "#!/bin/sh\nexec /usr/bin/python3 \"$@\"\n".write(to: bin.appendingPathComponent("python"), atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: bin.appendingPathComponent("python").path)
            try Data().write(to: backend.appendingPathComponent("__init__.py"))
            let worker = """
            import json,sys,pathlib,time,os
            root=pathlib.Path(__file__).resolve().parents[2]
            (root/'worker-pid').write_text(str(os.getpid()))
            for line in sys.stdin:
                r=json.loads(line); result={}
                if r.get('action')=='transcribe':
                    name=pathlib.Path(r['path']).name
                    with (root/'requests.jsonl').open('a') as f:
                        f.write(json.dumps({'name':name,'model':r['model'],'language':r['language']})+'\\n');f.flush();os.fsync(f.fileno())
                    if name=='slow.wav' and not (root/'allow-slow').exists():
                        (root/'slow-admitted').touch();time.sleep(120)
                    result={'text':'Public process fixture '+name,'model':r['model'],'audio_seconds':1}
                print(json.dumps({'id':r['id'],'ok':True,'result':result}),flush=True)
            """
            try worker.write(to: backend.appendingPathComponent("worker.py"), atomically: true, encoding: .utf8)
            var settings = OSprSettings(); settings.rootPath = engine.path; settings.mode = .verbatim
            settings.model = "whisper-small"; settings.saveHistory = true; settings.retentionDays = 0; settings.autoPaste = false
            try store.write(settings, name: "settings.json")
            for name in ["first.wav", "slow.wav", "last.wav"] { try Data("Synthetic public process fixture; worker does not decode this file.".utf8).write(to: root.appendingPathComponent(name)) }
        }
        let app = AppModel(instanceLock: try AppInstanceLock(directory: root), directory: root, enableServices: false)
        try await settle { !app.busy }
        if stage == "admit" {
            app.importFiles(["first.wav", "slow.wav", "last.wav"].map { root.appendingPathComponent($0) })
            try await settle { FileManager.default.fileExists(atPath: root.appendingPathComponent("engine/slow-admitted").path) }
            let batch = try XCTUnwrap(app.importBatch)
            XCTAssertEqual(batch.items.map(\.state), [.completed, .processing, .queued])
            XCTAssertEqual(batch.items[0].transcriptID, batch.items[0].resultID)
            XCTAssertEqual(try HistoryDatabase(directory: root).statistics().records, 1)
            try emit(["status": "ready-for-intentional-sigkill", "history_records": 1,
                      "test_pid": ProcessInfo.processInfo.processIdentifier,
                      "worker_pid": Int(try String(contentsOf: root.appendingPathComponent("engine/worker-pid"), encoding: .utf8))!,
                      "planned_ids": batch.items.map { $0.resultID.uuidString }, "requests": requests(root)], name: "admit-ready.json", root: root)
            // The harness confirms this process is live, then kills its owned
            // process group. A timeout is a failed control, never a successful kill.
            try await Task.sleep(for: .seconds(120))
            XCTFail("Harness failed to interrupt the live process")
        } else if stage == "resume" {
            XCTAssertTrue(app.importRecovered)
            XCTAssertEqual(app.importBatch?.items.map(\.state), [.completed, .cancelled, .cancelled])
            XCTAssertEqual(try requests(root).count, 2)
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertEqual(try requests(root).count, 2) // no startup inference
            let expected = try XCTUnwrap(app.importBatch).items.map(\.resultID)
            app.retryImports(); try await settle { !app.busy }
            XCTAssertEqual(app.importBatch?.completedCount, 3)
            XCTAssertEqual(app.importBatch?.items.compactMap(\.transcriptID), expected)
            let observed = try requests(root)
            XCTAssertEqual(observed.compactMap { $0["name"] as? String }, ["first.wav", "slow.wav", "slow.wav", "last.wav"])
            XCTAssertTrue(observed.allSatisfy { $0["model"] as? String == "whisper-small" && $0["language"] as? String == "" })
            try await app.prepareForTermination()
            let history = try HistoryDatabase(directory: root)
            XCTAssertEqual(try history.statistics().records, 3)
            try emit(["status": "passed", "planned_ids": expected.map(\.uuidString), "requests": observed,
                      "history_records": 3, "fingerprint": history.contentFingerprint()], name: "resume-result.json", root: root)
        } else if stage == "verify" {
            let expected = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("resume-result.json"))) as? [String: Any])
            XCTAssertTrue(app.importRecovered); XCTAssertEqual(app.importBatch?.completedCount, 3)
            XCTAssertEqual(app.importBatch?.retryCount, 0); XCTAssertEqual(try requests(root).count, 4)
            let history = try HistoryDatabase(directory: root)
            XCTAssertEqual(try history.contentFingerprint(), expected["fingerprint"] as? String)
            try await app.prepareForTermination()
            try emit(["status": "passed", "history_records": 3, "requests": 4, "payloads_unchanged": true], name: "verify-result.json", root: root)
        } else {
            XCTAssertFalse(app.settings.saveHistory); XCTAssertNil(app.importBatch)
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(FileImportJournal.fileName).path))
            XCTAssertEqual(try HistoryDatabase(directory: root).statistics().records, 0)
            XCTAssertEqual(try requests(root).count, 4)
            try await app.prepareForTermination()
            try emit(["status": "passed", "history_records": 0, "requests": 4, "journal_absent": true], name: "privacy-result.json", root: root)
        }
    }
}
