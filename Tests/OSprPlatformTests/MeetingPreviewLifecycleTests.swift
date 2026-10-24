import XCTest
import AVFoundation
@testable import OSpr
@testable import OSprCore

private final class FixtureMeetingSession: MeetingCaptureSession {
    var level: (Float) -> Void = { _ in }
    var stopped: (Error) -> Void = { _ in }
    let directory: URL
    let failPreview: Bool
    var snapshotCalls = 0
    var discarded = false
    var stoppedNormally = false
    init(directory: URL, failPreview: Bool) { self.directory = directory; self.failPreview = failPreview }
    func start(includeMicrophone: Bool, microphoneID: String) async throws {
        XCTAssertFalse(includeMicrophone, "This fixture must never request a real device")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16000)!
        buffer.frameLength = 16000; buffer.int16ChannelData![0].update(repeating: 1000, count: 16000)
        let writer = try PCMFileWriter(url: source, format: format)
        try writer.write(buffer); try writer.close()
    }
    var source: URL { directory.appendingPathComponent("system.wav") }
    func snapshotPreview(incremental: Bool) async throws -> URL? {
        snapshotCalls += 1
        if failPreview { throw OSprError.message("Injected draft failure") }
        guard snapshotCalls == 1 else { return nil }
        let packet = directory.appendingPathComponent("preview-" + UUID().uuidString + ".wav")
        try FileManager.default.copyItem(at: source, to: packet)
        return packet
    }
    func stop() async throws -> [MeetingTrack] { stoppedNormally = true; return [MeetingTrack(url: source, start: 1000, end: 1001)] }
    func snapshotForQuit() throws -> [MeetingTrack] { [MeetingTrack(url: source, start: 1000, end: 1001)] }
    func discard() async { discarded = true; try? FileManager.default.removeItem(at: directory) }
}

