import Foundation
import OSprCore

@main struct OSprCLI {
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        guard let command = args.first else { usage(); return }
        let root = EngineLocation.resolve()
        let worker = WorkerClient(root: root)
        defer { worker.shutdown() }
        do {
            let result: [String: Any]
            switch command {
            case "_benchmark-speech-probes":
                guard args.count == 3 else { usage(); exit(2) }
                result = try SpeechDetection.probes(audioURL: URL(fileURLWithPath: args[1]), modelURL: URL(fileURLWithPath: args[2]))
            case "_benchmark-speech-capture":
                guard (3...5).contains(args.count) else { usage(); exit(2) }
                let packets = args.count >= 4 ? args[3].split(separator: ",").map { Int($0) ?? 0 } : [1024]
                result = try SpeechDetection.capture(audioURL: URL(fileURLWithPath: args[1]), modelURL: URL(fileURLWithPath: args[2]),
                    packets: packets, silenceSeconds: args.count == 5 ? Double(args[4]) ?? .nan : 1.2)
            case "_benchmark-speech-endpoints":
                guard (2...4).contains(args.count) else { usage(); exit(2) }
                result = ["records": try SpeechDetection.endpoints(manifestURL: URL(fileURLWithPath: args[1]),
                    silenceSeconds: args.count >= 3 ? Double(args[2]) ?? .nan : 1.2,
                    windowFrames: args.count == 4 ? Int(args[3]) ?? 0 : 1)]
            case "analyze-speech", "_benchmark-speech-detector":
                guard (3...5).contains(args.count) else { usage(); exit(2) }
                let silence = args.count == 5 ? Double(args[4]) ?? .nan : 1.2
                if command == "analyze-speech" {
                    result = try SpeechDetection.run(audioURL: URL(fileURLWithPath: args[1]), modelURL: URL(fileURLWithPath: args[2]),
                        units: args.count >= 4 ? args[3] : "cpu", silenceSeconds: silence)
                } else {
                    result = try SpeechDetection.replay(manifestURL: URL(fileURLWithPath: args[1]), modelURL: URL(fileURLWithPath: args[2]),
                        units: args.count >= 4 ? args[3] : "cpu", silenceSeconds: silence)
                }
            case "resolve-profile":
                guard (3...4).contains(args.count) else { usage(); exit(2) }
                result = try ProfileResolution.run(file: URL(fileURLWithPath: args[1]), bundleID: args[2], document: args.count == 4 ? args[3] : nil)
            case "doctor": result = try await worker.request(["action": "ping"])
            case "verify-audio-review":
                guard args.count > 1 else { usage(); exit(2) }
                result = try await AudioReviewCheck.run(source: URL(fileURLWithPath: args[1]), worker: worker)
            case "benchmark-history": result = try await HistoryBenchmark.run(rows: args.count > 1 ? Int(args[1]) ?? 10_000 : 10_000, edits: args.count > 2 ? Int(args[2]) ?? 50 : 50)
            case "benchmark-history-index": result = try HistoryIndexBenchmark.run(rows: args.count > 1 ? Int(args[1]) ?? 25_000 : 25_000, repeats: args.count > 2 ? Int(args[2]) ?? 3 : 3)
            case "benchmark-history-session": result = try HistorySessionBenchmark.run(rows: args.count > 1 ? Int(args[1]) ?? 25_000 : 25_000)
            case "_benchmark-history-index-case":
                guard args.count == 4, let count = Int(args[3]) else { usage(); exit(2) }
                if args[2] == "session" { result = try await HistorySessionBenchmark.measure(directory: URL(fileURLWithPath: args[1]), count: count) }
                else { result = try HistoryIndexBenchmark.measure(directory: URL(fileURLWithPath: args[1]), mode: args[2], count: count) }
            case "models": result = try await worker.request(["action": "model_status"])
            case "download":
                guard args.count > 1 else { usage(); exit(2) }
                result = try await worker.request(["action": "download_model", "model": args[1]], progress: { event in
                    if let data = try? JSONSerialization.data(withJSONObject: event, options: [.sortedKeys]) {
                        FileHandle.standardError.write(data + Data([10]))
                    }
                })
            case "warm": result = try await worker.request(["action": "warm", "model": args.count > 1 ? args[1] : "parakeet-v3"])
            case "meeting":
                guard args.count > 1 else { usage(); exit(2) }
                result = try await worker.request(["action": "meeting", "path": URL(fileURLWithPath: args[1]).path,
                    "model": args.count > 2 ? args[2] : "parakeet-v3"])
            case "transcribe":
                guard args.count > 1 else { usage(); exit(2) }
                result = try await worker.request(["action": "transcribe", "path": URL(fileURLWithPath: args[1]).path,
                    "model": args.count > 2 ? args[2] : "parakeet-v3"])
            case "transcribe-cloud", "transcribe-deepgram", "transcribe-soniox":
                guard args.count >= 4 else { usage(); exit(2) }
                let provider = command == "transcribe-deepgram" ? "deepgram" : command == "transcribe-soniox" ? "soniox" : "compatible"
                _ = try ProviderClient.speechEndpoint(base: args[2], provider: provider)
                let workspace = try ProviderUploadWorkspace()
                defer { workspace.close() }
                let manifest = try await worker.request(["action": "prepare_upload_parts", "path": URL(fileURLWithPath: args[1]).path, "output_dir": workspace.url.path])
                let plan = try ProviderUploadPlan(manifest, directory: workspace.url)
                result = try await ProviderClient.transcribe(plan: plan, base: args[2], model: args[3],
                    key: ProcessInfo.processInfo.environment["OSPR_TRANSCRIPTION_KEY"] ?? "",
                    language: args.count > 4 ? args[4] : "", vocabulary: "", provider: provider, progress: { part, total in
                        FileHandle.standardError.write(Data("Uploading audio part \(part)/\(total)\n".utf8))
                    })
            case "benchmark":
                guard args.count > 1 else { usage(); exit(2) }
                let model = args.count > 2 ? args[2] : "parakeet-v3"
                let count = min(100, max(1, args.count > 3 ? Int(args[3]) ?? 20 : 20))
                var runs: [[String: Any]] = []
                for index in 0...count {
                    let start = ContinuousClock.now
                    var response = try await worker.request(["action": "transcribe", "path": URL(fileURLWithPath: args[1]).path, "model": model])
                    let text = response["text"] as? String ?? ""
                    response["processed_text"] = TextPipeline.process(text, mode: .clean, replacements: [], spokenPunctuation: false, language: response["language"] as? String ?? "")
                    let elapsed = start.duration(to: .now).components
                    response["native_wall_ms"] = Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
                    response["trial"] = index; response["cold"] = index == 0
                    runs.append(response)
                }
                let times = runs.dropFirst().compactMap { $0["native_wall_ms"] as? Double }.sorted()
                result = ["model": model, "warm_trials": count, "cold_ms": runs.first?["native_wall_ms"] ?? 0,
                    "p50_ms": times[times.count / 2], "p95_ms": times[min(times.count - 1, Int(Double(times.count) * 0.95))],
                    "boundary": "Swift CLI → owned Python worker → model → deterministic text rules; excludes microphone, UI and insertion.", "runs": runs]
            case "rewrite":
                guard args.count > 1 else { usage(); exit(2) }
                result = try await worker.request(["action": "rewrite", "text": args[1], "instruction": "Remove filler words and fix punctuation. Preserve meaning."])
            default: usage(); exit(2)
            }
            let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            print(String(data: data, encoding: .utf8)!)
        } catch { FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8)); exit(1) }
    }
    static func usage() { print("OSpr · Apple Silicon dictation\nUsage: ospr-cli analyze-speech <16k-mono.wav> <model.mlmodelc> [cpu|gpu|ane|all] [silence-seconds] | resolve-profile <settings.json> <bundle-id> [document-url] | doctor | models | download <model> | warm [model] | transcribe <audio> [model] | transcribe-cloud <audio> <base-url> <model> [language] | transcribe-deepgram <audio> <base-url> <model> [language] | transcribe-soniox <audio> <base-url> <model> [language] | meeting <audio> [model] | benchmark <audio> [model] [repeats] | benchmark-history [rows] [edits] | benchmark-history-index [rows] [repeats] | benchmark-history-session [rows] | verify-audio-review <short-audio> | rewrite <text>\ntranscribe-cloud (compatible) transcribe-deepgram (native Listen), and transcribe-soniox (native async jobs) explicitly upload audio to the specified provider; the key is read from OSPR_TRANSCRIPTION_KEY, never a command-line argument. Other speech commands remain local. resolve-profile only inspects the supplied settings and URL; it does not load a model or contact a provider.\nProgress is on stderr; final result is JSON on stdout.\nBundled CLI discovers its engine; development commands use the checkout or OSPR_ROOT. Models: parakeet-v3, cohere-native8, whisper-turbo, whisper-small, qwen3-asr, nemotron-streaming") }
}
