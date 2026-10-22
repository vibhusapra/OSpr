import Foundation
import AVFoundation
import ScreenCaptureKit
import CoreMedia
import OSprCore

struct MeetingTrack {
    var url: URL
    var start: Double
    var end: Double
}

struct MeetingCaptureIssue: LocalizedError {
    var cause: Error
    var tracks: [MeetingTrack]
    var errorDescription: String? { cause.localizedDescription }
}
protocol MeetingCaptureSession: AnyObject {
    var level: (Float) -> Void { get set }
    var stopped: (Error) -> Void { get set }
    func start(includeMicrophone: Bool, microphoneID: String) async throws
    func stop() async throws -> [MeetingTrack]
    func discard() async
    func snapshotForQuit() throws -> [MeetingTrack]
}

/// ScreenCaptureKit delivers audio on a dedicated queue. Video output is never
/// registered. Microphone and desktop remain separate until clock-aligned mixing.
@available(macOS 15.0, *)
final class MeetingCapture: NSObject, SCStreamOutput, SCStreamDelegate, MeetingCaptureSession, @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.ospr.meeting-capture", qos: .userInitiated)
    private var stream: SCStream?
    private var tracks: [String: (sink: AudioSink, track: MeetingTrack, rate: Double)] = [:]
    private var directory: URL
    private var accepting = false
    private var failure: Error?
    private var cancelled = false
    private var monoScratch = [Float](repeating: 0, count: 8192)
    private var lastLevelUpdate: TimeInterval = 0
    var level: (Float) -> Void = { _ in }
    var stopped: (Error) -> Void = { _ in }
    init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    func start(includeMicrophone: Bool, microphoneID: String) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        if queue.sync(execute: { cancelled }) { throw CancellationError() }
        guard let display = content.displays.first else { throw OSprError.message("No display is available for desktop audio capture.") }
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.width = 2; configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        configuration.capturesAudio = true; configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48000; configuration.channelCount = 2
        configuration.captureMicrophone = includeMicrophone
        if !microphoneID.isEmpty { configuration.microphoneCaptureDeviceID = microphoneID }
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        if includeMicrophone { try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: queue) }
        self.stream = stream
        queue.sync { accepting = true }
        do {
            try await stream.startCapture()
            if let failure = queue.sync(execute: { self.failure }) { throw failure }
        }
        catch { queue.sync { accepting = false }; self.stream = nil; throw error }
    }
    static func pcm(_ sample: CMSampleBuffer) throws -> AVAudioPCMBuffer {
        guard CMSampleBufferDataIsReady(sample), let description = CMSampleBufferGetFormatDescription(sample),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description),
              let format = AVAudioFormat(streamDescription: asbd), CMSampleBufferGetNumSamples(sample) > 0,
              let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(CMSampleBufferGetNumSamples(sample))) else {
            throw OSprError.message("Desktop capture returned an unsupported audio buffer.")
        }
        pcm.frameLength = pcm.frameCapacity
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(pcm.frameLength), into: pcm.mutableAudioBufferList)
        guard status == noErr else { throw OSprError.message("Could not read desktop audio (\(status)).") }
        return pcm
    }
    static func gapFrames(timestamp: Double, previousEnd: Double, rate: Double) throws -> Int {
        let gap = timestamp - previousEnd
        guard timestamp.isFinite, previousEnd.isFinite, timestamp >= 0,
              rate.isFinite, (1000...384000).contains(rate), gap.isFinite, abs(gap) <= 3600 else {
            throw OSprError.message("Meeting audio has an invalid or excessive clock jump. Partial audio was kept.")
        }
        guard gap >= -0.1 else { throw OSprError.message("Meeting audio clock moved backwards. Stop and retry.") }
        return gap > 0.02 ? Int((gap * rate).rounded()) : 0
    }
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard accepting, type == .audio || type == .microphone else { return }
        do {
            let pcm = try Self.pcm(sampleBuffer)
            let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
            guard timestamp.isFinite else { throw OSprError.message("Desktop audio has no presentation clock.") }
            let key = type == .audio ? "system" : "microphone"
            if tracks[key] == nil {
                let url = directory.appendingPathComponent(key + ".wav")
                tracks[key] = (try AudioSink(url: url, format: pcm.format), MeetingTrack(url: url, start: timestamp, end: timestamp), pcm.format.sampleRate)
            }
            guard var track = tracks[key] else { return }
            let missing = try Self.gapFrames(timestamp: timestamp, previousEnd: track.track.end, rate: track.rate)
            if missing > 0 { track.sink.silence(frames: missing) }
            track.sink.enqueue(pcm)
            track.track.end = timestamp + Double(pcm.frameLength) / track.rate; tracks[key] = track
            if let error = track.sink.error { throw error }
            if let data = pcm.floatChannelData {
                let rms = monoScratch.withUnsafeMutableBufferPointer { AudioMath.downmix(channels: data,
                    channelCount: Int(pcm.format.channelCount), frames: Int(pcm.frameLength),
                    interleaved: pcm.format.isInterleaved, destination: $0) }
                guard rms.isFinite else { throw OSprError.message("Desktop capture returned non-finite samples.") }
                let now = ProcessInfo.processInfo.systemUptime
                if now - lastLevelUpdate >= 0.1 {
                    lastLevelUpdate = now
                    DispatchQueue.main.async { self.level(min(1, rms * 12)) }
                }
            }
        } catch {
            accepting = false; failure = error
            DispatchQueue.main.async { self.stopped(error) }
        }
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        queue.async { self.failure = error; self.accepting = false }
        DispatchQueue.main.async { self.stopped(error) }
    }
    func stop() async throws -> [MeetingTrack] {
        if let stream { try? await stream.stopCapture() }; stream = nil
        return try queue.sync {
            accepting = false
            for value in tracks.values {
                do { try value.sink.finish() } catch { failure = error }
            }
            let result = tracks.values.map(\.track)
            if let failure { throw MeetingCaptureIssue(cause: failure, tracks: result) }
            return result
        }
    }
    func snapshotForQuit() throws -> [MeetingTrack] {
        try queue.sync {
            accepting = false
            for value in tracks.values { try value.sink.finish() }
            return tracks.values.map(\.track)
        }
    }
    func discard() async {
        queue.sync { cancelled = true; accepting = false }
        _ = try? await stop()
        try? FileManager.default.removeItem(at: directory)
    }
}
