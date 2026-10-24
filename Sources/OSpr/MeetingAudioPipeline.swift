import Foundation
import AVFoundation
import OSprCore

/// Capture-owned state, called on the ScreenCaptureKit delivery queue. Durable
/// tracks and the optional draft mixer have independent failure domains.
final class MeetingAudioPipeline {
    private let directory: URL
    private let includeMicrophone: Bool
    private var tracks: [MeetingPreviewSource: (sink: AudioSink, track: MeetingTrack, rate: Double)] = [:]
    private var mixer: MeetingPreviewMixer?
    private var previewFailure: Error?
    private var closed = false
    private var mono = [Float](repeating: 0, count: 8192)
    init(directory: URL, includeMicrophone: Bool, preview: Bool) throws {
        self.directory = directory; self.includeMicrophone = includeMicrophone
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if preview { mixer = try MeetingPreviewMixer(includeMicrophone: includeMicrophone) }
    }
    func ingest(_ pcm: AVAudioPCMBuffer, source: MeetingPreviewSource, timestamp: Double) throws -> Float {
        guard !closed, source != .microphone || includeMicrophone, timestamp.isFinite else {
            throw OSprError.message("Meeting capture received an invalid or closed audio source.")
        }
        if tracks[source] == nil {
            let url = directory.appendingPathComponent(source.rawValue + ".wav")
            tracks[source] = (try AudioSink(url: url, format: pcm.format), MeetingTrack(url: url, start: timestamp, end: timestamp), pcm.format.sampleRate)
        }
        guard var track = tracks[source] else { return 0 }
        let missing = try MeetingAudioClock.gapFrames(timestamp: timestamp, previousEnd: track.track.end, rate: track.rate)
        if missing > 0 { track.sink.silence(frames: missing) }
        track.sink.enqueue(pcm)
        track.track.end = timestamp + Double(pcm.frameLength) / track.rate; tracks[source] = track
        if let error = track.sink.error { throw error }
        guard let channels = pcm.floatChannelData else {
            if mixer != nil {
                previewFailure = OSprError.message("Live meeting preview requires Float32 capture. Final transcription will use the complete recording.")
                mixer = nil
            }
            return 0
        }
        let rms = mono.withUnsafeMutableBufferPointer {
            AudioMath.downmix(channels: channels, channelCount: Int(pcm.format.channelCount), frames: Int(pcm.frameLength),
                              interleaved: pcm.format.isInterleaved, destination: $0)
        }
        guard rms.isFinite else { throw OSprError.message("Desktop capture returned non-finite samples.") }
        if let mixer {
            do {
                try mono.withUnsafeBufferPointer { values in
                    try mixer.append(UnsafeBufferPointer(start: values.baseAddress, count: Int(pcm.frameLength)),
                                     source: source, sampleRate: pcm.format.sampleRate, timestamp: timestamp)
                }
            } catch {
                // The original buffer was already admitted to its durable sink.
                previewFailure = error; self.mixer = nil
            }
        }
        return rms
    }
    func preview(incremental: Bool) throws -> [Float] {
        if let previewFailure { throw previewFailure }
        return try mixer?.snapshot(incremental: incremental) ?? []
    }
    func finish() throws -> [MeetingTrack] {
        closed = true; mixer?.finish()
        var failure: Error?
        for value in tracks.values { do { try value.sink.finish() } catch { failure = error } }
        let result = tracks.values.map(\.track)
        if let failure { throw MeetingCaptureIssue(cause: failure, tracks: result) }
        return result
    }
    static func exportPreview(_ samples: [Float], directory: URL) throws -> URL? {
        guard !samples.isEmpty else { return nil }
        guard samples.count <= 12 * 16000, samples.allSatisfy(\.isFinite),
              let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else {
            throw OSprError.message("Invalid live meeting preview packet.")
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: $0.count) }
        let destination = directory.appendingPathComponent("preview-" + UUID().uuidString + ".wav")
        do {
            let writer = try PCMFileWriter(url: destination, format: format)
            try writer.write(buffer); try writer.close()
            return destination
        } catch { try? FileManager.default.removeItem(at: destination); throw error }
    }
}
