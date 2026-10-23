import Foundation
import CoreML
import OSprCore

enum SpeechDetection {
    static func endpoints(manifestURL: URL, silenceSeconds: Double) throws -> [[String: Any]] {
        struct Trace: Decodable { let id: String; let probabilities: [Double]; let audio_samples: Int; let chunk_samples: Int }
        let file = try FileHandle(forReadingFrom: manifestURL); defer { try? file.close() }
        let bytes = try file.read(upToCount: 8 * 1024 * 1024 + 1) ?? Data()
        guard bytes.count <= 8 * 1024 * 1024 else { throw OSprError.message("Speech trace manifest exceeds 8 MiB.") }
        let traces = try JSONDecoder().decode([Trace].self, from: bytes)
        guard !traces.isEmpty, traces.count <= 500, Set(traces.map(\.id)).count == traces.count else {
            throw OSprError.message("Speech replay needs 1–500 uniquely identified traces.")
        }
        let config = try SpeechEndpoint.Configuration(silenceSeconds: silenceSeconds)
        return try traces.map { trace in
            guard [512, 4096].contains(trace.chunk_samples), (1...300 * 16_000).contains(trace.audio_samples),
                  trace.probabilities.count == (trace.audio_samples + trace.chunk_samples - 1) / trace.chunk_samples else {
                throw OSprError.message("Speech replay trace has an invalid frame count.")
            }
            var endpoint = SpeechEndpoint(configuration: config); var events = [SpeechEndpoint.Event]()
            for (index, probability) in trace.probabilities.enumerated() {
                let start = index * trace.chunk_samples
                events += try endpoint.observe(probability: probability, startSample: start,
                    sampleCount: min(trace.chunk_samples, trace.audio_samples - start))
            }
            return ["id": trace.id, "events": try JSONSerialization.jsonObject(with: JSONEncoder().encode(events))]
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
