import XCTest
@testable import OSpr
@testable import OSprCore

final class TextPreparationTests: XCTestCase {
    @MainActor private func fixture(mode: String = "valid") throws -> (AppModel, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("OSpr-text-prepare-" + UUID().uuidString)
        let root = directory.appendingPathComponent("engine")
        let backend = root.appendingPathComponent("backend/ospr_backend")
        let bin = root.appendingPathComponent(".venv/bin")
        try FileManager.default.createDirectory(at: backend, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try "#!/bin/sh\nexec /usr/bin/python3 \"$@\"\n".write(to: bin.appendingPathComponent("python"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: bin.appendingPathComponent("python").path)
        try Data().write(to: backend.appendingPathComponent("__init__.py"))
        let code = """
        import json,sys,pathlib,os,time
        base=pathlib.Path(__file__).resolve().parents[2]
        with (base/'starts').open('a') as f:f.write('start\\n')
        primed=None
        for line in sys.stdin:
            request=json.loads(line); action=request.get('action'); result={}; rejected=False
            if action=='ping':result={'pid':os.getpid()}
            if action=='warm_text':
                (base/'admitted').touch()
                if '\(mode)'=='slow':time.sleep(0.5)
                if '\(mode)'=='missing':rejected=True
                model=request['model']; primed=model
                result={'model':model if '\(mode)'!='wrong' else 'wrong',
                        'repository':'mlx-community/Qwen3-4B-Instruct-2507-4bit' if model=='rewrite-quality' else 'mlx-community/Qwen3.5-9B-4bit',
                        'primed':True,'cache_only':True,'already_prepared':False,'finish_reason':'stop',
                        'generation_tokens':6,'load_ms':10,'prime_ms':20,'total_ms':30}
            if action=='model_status':
                (base/'status-admitted').touch()
                if '\(mode)'=='status-slow':time.sleep(0.3)
                result={'models':[],'resident':['parakeet-v3'],'rewrite_resident':primed,'rewrite_primed':primed}
            response={'id':request['id'],'ok':True,'result':result}
            if rejected:primed=None;response={'id':request['id'],'ok':False,'error':'Download cached text weights first.','error_kind':'text-model-not-prepared'}
            print(json.dumps(response),flush=True)
        """
        try code.write(to: backend.appendingPathComponent("worker.py"), atomically: true, encoding: .utf8)
        var settings = OSprSettings(); settings.rootPath = root.path
        try JSONEncoder().encode(settings).write(to: directory.appendingPathComponent("settings.json"))
        let app = AppModel(instanceLock: try AppInstanceLock(directory: directory), directory: directory, enableServices: false)
        return (app, directory)
    }
    @MainActor private func settled(_ app: AppModel) async throws {
        for _ in 0..<1000 {
            if !app.busy && !app.checkingModels { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("Text preparation did not settle")
    }
    @MainActor func testPreparationKeepsSpeechReadinessSettingsAndHistoryThenReleaseClearsState() async throws {
        let (app, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await settled(app); app.ready = true
        for choice in LocalRefinementModel.allCases {
            app.prepareTextModel(choice); try await settled(app)
            XCTAssertEqual(app.preparedTextModel, choice.workerModel)
            XCTAssertTrue(app.ready); XCTAssertTrue(app.residentModels.contains("parakeet-v3"))
            XCTAssertTrue(app.error.isEmpty); XCTAssertEqual(app.settings.rewriteProvider, "none")
            XCTAssertEqual(app.settings.model, "parakeet-v3"); XCTAssertEqual(app.historyState.statistics.records, 0)
        }
        app.releaseModels(); XCTAssertNil(app.preparedTextModel); XCTAssertTrue(app.residentModels.isEmpty); XCTAssertFalse(app.ready)
        try await app.prepareForTermination()
    }
    @MainActor func testWrongModelAcknowledgementIsNotReadyAndDropsOwnedWorker() async throws {
        let (app, directory) = try fixture(mode: "wrong")
        defer { try? FileManager.default.removeItem(at: directory) }
        try await settled(app); app.ready = true
        app.prepareTextModel(.larger); try await settled(app)
        XCTAssertNil(app.preparedTextModel); XCTAssertFalse(app.ready)
        XCTAssertTrue(app.error.contains("did not acknowledge"))
        let starts = try String(contentsOf: directory.appendingPathComponent("engine/starts"), encoding: .utf8)
        XCTAssertEqual(starts.split(separator: "\n").count, 2)
        try await app.prepareForTermination()
    }
    @MainActor func testMissingCachedWeightsKeepsSpeechWorkerReadyWithoutEnablingRefinement() async throws {
        let (app, directory) = try fixture(mode: "missing")
        defer { try? FileManager.default.removeItem(at: directory) }
        try await settled(app); app.ready = true
        app.prepareTextModel(.larger); try await settled(app)
        XCTAssertNil(app.preparedTextModel); XCTAssertTrue(app.ready)
        XCTAssertTrue(app.residentModels.contains("parakeet-v3")); XCTAssertEqual(app.settings.rewriteProvider, "none")
        XCTAssertTrue(app.error.contains("cached text weights"))
        let starts = try String(contentsOf: directory.appendingPathComponent("engine/starts"), encoding: .utf8)
        XCTAssertEqual(starts.split(separator: "\n").count, 1)
        try await app.prepareForTermination()
    }
    @MainActor func testCancellationCannotPublishLatePreparationOrSyntheticHistory() async throws {
        let (app, directory) = try fixture(mode: "slow")
        defer { try? FileManager.default.removeItem(at: directory) }
        try await settled(app)
        app.prepareTextModel(.standard)
        for _ in 0..<1000 {
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent("engine/admitted").path) { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        app.cancel(); try await Task.sleep(nanoseconds: 550_000_000)
        XCTAssertNil(app.preparedTextModel); XCTAssertFalse(app.ready); XCTAssertEqual(app.phase, "idle")
        XCTAssertEqual(app.historyState.statistics.records, 0); XCTAssertEqual(app.settings.rewriteProvider, "none")
        try await app.prepareForTermination()
    }
    @MainActor func testQueuedOldInventoryCannotReplaceNewPreparationState() async throws {
        let (app, directory) = try fixture(mode: "status-slow")
        defer { try? FileManager.default.removeItem(at: directory) }
        try await settled(app); app.refreshModels()
        for _ in 0..<1000 {
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent("engine/status-admitted").path) { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertTrue(app.checkingModels)
        app.prepareTextModel(.larger); try await settled(app)
        XCTAssertEqual(app.preparedTextModel, "meeting-quality"); XCTAssertTrue(app.error.isEmpty)
        try await app.prepareForTermination()
    }

}
