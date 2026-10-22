import Foundation
import AVFoundation
import OSprCore

struct CaptureTelemetry {
    var rms: Float
    var receivedAt: Double
    var voiceAt: Double
    var hasVoice: Bool
}

/// The hardware tap touches only this locked audio state, never the main actor.
/// Levels/endpointing are polled at 10 Hz, avoiding a UI closure per audio block.
final class CapturePipeline: @unchecked Sendable {
    private let lock = NSLock()
    private let sink: AudioSink
    private let format: AVAudioFormat
    private let threshold: Float
    private var ring: AudioRing
    private var scratch = [Float](repeating: 0, count: 8192)
    private var active = true
    private var frames = 0
    private var previewFrames = 0
    private var latest: CaptureTelemetry
    private var failure: Error?
    init(sink: AudioSink, format: AVAudioFormat, threshold: Float, now: Double = ProcessInfo.processInfo.systemUptime) {
        self.sink = sink; self.format = format; self.threshold = threshold
        ring = AudioRing(capacity: Int(format.sampleRate * 12))
        latest = CaptureTelemetry(rms: 0, receivedAt: now, voiceAt: now, hasVoice: false)
    }
    func ingest(_ source: AVAudioPCMBuffer, now: Double = ProcessInfo.processInfo.systemUptime) {
        lock.lock(); defer { lock.unlock() }
        guard active else { return }
        guard source.format.isEqual(format), let channels = source.floatChannelData,
              source.frameLength > 0, source.frameLength <= 8192 else {
            failure = OSprError.message("The microphone format changed or returned an invalid audio block. Partial audio was kept.")
            return
        }
        sink.enqueue(source)
        let count = Int(source.frameLength)
        let rms = scratch.withUnsafeMutableBufferPointer { mono in
            let power = AudioMath.downmix(channels: channels, channelCount: Int(format.channelCount), frames: count,
                interleaved: format.isInterleaved, destination: mono)
            ring.append(UnsafeBufferPointer(start: mono.baseAddress, count: count))
            return power
        }
        guard rms.isFinite else {
            failure = OSprError.message("The microphone returned non-finite samples. Partial audio was kept.")
            return
        }
        frames += count; latest.rms = rms; latest.receivedAt = now
        if rms > threshold { latest.hasVoice = true; latest.voiceAt = now }
    }
    func telemetry() -> CaptureTelemetry { lock.lock(); defer { lock.unlock() }; return latest }
    func snapshot(incremental: Bool) throws -> [Float] {
        lock.lock(); defer { lock.unlock() }
        let delta = frames - previewFrames
        if incremental && delta > Int(format.sampleRate * 12) {
            throw OSprError.message("Streaming preview fell behind. Final transcription will use the complete recording.")
        }
        let samples = ring.snapshot(last: incremental ? delta : nil)
        if incremental { previewFrames = frames }
        return samples
    }
    var error: Error? { lock.lock(); defer { lock.unlock() }; return failure ?? sink.error }
    func finish() throws {
        lock.lock(); active = false; lock.unlock()
        try sink.finish()
        if let error { throw error }
    }
}