final class MeetingPreviewLifecycleTests: XCTestCase {
    @MainActor func testIncrementalDraftIsCancelledBeforeIndependentCompleteFinalASR() async throws {
        try await scenario { app, root, sessions in
            app.startMeeting()
            try await self.wait { app.preview == "provisional draft" }
            XCTAssertEqual(app.meetingPreviewTitle, "Live transcript · provisional")
            app.stop()
            try await self.wait { !app.busy }
            XCTAssertEqual(app.historyState.latest?.rawText, "canonical final tail")
            XCTAssertEqual(app.historyState.latest?.mode, .verbatim)
            XCTAssertEqual(app.historyState.latest?.duration, 1)
            XCTAssertFalse(app.hasRecovery)
            XCTAssertFalse(app.recordingDesktop)
            XCTAssertTrue(sessions.value[0].stoppedNormally && sessions.value[0].discarded)
            let actions = try self.requests(root).compactMap { $0["action"] as? String }
            for action in ["stream_begin", "stream_feed", "stream_cancel", "mix_meeting", "transcribe"] { XCTAssertTrue(actions.contains(action)) }
            XCTAssertLessThan(actions.firstIndex(of: "stream_cancel")!, actions.firstIndex(of: "mix_meeting")!)
            XCTAssertFalse(actions.contains("stream_end"), "The provisional stream must not replace the full-file result")
            let final = try XCTUnwrap(self.requests(root).last { $0["action"] as? String == "transcribe" })
            XCTAssertEqual(final["observed_frames"] as? Int, 16000)
        }
    }
    @MainActor func testPreviewFailureKeepsRecordingAndStillSavesTheFullFinalResult() async throws {
        try await scenario(failPreview: true) { app, root, _ in
            app.startMeeting()
            try await self.wait { app.error.contains("Live preview stopped") }
            XCTAssertEqual(app.phase, "recording")
            XCTAssertTrue(app.recordingDesktop)
            XCTAssertNil(app.historyState.latest)
            app.stop()
            try await self.wait { !app.busy }
            XCTAssertEqual(app.historyState.latest?.rawText, "canonical final tail")
            XCTAssertFalse(app.hasRecovery)
            let actions = try self.requests(root).compactMap { $0["action"] as? String }
            XCTAssertFalse(actions.contains("stream_feed"))
            XCTAssertTrue(actions.contains("stream_cancel") && actions.contains("transcribe"))
        }
    }
    @MainActor func testMissingStreamIDNeverFallsBackToPacketTranscription() async throws {
        try await scenario(mode: "missing-id") { app, root, sessions in
            app.startMeeting()
            try await self.wait { app.error.contains("Live preview stopped") }
            XCTAssertEqual(sessions.value[0].snapshotCalls, 0)
            XCTAssertFalse(try self.requests(root).contains { $0["action"] as? String == "transcribe" })
            app.stop(); try await self.wait { !app.busy }
            XCTAssertEqual(app.historyState.latest?.rawText, "canonical final tail")
        }
    }
    @MainActor func testRollingModelUsesDraftPacketsAndStillRunsCompleteFinalASR() async throws {
        try await scenario(model: "parakeet-v3") { app, root, _ in
            app.startMeeting(); try await self.wait { app.preview == "provisional draft" }
            XCTAssertEqual(app.meetingPreviewTitle, "Recent speech · last 12 seconds")
            app.stop(); try await self.wait { !app.busy }
            let calls = try self.requests(root).filter { $0["action"] as? String == "transcribe" }
            XCTAssertEqual(calls.count, 2)
            XCTAssertTrue((calls[0]["path"] as? String)?.contains("preview-") == true)
            XCTAssertFalse((calls[1]["path"] as? String)?.contains("preview-") == true)
            XCTAssertEqual(app.historyState.latest?.rawText, "canonical final tail")
        }
    }
    @MainActor func testCancelAndLateOldCaptureCallbackCannotStopReplacement() async throws {
        try await scenario { app, _, sessions in
            app.startMeeting(); try await self.wait { app.preview == "provisional draft" }
            app.cancel(); try await self.wait { sessions.value[0].discarded }
            XCTAssertNil(app.historyState.latest)
            app.startMeeting(); try await self.wait { sessions.value.count == 2 && app.phase == "recording" }
            sessions.value[0].stopped(OSprError.message("Late old capture error"))
            XCTAssertEqual(app.phase, "recording")
            XCTAssertTrue(app.recordingDesktop)
            XCTAssertFalse(app.error.contains("Late old"))
            app.cancel(); try await self.wait { sessions.value[1].discarded }
            XCTAssertNil(app.historyState.latest)
        }
    }
    @MainActor func testStopWaitsForAdmittedFeedBeforeDeletingItsPacket() async throws {
        try await scenario(mode: "slow-feed") { app, root, _ in
            app.startMeeting()
            try await self.wait { FileManager.default.fileExists(atPath: root.appendingPathComponent("feed-started").path) }
            app.stop(); try await self.wait { !app.busy }
            XCTAssertEqual(app.historyState.latest?.rawText, "canonical final tail")
            let feed = try XCTUnwrap(self.requests(root).first { $0["action"] as? String == "stream_feed" })
            XCTAssertEqual(feed["observed_frames"] as? Int, 16000, "The packet must exist until the admitted worker request reads it")
        }
    }
    @MainActor func testStopDuringStreamPreparationCancelsOnlyItsOwnedSession() async throws {
        try await scenario(mode: "slow-begin") { app, root, sessions in
            app.startMeeting()
            try await self.wait { FileManager.default.fileExists(atPath: root.appendingPathComponent("begin-started").path) }
            app.stop(); try await self.wait { !app.busy }
            XCTAssertEqual(sessions.value[0].snapshotCalls, 0)
            XCTAssertEqual(app.historyState.latest?.rawText, "canonical final tail")
            let actions = try self.requests(root).compactMap { $0["action"] as? String }
            XCTAssertTrue(actions.contains("stream_cancel"))
            XCTAssertFalse(actions.contains("stream_feed"))
        }
    }
    @MainActor func testFinalRecognitionFailureKeepsTheCompleteMixedRecovery() async throws {
        try await scenario(mode: "final-error") { app, root, sessions in
            app.startMeeting(); try await self.wait { app.preview == "provisional draft" }
            let original = try Data(contentsOf: sessions.value[0].source)
            app.stop(); try await self.wait { !app.busy }
            XCTAssertTrue(app.hasRecovery)
            XCTAssertNil(app.historyState.latest)
            XCTAssertTrue(app.error.contains("Injected final ASR failure"))
            let retained = root.appendingPathComponent("profile/Recovery/pending.wav")
            XCTAssertEqual(try Data(contentsOf: retained), original)
        }
    }
    private final class Sessions { var value: [FixtureMeetingSession] = [] }
    @MainActor private func scenario(model: String = "nemotron-streaming", mode: String = "normal", failPreview: Bool = false,
                                     body: (AppModel, URL, Sessions) async throws -> Void) async throws {
        guard ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"].contains(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw XCTSkip("Meeting preflight requires FFmpeg")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("OSpr-meeting-lifecycle-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = root.appendingPathComponent("backend/ospr_backend"), bin = root.appendingPathComponent(".venv/bin")
        try FileManager.default.createDirectory(at: backend, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try Data().write(to: backend.appendingPathComponent("__init__.py"))
        try Data("#!/bin/sh\nexec /usr/bin/python3 \"$@\"\n".utf8).write(to: bin.appendingPathComponent("python"))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: bin.appendingPathComponent("python").path)
        let source = """
        import json, sys, pathlib, shutil, wave, uuid, time
        root = pathlib.Path(__file__).resolve().parents[2]
        session = None
        for line in sys.stdin:
            request = json.loads(line)
            action = request['action']
            result = {}
            ok = True
            if action == 'stream_begin':
                if '\(mode)' == 'slow-begin':
                    (root/'begin-started').touch()
                    time.sleep(.25)
                session = str(uuid.uuid4())
                result = {} if '\(mode)' == 'missing-id' else {'session_id':session}
            if action == 'stream_feed':
                if '\(mode)' == 'slow-feed':
                    (root/'feed-started').touch()
                    time.sleep(.25)
                with wave.open(request['path']) as audio: request['observed_frames'] = audio.getnframes()
                result = {'text':'provisional draft'}
            if action == 'stream_cancel':
                result = {'cancelled':request.get('session_id') == session}
                if result['cancelled']: session = None
            if action == 'mix_meeting': shutil.copyfile(request['tracks'][0]['path'], request['output'])
            if action == 'transcribe':
                with wave.open(request['path']) as audio: request['observed_frames'] = audio.getnframes()
                text = 'provisional draft' if 'preview-' in pathlib.Path(request['path']).name else 'canonical final tail'
                result = {'text':text,'audio_seconds':1.0,'segments':[{'start':0.0,'end':1.0,'text':text}]}
                if '\(mode)' == 'final-error' and text != 'provisional draft': ok = False
            with (root/'requests.jsonl').open('a') as out: out.write(json.dumps(request)+'\\n')
            print(json.dumps({'id':request['id'],'ok':ok,'result':result,'error':'Injected final ASR failure'}), flush=True)
        """
        try source.write(to: backend.appendingPathComponent("worker.py"), atomically: true, encoding: .utf8)
        let directory = root.appendingPathComponent("profile")
        let store = try LocalStore(directory: directory)
        var config = OSprSettings(); config.rootPath = root.path; config.model = model
        config.preview = true; config.mode = .clean; config.transcriptionProvider = "local"
        config.rewriteProvider = "none"; config.speakerLabels = false; config.keepAudio = false; config.autoPaste = false
        try store.write(config, name: "settings.json")
        let sessions = Sessions()
        let app = AppModel(instanceLock: try AppInstanceLock(directory: directory), directory: directory, enableServices: false,
                           meetingFactory: { directory, preview in
            XCTAssertTrue(preview)
            let session = FixtureMeetingSession(directory: directory, failPreview: failPreview)
            sessions.value.append(session); return session
        })
        app.meetingMicrophone = false
        try await wait { !app.busy }
        do { try await body(app, root, sessions) }
        catch { app.cancel(); try? await app.prepareForTermination(); throw error }
        try await app.prepareForTermination()
    }
    private func requests(_ root: URL) throws -> [[String: Any]] {
        let path = root.appendingPathComponent("requests.jsonl")
        guard FileManager.default.fileExists(atPath: path.path) else { return [] }
        return try String(contentsOf: path, encoding: .utf8).split(separator: "\n").map {
            try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any]
        }
    }
    @MainActor private func wait(_ ready: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(8)
        while !ready() {
            guard Date() < deadline else { throw OSprError.message("Meeting lifecycle fixture timed out") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
