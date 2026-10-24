import Foundation
import CoreML
import AVFoundation
import OSprCore

enum SpeechDetection {
    static func probes(audioURL: URL, modelURL: URL) throws -> [String: Any] {
        let samples = try SpeechAudioInput.read(audioURL)
        let detector = try CoreMLSpeechDetector(modelURL: modelURL, computeUnits: .cpuOnly)
        guard detector.chunkSamples == 512 else { throw OSprError.message("Probe control requires the 32 ms model.") }
        var expected = [Double]()
        for start in stride(from: 0, to: samples.count, by: 512) {
            expected.append(try detector.predict(samples[start..<min(start + 512, samples.count)]))
        }
        detector.reset()
        var probes = 0
        for (index, start) in stride(from: 0, to: samples.count, by: 512).enumerated() {
            let end = min(start + 512, samples.count)
            for count in Set([1, min(17, end - start), min(511, end - start)]).sorted() {
                let first = try detector.probe(samples[start..<start + count])
                let second = try detector.probe(samples[start..<start + count])
                guard first == second else { throw OSprError.message("A partial probe committed recurrent state.") }
                probes += 2
            }
            guard try detector.predict(samples[start..<end]) == expected[index] else {
                throw OSprError.message("Partial probes changed the continuing model stream.")
            }
        }
        var rejected = false
        do { _ = try detector.probe([Float.nan][...]) } catch { rejected = true }
        guard rejected else { throw OSprError.message("Invalid probe unexpectedly succeeded.") }
        var poisoned = false
        do { _ = try detector.predict(samples.prefix(512)) } catch { poisoned = true }
        guard poisoned else { throw OSprError.message("A failed probe did not poison prediction.") }
        detector.reset()
        guard try detector.predict(samples.prefix(512)) == expected[0] else { throw OSprError.message("Probe reset failed.") }
        return ["status": "passed", "audio_samples": samples.count, "complete_or_final_model_frames": expected.count,
                "successful_partial_probes": probes, "exact_continuing_stream": true,
                "repeat_probe_identity": true, "invalid_probe_poisoned": true, "reset_recovered": true,
                "boundary": "Real pinned Core ML CPU inference on a local public file. Partial-tail probes restore context and recurrent state; failed probes remain poisoned. No microphone, capture scheduling or ASR."]
    }
    static func capture(audioURL: URL, modelURL: URL, packets: [Int], silenceSeconds: Double) throws -> [String: Any] {
        guard !packets.isEmpty, packets.count <= 20, packets.allSatisfy({ (128...8192).contains($0) }) else {
            throw OSprError.message("Capture replay needs 1–20 packet sizes between 128 and 8192 samples.")
        }
        let file = try AVAudioFile(forReading: audioURL)
        let format = file.processingFormat
        guard format.commonFormat == .pcmFormatFloat32, (1...8).contains(format.channelCount),
              format.sampleRate.isFinite, (8_000...192_000).contains(format.sampleRate),
              file.length > 0, Double(file.length) <= format.sampleRate * 300,
              let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192) else {
            throw OSprError.message("Capture replay requires at most five minutes of finite supported audio.")
        }
        let prepared = ContinuousClock.now
        let monitor = try NeuralCaptureMonitor(sampleRate: format.sampleRate, modelURL: modelURL, silenceSeconds: silenceSeconds)
        let preparationMS = milliseconds(prepared.duration(to: .now))
        defer { monitor.close() }
        var scratch = [Float](repeating: 0, count: 8192)
        var consumed: AVAudioFramePosition = 0
        var rows = [[String: Any]]()
        var firstFinish: [String: Any]?
        while consumed < file.length {
            let requested = min(packets[rows.count % packets.count], Int(file.length - consumed))
            try file.read(into: input, frameCount: AVAudioFrameCount(requested))
            guard input.frameLength > 0, let channels = input.floatChannelData else {
                throw OSprError.message("Capture replay encountered an early EOF.")
            }
            let count = Int(input.frameLength)
            let begin = ContinuousClock.now
            let rms = scratch.withUnsafeMutableBufferPointer { mono in
                let rms = AudioMath.downmix(channels: channels, channelCount: Int(format.channelCount), frames: count,
                    interleaved: format.isInterleaved, destination: mono)
                if rms.isFinite { monitor.enqueue(UnsafeBufferPointer(start: mono.baseAddress, count: count)) }
                return rms
            }
            guard rms.isFinite else { throw OSprError.message("Capture replay encountered non-finite input.") }
            monitor.synchronize()
            consumed += AVAudioFramePosition(count)
            let snapshot = monitor.snapshot()
            if let warning = snapshot.warning { throw OSprError.message(warning) }
            guard snapshot.receivedInputSamples == consumed, snapshot.processedInputSamples == consumed,
                  snapshot.queuedInputSamples == 0, let observation = snapshot.observation else {
                throw OSprError.message("Capture replay did not examine every received block.")
            }
            var row: [String: Any] = ["input_samples": consumed, "normalized_samples": observation.normalizedSamples,
                "incomplete_frame_samples": observation.incompleteFrameSamples, "has_speech": observation.hasSpeech,
                "enqueue_through_drain_ms": milliseconds(begin.duration(to: .now))]
            if let candidate = observation.candidate {
                row["candidate"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(candidate))
                if firstFinish == nil { firstFinish = row }
            }
            rows.append(row)
        }
        return ["input_sample_rate": format.sampleRate, "input_channels": format.channelCount,
                "input_samples": consumed, "packet_sizes": packets, "preparation_ms": preparationMS,
                "first_finish": firstFinish ?? NSNull(), "records": rows,
                "boundary": "Accelerated packet replay through the actual preallocated monitor, continuous AVAudioConverter, native Core ML, causal score, retractable endpoint and partial-tail probes. Each packet drains before the next; this does not simulate real-time contention. Dry-run candidates do not stop the source; complete input remains intact. Converter filter latency and packet polling are included in sample-frontier differences, not measured hardware/UI latency."]
    }
    static func endpoints(manifestURL: URL, silenceSeconds: Double, windowFrames: Int = 1) throws -> [[String: Any]] {
        struct Trace: Decodable { let id: String; let probabilities: [Double]; let audio_samples: Int; let chunk_samples: Int }
        let file = try FileHandle(forReadingFrom: manifestURL); defer { try? file.close() }
        let bytes = try file.read(upToCount: 8 * 1024 * 1024 + 1) ?? Data()
        guard bytes.count <= 8 * 1024 * 1024 else { throw OSprError.message("Speech trace manifest exceeds 8 MiB.") }
        let traces = try JSONDecoder().decode([Trace].self, from: bytes)
        guard !traces.isEmpty, traces.count <= 500, Set(traces.map(\.id)).count == traces.count else {
            throw OSprError.message("Speech replay needs 1–500 uniquely identified traces.")
        }
        let config = try SpeechEndpoint.Configuration(silenceSeconds: silenceSeconds)
        _ = try CausalSpeechScore(windowFrames: windowFrames)
        return try traces.map { trace in
            guard [512, 4096].contains(trace.chunk_samples), (1...300 * 16_000).contains(trace.audio_samples),
                  trace.probabilities.count == (trace.audio_samples + trace.chunk_samples - 1) / trace.chunk_samples else {
                throw OSprError.message("Speech replay trace has an invalid frame count.")
            }
            guard windowFrames == 1 || trace.chunk_samples == 512 else {
                throw OSprError.message("Eight-frame aggregation is evaluated only for 32 ms detector frames.")
            }
            var endpoint = SpeechEndpoint(configuration: config); var events = [SpeechEndpoint.Event]()
            var scoring = try CausalSpeechScore(windowFrames: windowFrames); var scores = [Double]()
            for (index, probability) in trace.probabilities.enumerated() {
                let start = index * trace.chunk_samples
                let score = try scoring.consume(probability)
                if windowFrames != 1 { scores.append(score) }
                events += try endpoint.observe(probability: score, startSample: start,
                    sampleCount: min(trace.chunk_samples, trace.audio_samples - start))
            }
            var result: [String: Any] = ["id": trace.id, "events": try JSONSerialization.jsonObject(with: JSONEncoder().encode(events))]
            if windowFrames != 1 { result["activity_scores"] = scores; result["score_window_frames"] = windowFrames }
            return result
        }
    }
    static func run(audioURL: URL, modelURL: URL, units: String, silenceSeconds: Double) throws -> [String: Any] {
        let (detector, config, loadMS) = try prepare(modelURL: modelURL, units: units, silenceSeconds: silenceSeconds)
        var result = try analyze(audioURL: audioURL, detector: detector, config: config)
        result["load_ms"] = loadMS; result["compute_units_requested"] = units
        return result
    }
    static func replay(manifestURL: URL, modelURL: URL, units: String, silenceSeconds: Double) throws -> [String: Any] {
        struct Item: Decodable { let id: String; let path: String }
        let file = try FileHandle(forReadingFrom: manifestURL); defer { try? file.close() }
        let bytes = try file.read(upToCount: 4 * 1024 * 1024 + 1) ?? Data()
        guard bytes.count <= 4 * 1024 * 1024 else { throw OSprError.message("Speech replay manifest exceeds 4 MiB.") }
        let items = try JSONDecoder().decode([Item].self, from: bytes)
        guard !items.isEmpty, items.count <= 500, Set(items.map(\.id)).count == items.count else {
            throw OSprError.message("Speech replay needs 1–500 uniquely identified files.")
        }
        let (detector, config, loadMS) = try prepare(modelURL: modelURL, units: units, silenceSeconds: silenceSeconds)
        let primeStarted = ContinuousClock.now
        let zeros = [Float](repeating: 0, count: detector.chunkSamples)
        for _ in 0..<3 { _ = try detector.predict(zeros[...]) }
        let primeMS = milliseconds(primeStarted.duration(to: .now))
        var records = [[String: Any]]()
        for item in items {
            detector.reset()
            var record: [String: Any]
            do { record = try analyze(audioURL: URL(fileURLWithPath: item.path), detector: detector, config: config) }
            catch { throw OSprError.message("Speech replay failed for \(item.id.prefix(80)): \(error.localizedDescription)") }
            record["id"] = item.id; records.append(record)
        }
        return ["records": records, "load_ms": loadMS, "prime_ms": primeMS, "compute_units_requested": units,
                "boundary": "One serial resident Core ML model, three discarded synthetic prime frames, fresh recurrent/endpoint state for every public fixture. No real-time scheduling or physical microphone. Requested compute units do not prove actual execution devices."]
    }
    private static func prepare(modelURL: URL, units: String, silenceSeconds: Double) throws -> (CoreMLSpeechDetector, SpeechEndpoint.Configuration, Double) {
        let config = try SpeechEndpoint.Configuration(silenceSeconds: silenceSeconds)
        let compute: MLComputeUnits
        switch units {
        case "cpu": compute = .cpuOnly
        case "gpu": compute = .cpuAndGPU
        case "ane": compute = .cpuAndNeuralEngine
        case "all": compute = .all
        default: throw OSprError.message("Compute units must be cpu, gpu, ane or all.")
        }
        let start = ContinuousClock.now
        let detector = try CoreMLSpeechDetector(modelURL: modelURL, computeUnits: compute)
        return (detector, config, milliseconds(start.duration(to: .now)))
    }
    private static func analyze(audioURL: URL, detector: CoreMLSpeechDetector, config: SpeechEndpoint.Configuration) throws -> [String: Any] {
        let samples = try SpeechAudioInput.read(audioURL)
        var endpoint = SpeechEndpoint(configuration: config)
        var probabilities = [Double](), times = [Double](), events = [SpeechEndpoint.Event]()
        for offset in stride(from: 0, to: samples.count, by: detector.chunkSamples) {
            let count = min(detector.chunkSamples, samples.count - offset)
            let begin = ContinuousClock.now
            let probability = try detector.predict(samples[offset..<offset + count])
            times.append(milliseconds(begin.duration(to: .now))); probabilities.append(probability)
            events += try endpoint.observe(probability: probability, startSample: offset, sampleCount: count)
        }
        let encodedEvents = try JSONSerialization.jsonObject(with: JSONEncoder().encode(events))
        let encodedConfig = try JSONSerialization.jsonObject(with: JSONEncoder().encode(config))
        return ["sample_rate": 16_000, "audio_samples": samples.count, "chunk_samples": detector.chunkSamples,
            "probabilities": probabilities,
            "prediction_ms": times, "events": encodedEvents, "endpoint_configuration": encodedConfig,
            "boundary": "Offline Core ML probability and one-shot endpoint replay. Compute units are requested eligibility, not proof of actual hardware execution. No microphone, resampling, ASR or insertion. Last partial frame is zero-padded; endpoint time uses only real samples."]
    }
    private static func milliseconds(_ duration: Duration) -> Double {
        let c = duration.components; return Double(c.seconds) * 1000 + Double(c.attoseconds) / 1e15
    }
}
