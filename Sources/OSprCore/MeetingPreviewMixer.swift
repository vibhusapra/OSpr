import Foundation
import AVFoundation
import Accelerate

public enum MeetingPreviewSource: String, Sendable { case system, microphone }

/// Same gap policy as durable desktop capture. Sub-frame clock jitter does not
/// insert or delete recorded samples; larger gaps are represented by silence.
public enum MeetingAudioClock {
    public static func gapFrames(timestamp: Double, previousEnd: Double, rate: Double) throws -> Int {
        let gap = timestamp - previousEnd
        guard timestamp.isFinite, previousEnd.isFinite, timestamp >= 0,
              rate.isFinite, (1000...384000).contains(rate), gap.isFinite, abs(gap) <= 3600 else {
            throw OSprError.message("Meeting audio has an invalid or excessive clock jump. Partial audio was kept.")
        }
        guard gap >= -0.1 else { throw OSprError.message("Meeting audio clock moved backwards. Stop and retry.") }
        return gap > 0.02 ? Int((gap * rate).rounded()) : 0
    }
}

/// Fixed sample FIFO plus a bounded segment ring. Clock gaps consume metadata,
/// not sample storage. A long silence cannot collide with unread audio as it
/// would in a ring indexed by absolute clock position. Caller owns serialization.
private final class TimedPreviewPCM {
    private struct Segment { var start = 0; var position = 0; var count = 0 }
    private var samples: [Float]
    private var segments = [Segment](repeating: Segment(), count: 1024)
    private var head = 0, segmentCount = 0, writePosition = 0
    private(set) var count = 0
    private(set) var consumedThrough: Int
    var capacity: Int { samples.count }
    init(capacity: Int, origin: Int) {
        samples = [Float](repeating: 0, count: capacity); consumedThrough = origin
    }
    func append(_ values: UnsafeBufferPointer<Float>, at start: Int) throws {
        guard start >= consumedThrough else {
            throw OSprError.message("A meeting source arrived too late for live preview. Final transcription will use the complete recording.")
        }
        guard values.count <= capacity - count else {
            throw OSprError.message("Meeting preview fell behind. Final transcription will use the complete recording.")
        }
        guard !values.isEmpty, let base = values.baseAddress else { return }
        let last = (head + segmentCount - 1 + segments.count) % segments.count
        let extendsLast = segmentCount > 0 && segments[last].start + segments[last].count == start
        guard extendsLast || segmentCount < segments.count else {
            throw OSprError.message("Too many discontinuous meeting packets for live preview.")
        }
        let first = min(values.count, capacity - writePosition)
        samples.withUnsafeMutableBufferPointer { destination in
            destination.baseAddress!.advanced(by: writePosition).update(from: base, count: first)
            if first < values.count { destination.baseAddress!.update(from: base.advanced(by: first), count: values.count - first) }
        }
        if extendsLast { segments[last].count += values.count }
        else {
            segments[(head + segmentCount) % segments.count] = Segment(start: start, position: writePosition, count: values.count)
            segmentCount += 1
        }
        writePosition = (writePosition + values.count) % capacity; count += values.count
    }
    /// Add the actual samples in this clock interval. Missing regions remain
    /// zero in the caller's destination, including absent or not-yet-started tracks.
    func add(into destination: UnsafeMutableBufferPointer<Float>, startingAt start: Int, gain: Float) {
        let end = start + destination.count
        while segmentCount > 0 {
            let segment = segments[head]
            if segment.start >= end { break }
            if segment.start < start {
                drop(min(segment.count, start - segment.start)); continue
            }
            let length = min(segment.count, end - segment.start)
            let offset = segment.start - start
            let first = min(length, capacity - segment.position)
            samples.withUnsafeBufferPointer { source in
                var weight = gain
                vDSP_vsma(source.baseAddress!.advanced(by: segment.position), 1, &weight,
                          destination.baseAddress!.advanced(by: offset), 1,
                          destination.baseAddress!.advanced(by: offset), 1, vDSP_Length(first))
                if first < length {
                    vDSP_vsma(source.baseAddress!, 1, &weight,
                              destination.baseAddress!.advanced(by: offset + first), 1,
                              destination.baseAddress!.advanced(by: offset + first), 1, vDSP_Length(length - first))
                }
            }
            drop(length)
        }
        consumedThrough = max(consumedThrough, end)
    }
    private func drop(_ length: Int) {
        segments[head].start += length
        segments[head].position = (segments[head].position + length) % capacity
        segments[head].count -= length; count -= length
        if segments[head].count == 0 { head = (head + 1) % segments.count; segmentCount -= 1 }
    }
}

