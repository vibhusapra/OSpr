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
    func snapshotPreview(incremental: Bool) async throws -> URL?
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
    private var pipeline: MeetingAudioPipeline?
    private let previewEnabled: Bool
    private var directory: URL
    private var accepting = false
    private var failure: Error?
    private var cancelled = false
    private var lastLevelUpdate: TimeInterval = 0
    var level: (Float) -> Void = { _ in }
    var stopped: (Error) -> Void = { _ in }
    init(directory: URL, preview: Bool = false) throws {
        self.directory = directory; self.previewEnabled = preview
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
        try queue.sync {
            guard !cancelled else { throw CancellationError() }
            pipeline = try MeetingAudioPipeline(directory: directory, includeMicrophone: includeMicrophone, preview: previewEnabled)
            self.stream = stream; accepting = true
        }
        do {
            try await stream.startCapture()
            if let failure = queue.sync(execute: { self.failure }) { throw failure }
        }
        catch {
            queue.sync { accepting = false; self.stream = nil }
            try? await stream.stopCapture()
            throw error
        }
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
        try MeetingAudioClock.gapFrames(timestamp: timestamp, previousEnd: previousEnd, rate: rate)
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard accepting, type == .audio || type == .microphone else { return }
        do {
            let pcm = try Self.pcm(sampleBuffer)
            let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
            guard timestamp.isFinite else { throw OSprError.message("Desktop audio has no presentation clock.") }
            let source: MeetingPreviewSource = type == .audio ? .system : .microphone
            let rms = try pipeline?.ingest(pcm, source: source, timestamp: timestamp) ?? 0
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastLevelUpdate >= 0.1 {
                lastLevelUpdate = now
                DispatchQueue.main.async { self.level(min(1, rms * 12)) }
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
    func snapshotPreview(incremental: Bool) async throws -> URL? {
        let samples: [Float] = try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do { continuation.resume(returning: try self.pipeline?.preview(incremental: incremental) ?? []) }
                catch { continuation.resume(throwing: error) }
            }
        }
        try Task.checkCancellation()
        // Export outside the delivery queue; never read an active WAV header.
        return try MeetingAudioPipeline.exportPreview(samples, directory: directory)
    }
    func stop() async throws -> [MeetingTrack] {
        let owned = queue.sync { () -> SCStream? in
            accepting = false
            let owned = stream; stream = nil
            return owned
        }
        if let owned { try? await owned.stopCapture() }
        return try queue.sync {
            let result = try pipeline?.finish() ?? []
            if let failure { throw MeetingCaptureIssue(cause: failure, tracks: result) }
            return result
        }
    }
    func snapshotForQuit() throws -> [MeetingTrack] {
        try queue.sync { accepting = false; return try pipeline?.finish() ?? [] }
    }
    func discard() async {
        queue.sync { cancelled = true; accepting = false }
        _ = try? await stop()
        queue.sync { pipeline = nil }
        try? FileManager.default.removeItem(at: directory)
    }
}
