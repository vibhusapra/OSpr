import XCTest
import AVFoundation
@testable import OSpr
@testable import OSprCore

final class AudioPrivacyTests: XCTestCase {
    @MainActor private final class Fixture {
        let directory: URL
        let engine: URL
        let app: AppModel
        var originals: [URL: Data] = [:]

        init(keepAudio: Bool = true, mode: WritingMode = .verbatim) throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("OSpr-audio-privacy-" + UUID().uuidString)
            engine = directory.appendingPathComponent("engine")
            let backend = engine.appendingPathComponent("backend/ospr_backend"), bin = engine.appendingPathComponent(".venv/bin")
            try FileManager.default.createDirectory(at: backend, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            let launcher = bin.appendingPathComponent("python")
            try "#!/bin/sh\nexec /usr/bin/python3 \"$@\"\n".write(to: launcher, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: launcher.path)
            try Data().write(to: backend.appendingPathComponent("__init__.py"))
            try Self.worker.write(to: backend.appendingPathComponent("worker.py"), atomically: true, encoding: .utf8)
            var settings = OSprSettings()
            settings.rootPath = engine.path; settings.saveHistory = true; settings.keepAudio = keepAudio
            settings.retentionDays = 0; settings.autoPaste = false; settings.model = "whisper-small"; settings.mode = mode
            if mode != .verbatim { settings.rewriteProvider = "local" }
            try JSONEncoder().encode(settings).write(to: directory.appendingPathComponent("settings.json"))
            app = AppModel(instanceLock: try AppInstanceLock(directory: directory), directory: directory, enableServices: false)
        }
        deinit { try? FileManager.default.removeItem(at: directory) }