/// Bounded, clock-aligned draft mix. Native samples are copied during ingress;
/// continuous resampling happens when the inference consumer asks for a packet.
/// Raw recording is independent. Call all methods on one capture-owned queue.
public final class MeetingPreviewMixer {
    private final class Track {
        let rate: Double, offset: Int
        let input: TimedPreviewPCM, output: TimedPreviewPCM
        let converter: StreamingSpeechResampler
        let scratch: AVAudioPCMBuffer
        var lastEnd: Double
        var written = 0, consumed = 0, normalizedEnd: Int
        var finished = false
        init(rate: Double, offset: Int, timestamp: Double, seconds: Int) throws {
            self.rate = rate; self.offset = offset; lastEnd = timestamp; normalizedEnd = offset
            input = TimedPreviewPCM(capacity: Int(rate) * seconds, origin: 0)
            output = TimedPreviewPCM(capacity: 16000 * seconds, origin: offset)
            converter = try StreamingSpeechResampler(sampleRate: rate)
            guard let scratch = AVAudioPCMBuffer(pcmFormat: converter.inputFormat, frameCapacity: 8192) else {
                throw OSprError.message("Could not allocate meeting preview conversion.")
            }
            self.scratch = scratch
        }
        func consume(through requested: Int, final: Bool) throws {
            let end = final ? min(written, requested) : requested
            while consumed < end {
                let length = min(8192, end - consumed)
                scratch.frameLength = AVAudioFrameCount(length)
                let buffer = UnsafeMutableBufferPointer(start: scratch.floatChannelData![0], count: length)
                buffer.initialize(repeating: 0)
                input.add(into: buffer, startingAt: consumed, gain: 1)
                consumed += length
                try converter.process(scratch) { values in
                    try output.append(values, at: normalizedEnd); normalizedEnd += values.count
                }
            }
            if final, !finished, consumed >= written {
                try converter.finish { values in
                    try output.append(values, at: normalizedEnd); normalizedEnd += values.count
                }
                finished = true
            }
        }
    }
    private let includeMicrophone: Bool
    private let bufferSeconds: Int
    private let reorderFrames: Int
    private var tracks: [MeetingPreviewSource: Track] = [:]
    private var anchor: Double?
    private var cursor: Int?
    private var firstFrame: Int?
    private var closed = false
    private var failure: Error?
    private var tail: AudioRing
    public private(set) var emittedSamples = 0
    public var startTime: Double? { firstFrame.flatMap { frame in anchor.map { $0 + Double(frame) / 16000 } } }
    public var bufferedInputSamples: Int { tracks.values.reduce(0) { $0 + $1.input.count } }
    public var allocatedSampleCapacity: Int { tracks.values.reduce(16000 * bufferSeconds) { $0 + $1.input.capacity + $1.output.capacity } }

