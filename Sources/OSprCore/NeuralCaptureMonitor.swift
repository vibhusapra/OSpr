import AVFoundation

public struct NeuralCaptureSnapshot {
    public let receivedInputSamples: Int
    public let processedInputSamples: Int
    public let queuedInputSamples: Int
    public let observation: LiveSpeechObservation?
    public let warning: String?
    public let accepting: Bool
}

/// Bounded sidecar to the complete recording writer. The callback only copies
/// mono floats into preallocated slots. One owning queue performs normalization,
/// inference and tail probes. Failures disable automatic finishing, never drop
/// audio from the independent original/recovery recording.
public final class NeuralCaptureMonitor: @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.ospr.speech-monitor", qos: .userInitiated)
    private let lock = NSLock()
    private let process: (AVAudioPCMBuffer) throws -> LiveSpeechObservation
    private var pool: [AVAudioPCMBuffer]
    private let maximumQueuedSamples: Int
    private var accepting = true
    private var received = 0
    private var processed = 0
    private var queued = 0
    private var observation: LiveSpeechObservation?
    private var failure: String?

    /// Prepare off the main actor before installing a hardware tap. No download
    /// occurs here; the caller supplies the separately verified pinned asset.
    public convenience init(sampleRate: Double, modelURL: URL, silenceSeconds: Double) throws {
        let model = try CoreMLSpeechDetector(modelURL: modelURL, computeUnits: .cpuOnly)
        guard model.chunkSamples == 512 else { throw OSprError.message("Choose the pinned 32 ms speech detector.") }
        let zeros = [Float](repeating: 0, count: 512)
        for _ in 0..<3 { _ = try model.predict(zeros[...]) }
        model.reset()
        let processor = try NeuralCaptureProcessor(sampleRate: sampleRate, model: model, silenceSeconds: silenceSeconds)
        try self.init(sampleRate: sampleRate, process: { try processor.process($0) })
    }
    init(sampleRate: Double, bufferCount: Int = 16, maximumQueuedSeconds: Double = 0.5,
         process: @escaping (AVAudioPCMBuffer) throws -> LiveSpeechObservation) throws {
        guard sampleRate.isFinite, (8_000...192_000).contains(sampleRate), (1...16).contains(bufferCount),
              maximumQueuedSeconds.isFinite, (0.01...0.5).contains(maximumQueuedSeconds),
              let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else {
            throw OSprError.message("Invalid bounded speech monitor configuration.")
        }
        self.process = process; maximumQueuedSamples = Int(floor(sampleRate * maximumQueuedSeconds))
        pool = try (0..<bufferCount).map { _ in
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192) else {
                throw OSprError.message("Could not allocate bounded speech monitor buffers.")
            }
            return buffer
        }
    }
    public func enqueue(_ samples: UnsafeBufferPointer<Float>) {
        lock.lock(); defer { lock.unlock() }
        guard accepting, failure == nil else { return }
        guard !samples.isEmpty, samples.count <= 8192, received <= Int.max - samples.count else {
            fail("Speech detection received an invalid audio block. Stop manually."); return
        }
        received += samples.count
        guard samples.count <= maximumQueuedSamples - queued, let buffer = pool.popLast() else {
            fail("Speech detection fell behind. Automatic finish is disabled; stop manually. The complete recording is still being saved.")
            return
        }
        let through = received
        buffer.frameLength = AVAudioFrameCount(samples.count)
        buffer.floatChannelData![0].update(from: samples.baseAddress!, count: samples.count)
        queued += samples.count
        // Schedule while admission is locked, so close/barrier cannot race
        // between taking a slot and enqueuing its work.
        queue.async { [self] in
            lock.lock(); let run = accepting && failure == nil; lock.unlock()
            var result: LiveSpeechObservation?
            var problem: Error?
            if run {
                do { result = try process(buffer) } catch { problem = error }
            }
            lock.lock(); defer { lock.unlock() }
            queued -= Int(buffer.frameLength); pool.append(buffer)
            guard accepting, failure == nil else { return }
            if let problem { fail("Speech detection failed. Stop manually. " + problem.localizedDescription); return }
            if let result {
                guard result.normalizedSamples >= (observation?.normalizedSamples ?? 0),
                      result.incompleteFrameSamples == result.normalizedSamples % 512,
                      result.candidate == nil || (result.hasSpeech && result.normalizedSamples > 0 &&
                        result.candidate?.kind == .finished && result.candidate!.boundarySample >= 0 &&
                        result.candidate!.boundarySample <= result.normalizedSamples &&
                        result.candidate?.observedThroughSample == result.normalizedSamples) else {
                    fail("Speech detection returned an inconsistent frontier. Stop manually."); return
                }
                processed = through; observation = result
            }
        }
    }
    public func snapshot() -> NeuralCaptureSnapshot {
        lock.lock(); defer { lock.unlock() }
        return .init(receivedInputSamples: received, processedInputSamples: processed, queuedInputSamples: queued,
                     observation: observation, warning: failure, accepting: accepting)
    }
    /// The owner must call while holding the same ingress lock that protects
    /// capture's active flag, then close capture admission before releasing it.
    /// This atomic claim also closes this monitor, preventing a read-then-stop race.
    public func claimFinish(expectedInputSamples: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard accepting, failure == nil, received > 0, received == expectedInputSamples,
              processed == received, queued == 0, let observation, observation.hasSpeech,
              let candidate = observation.candidate, candidate.kind == .finished,
              candidate.observedThroughSample == observation.normalizedSamples else { return false }
        accepting = false
        return true
    }
    /// Closes only the optional monitor. In-flight work cannot publish after close.
    public func close() { lock.lock(); accepting = false; lock.unlock() }
    /// Offline replay/testing only. Never block the hardware callback or UI.
    public func synchronize() { queue.sync {} }
    private func fail(_ message: String) { failure = message; accepting = false; observation = nil }
}