        func source(_ name: String) throws -> URL {
            let url = directory.appendingPathComponent(name)
            let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1))
            let samples = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1600))
            samples.frameLength = 1600
            for i in 0..<1600 { samples.floatChannelData?[0][i] = Float(sin(Double(i) * 2 * .pi * 440 / 16000) * 0.1) }
            var file: AVAudioFile? = try AVAudioFile(forWriting: url, settings: format.settings)
            try file?.write(from: samples); file = nil
            originals[url] = try Data(contentsOf: url)
            return url
        }
        func control(_ value: [String: Any]) throws {
            try JSONSerialization.data(withJSONObject: value).write(to: engine.appendingPathComponent("control.json"), options: .atomic)
        }
        func release(_ phase: String, _ index: Int = 1) throws {
            try Data().write(to: engine.appendingPathComponent("release-\(phase)-\(index)"))
        }
        func marker(_ phase: String, _ index: Int = 1) -> URL { engine.appendingPathComponent("admitted-\(phase)-\(index).json") }
        func admitted(_ phase: String, _ index: Int = 1) async throws -> [String: Any] {
            let url = marker(phase, index)
            try await AudioPrivacyTests.wait { FileManager.default.fileExists(atPath: url.path) }
            return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        }
        func idle() async throws { try await AudioPrivacyTests.wait { !self.app.busy } }
        func savedPreferences() async throws { try await AudioPrivacyTests.wait { !self.app.audioMaintenance } }
        func rows() async throws -> [Transcript] {
            var result = [Transcript]()
            for item in app.importBatch?.items ?? [] {
                let id = try XCTUnwrap(item.transcriptID)
                let record = try await app.historyState.record(id: id)
                result.append(try XCTUnwrap(record))
                XCTAssertEqual(id, item.resultID)
            }
            return result
        }
        func cleanAudio(expected: Set<String> = []) async throws {
            try await AudioPrivacyTests.wait {
                let files = (try? FileManager.default.contentsOfDirectory(atPath: self.directory.appendingPathComponent("Audio").path)) ?? []
                return Set(files) == expected
            }
        }
        func unchangedSources() throws {
            for (url, data) in originals { XCTAssertEqual(try Data(contentsOf: url), data) }
        }
        func finish() async throws { try unchangedSources(); try await app.prepareForTermination() }

        private static let worker = """
        import json,sys,pathlib,time,os,shutil
        base=pathlib.Path(__file__).resolve().parents[2]
        counts={}
        def control():
            path=base/'control.json'
            return json.loads(path.read_text()) if path.exists() else {}
        def admit(phase,index,request):
            marker=base/('admitted-'+phase+'-'+str(index)+'.json')
            temporary=marker.with_suffix('.tmp')
            temporary.write_text(json.dumps(request));temporary.replace(marker)
            if control().get('pause_'+phase)==index:
                until=time.monotonic()+15
                while not (base/('release-'+phase+'-'+str(index))).exists():
                    if time.monotonic()>until:raise RuntimeError('Fixture release deadline')
                    time.sleep(.01)
        for line in sys.stdin:
            r=json.loads(line);a=r.get('action');value={'pid':os.getpid()};ok=True
            counts[a]=counts.get(a,0)+1;n=counts[a]
            with (base/'requests.jsonl').open('a') as f:f.write(json.dumps(r)+'\\n')
            if a=='prepare_review':
                shutil.copyfile(r['path'],r['output'])
                admit('review',n,r)
            if a=='transcribe':
                if not pathlib.Path(r['path']).is_file():raise RuntimeError('Active inference source disappeared')
                admit('transcribe',n,r)
                value={'text':'Public fixture '+str(n)+'.','raw_text':'Public fixture '+str(n)+'.','model':r['model'],'audio_seconds':.1}
                ok=control().get('fail_transcribe')!=n
            if a=='rewrite':
                admit('rewrite',n,r);ok=False
            response={'id':r['id'],'ok':ok,'result':value}
            if not ok:response={'id':r['id'],'ok':False,'error':'Controlled fixture failure'}
            print(json.dumps(response),flush=True)
        """
    }

    @MainActor private static func wait(_ condition: () -> Bool) async throws {
        let until = Date().addingTimeInterval(8)
        while !condition() {
            guard Date() < until else { throw OSprError.message("Audio privacy fixture did not settle") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @MainActor func testRevocationDropsActiveAndLaterAudioButPreservesPreviouslySavedClip() async throws {
        let f = try Fixture(); try await f.idle()
        let priorSource = try f.source("prior.wav")
        f.app.importFiles([priorSource]); try await f.idle()
        let priorRows = try await f.rows(), prior = try XCTUnwrap(priorRows.first)
        let priorName = try XCTUnwrap(prior.audioFile), audio = f.directory.appendingPathComponent("Audio/" + priorName)
        let bytes = try Data(contentsOf: audio), encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let payload = try encoder.encode(prior)
        try await f.cleanAudio(expected: [priorName])
        try f.control(["pause_transcribe": 2])
        let active = try f.source("active.wav"), later = try f.source("later.wav")
        f.app.importFiles([active, later])
        let request = try await f.admitted("transcribe", 2)
        XCTAssertNotEqual(request["path"] as? String, active.path, "Must already have adopted its review copy")
        f.app.settings.keepAudio = false; f.app.saveOSprSettings(); try await f.savedPreferences()
        try f.release("transcribe", 2); try await f.idle()
        let records = try await f.rows()
        XCTAssertEqual(records.map(\.text), ["Public fixture 2.", "Public fixture 3."])
        XCTAssertTrue(records.allSatisfy { $0.audioFile == nil })
        let old = try await f.app.historyState.record(id: prior.id)
        XCTAssertEqual(try encoder.encode(XCTUnwrap(old)), payload)
        XCTAssertEqual(try Data(contentsOf: audio), bytes)
        let laterReview = try String(contentsOf: f.engine.appendingPathComponent("requests.jsonl"), encoding: .utf8).split(separator: "\n").contains { line in
            guard let data = line.data(using: .utf8), let r = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
            return r["action"] as? String == "prepare_review" && r["path"] as? String == later.path
        }
        XCTAssertFalse(laterReview)
        try await f.cleanAudio(expected: [priorName]); try await f.finish()
    }

    @MainActor func testReenablingCannotResurrectAnAlreadyRevokedTake() async throws {
        let f = try Fixture(); try await f.idle(); try f.control(["pause_transcribe": 1])
        f.app.importFiles([try f.source("revoked.wav")]); _ = try await f.admitted("transcribe")
        f.app.settings.keepAudio = false; f.app.saveOSprSettings(); try await f.savedPreferences()
        f.app.settings.keepAudio = true; f.app.saveOSprSettings(); try await f.savedPreferences()
        try f.release("transcribe"); try await f.idle()
        let first = try await f.rows(); XCTAssertNil(first.first?.audioFile)
        try await f.cleanAudio()
        try f.control([:]); f.app.importFiles([try f.source("new-take.wav")]); try await f.idle()
        let next = try await f.rows(); let name = try XCTUnwrap(next.first?.audioFile)
        try await f.cleanAudio(expected: [name]); try await f.finish()
    }

    @MainActor func testRevocationDuringPreparationPreservesActiveStageThenUsesOriginal() async throws {
        let f = try Fixture(); try await f.idle(); try f.control(["pause_review": 1])
        let source = try f.source("source.wav"); f.app.importFiles([source])
        let request = try await f.admitted("review"), output = try XCTUnwrap(request["output"] as? String)
        f.app.settings.keepAudio = false; f.app.saveOSprSettings(); try await f.savedPreferences()
        XCTAssertTrue(FileManager.default.fileExists(atPath: output), "Preferences must not unlink an active worker output")
        try f.release("review"); try await f.idle()
        let inference = try await f.admitted("transcribe")
        XCTAssertEqual(inference["path"] as? String, source.path)
        let records = try await f.rows(); XCTAssertNil(records.first?.audioFile); XCTAssertNil(records.first?.warning)
        XCTAssertEqual(f.app.importBatch?.items.first?.state, .completed)
        try await f.cleanAudio(); try await f.finish()
    }

    @MainActor func testUnrelatedPreferencesCannotDeleteAnActivePreparation() async throws {
        let f = try Fixture(); try await f.idle(); try f.control(["pause_review": 1])
        let source = try f.source("source.wav"); f.app.importFiles([source])
        let request = try await f.admitted("review"), output = try XCTUnwrap(request["output"] as? String)
        f.app.settings.language = "fr"; f.app.saveOSprSettings(); try await f.savedPreferences()
        XCTAssertTrue(FileManager.default.fileExists(atPath: output))
        try f.release("review"); try await f.idle()
        let records = try await f.rows(), name = try XCTUnwrap(records.first?.audioFile)
        XCTAssertNil(records.first?.warning)
        XCTAssertEqual(try Data(contentsOf: f.directory.appendingPathComponent("Audio/" + name)), f.originals[source])
        let inference = try await f.admitted("transcribe"); XCTAssertEqual(inference["language"] as? String, "")
        try await f.cleanAudio(expected: [name]); try await f.finish()
    }

    @MainActor func testHistoryOffDuringInferenceKeepsSessionTextButNoAudioOrDatabaseRecord() async throws {
        let f = try Fixture(); try await f.idle(); try f.control(["pause_transcribe": 1])
        f.app.importFiles([try f.source("source.wav")]); _ = try await f.admitted("transcribe")
        f.app.settings.saveHistory = false; f.app.saveOSprSettings(); try await f.savedPreferences()
        try f.release("transcribe"); try await f.idle()
        XCTAssertEqual(f.app.historyState.latest?.text, "Public fixture 1.")
        XCTAssertNil(f.app.historyState.latest?.audioFile)
        XCTAssertEqual(try HistoryDatabase(directory: f.directory).statistics().records, 0)
        try await f.cleanAudio(); try await f.finish()
    }

    @MainActor func testEnablingRetentionDoesNotRetroactivelyArchiveAdmittedWork() async throws {
        let f = try Fixture(keepAudio: false); try await f.idle(); try f.control(["pause_transcribe": 1])
        f.app.importFiles([try f.source("source.wav")]); _ = try await f.admitted("transcribe")
        f.app.settings.keepAudio = true; f.app.saveOSprSettings(); try await f.savedPreferences()
        try f.release("transcribe"); try await f.idle()
        let records = try await f.rows(); XCTAssertNil(records.first?.audioFile)
        try await f.cleanAudio()
        try f.control([:]); f.app.importFiles([try f.source("new-take.wav")]); try await f.idle()
        let next = try await f.rows(), name = try XCTUnwrap(next.first?.audioFile)
        try await f.cleanAudio(expected: [name]); try await f.finish()
    }

    @MainActor func testFailedRecognitionAfterRevocationReleasesItsArchive() async throws {
        let f = try Fixture(); try await f.idle(); try f.control(["pause_transcribe": 1, "fail_transcribe": 1])
        f.app.importFiles([try f.source("source.wav")]); _ = try await f.admitted("transcribe")
        f.app.settings.keepAudio = false; f.app.saveOSprSettings(); try await f.savedPreferences()
        try f.release("transcribe"); try await f.idle()
        XCTAssertEqual(f.app.importBatch?.items.first?.state, .failed)
        XCTAssertNil(f.app.importBatch?.items.first?.transcriptID)
        try await f.cleanAudio(); try await f.finish()
    }

    @MainActor func testRevocationDuringFailedRefinementKeepsRawTextWithoutAudio() async throws {
        for mode: WritingMode in [.clean, .assistant] {
            let f = try Fixture(mode: mode); try await f.idle(); try f.control(["pause_rewrite": 1])
            f.app.importFiles([try f.source("source.wav")]); _ = try await f.admitted("rewrite")
            f.app.settings.keepAudio = false; f.app.saveOSprSettings(); try await f.savedPreferences()
            try f.release("rewrite"); try await f.idle()
            let records = try await f.rows()
            XCTAssertEqual(records.first?.text, "Public fixture 1."); XCTAssertEqual(records.first?.rawText, "Public fixture 1.")
            XCTAssertNil(records.first?.audioFile)
            XCTAssertTrue(f.app.importBatch?.items.first?.message?.contains("rewrite failed") == true)
            XCTAssertTrue(f.app.importBatch?.items.first?.historyCommitted == true, "The raw fallback must acknowledge its successful History commit")
            try await f.cleanAudio(); try await f.finish()
        }
    }

    @MainActor func testCancellationDuringPreparationReleasesItsTemporaryLease() async throws {
        let f = try Fixture(); try await f.idle(); try f.control(["pause_review": 1])
        f.app.importFiles([try f.source("source.wav")]); _ = try await f.admitted("review")
        f.app.cancel(); try await f.idle(); try await f.cleanAudio()
        XCTAssertNil(f.app.importBatch?.items.first?.transcriptID)
        try await f.finish()
    }
}