    public init(includeMicrophone: Bool, bufferSeconds: Int = 12, reorderSeconds: Double = 0.5) throws {
        guard (1...12).contains(bufferSeconds), reorderSeconds.isFinite, (0...1).contains(reorderSeconds) else {
            throw OSprError.message("Invalid meeting preview buffer configuration.")
        }
        self.includeMicrophone = includeMicrophone; self.bufferSeconds = bufferSeconds
        reorderFrames = Int((reorderSeconds * 16000).rounded())
        tail = AudioRing(capacity: 16000 * bufferSeconds)
    }
    public func append(_ samples: UnsafeBufferPointer<Float>, source: MeetingPreviewSource,
                       sampleRate: Double, timestamp: Double) throws {
        if let failure { throw failure }
        do {
            guard !closed, source != .microphone || includeMicrophone,
                  sampleRate.isFinite, (8000...192000).contains(sampleRate), sampleRate.rounded() == sampleRate,
                  timestamp.isFinite, timestamp >= 0, timestamp.ulp <= 1 / sampleRate,
                  !samples.isEmpty, samples.count <= 8192, samples.allSatisfy(\.isFinite) else {
                throw OSprError.message("Invalid source, format or samples in meeting preview.")
            }
            if anchor == nil { anchor = timestamp }
            let relative = timestamp - anchor!
            guard abs(relative) <= 3612 else { throw OSprError.message("Meeting preview exceeded its clock limit.") }
            let track: Track
            if let existing = tracks[source] {
                guard existing.rate == sampleRate else { throw OSprError.message("A meeting source changed sample rate; preview stopped.") }
                track = existing
            } else {
                let offset = Int((relative * 16000).rounded())
                guard emittedSamples == 0 || offset >= cursor! else {
                    throw OSprError.message("A meeting source started behind live preview. Final transcription will use the complete recording.")
                }
                track = try Track(rate: sampleRate, offset: offset, timestamp: timestamp, seconds: bufferSeconds)
                tracks[source] = track
            }
            let gap = try MeetingAudioClock.gapFrames(timestamp: timestamp, previousEnd: track.lastEnd, rate: sampleRate)
            guard track.written + gap + samples.count <= Int(sampleRate * 3612) else {
                throw OSprError.message("Meeting preview exceeded its duration limit.")
            }
            try track.input.append(samples, at: track.written + gap)
            track.written += gap + samples.count
            track.lastEnd = timestamp + Double(samples.count) / sampleRate
        } catch { failure = error; throw error }
    }
    public func finish() { closed = true }
    public func snapshot(incremental: Bool) throws -> [Float] {
        if let failure { throw failure }
        do { return try take(incremental: incremental) }
        catch { failure = error; throw error }
    }
    private func take(incremental: Bool) throws -> [Float] {
        guard !tracks.isEmpty else { return [] }
        if emittedSamples == 0 { cursor = tracks.values.map(\.offset).min()! }
        guard let start = cursor else { return [] }
        let desired: Int
        if closed {
            desired = tracks.values.map { $0.offset + Int(ceil(Double($0.written) * 16000 / $0.rate)) + 1 }.max()!
        } else {
            desired = tracks.values.map { $0.offset + Int(floor(Double($0.written) * 16000 / $0.rate)) }.max()! - reorderFrames
        }
        guard desired > start else { return [] }
        let limit = min(desired, start + 16000 * bufferSeconds)
        for track in tracks.values where !track.finished {
            let target = max(0, Int(ceil(Double(limit - track.offset) * track.rate / 16000)))
            try track.consume(through: target, final: closed)
        }
        var end = limit
        for track in tracks.values where !track.finished { end = min(end, max(track.offset, track.normalizedEnd)) }
        if closed, tracks.values.allSatisfy(\.finished) { end = min(end, tracks.values.map(\.normalizedEnd).max()!) }
        guard end > start else { return [] }
        var mixed = [Float](repeating: 0, count: end - start)
        mixed.withUnsafeMutableBufferPointer { destination in
            // Fixed source order makes accumulation independent of dictionary order.
            for source in [MeetingPreviewSource.system, .microphone] {
                tracks[source]?.output.add(into: destination, startingAt: start, gain: includeMicrophone ? 0.5 : 1)
            }
        }
        for i in mixed.indices { mixed[i] = min(1, max(-1, mixed[i])) }
        mixed.withUnsafeBufferPointer { tail.append($0) }
        cursor = end; emittedSamples += mixed.count
        if firstFrame == nil { firstFrame = start }
        return incremental ? mixed : tail.snapshot()
    }
}
