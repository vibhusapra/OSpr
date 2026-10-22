import Foundation
import OSprCore

@main struct OSprCLI {
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        guard let command = args.first else { usage(); return }
        let root = ProcessInfo.processInfo.environment["OSPR_ROOT"] ?? FileManager.default.currentDirectoryPath
        let worker = WorkerClient(root: root)
        defer { worker.shutdown() }
        do {
            let result: [String: Any]
            switch command {
            case "doctor": result = try await worker.request(["action": "ping"])
            case "warm": result = try await worker.request(["action": "warm", "model": args.count > 1 ? args[1] : "parakeet-v3"])
            case "meeting":
                guard args.count > 1 else { usage(); exit(2) }
                result = try await worker.request(["action": "meeting", "path": URL(fileURLWithPath: args[1]).path,
                    "model": args.count > 2 ? args[2] : "parakeet-v3"])
            case "transcribe":
                guard args.count > 1 else { usage(); exit(2) }
                result = try await worker.request(["action": "transcribe", "path": URL(fileURLWithPath: args[1]).path,
                    "model": args.count > 2 ? args[2] : "parakeet-v3"])
            case "benchmark":
                guard args.count > 1 else { usage(); exit(2) }
                let model = args.count > 2 ? args[2] : "parakeet-v3"
                let count = min(100, max(1, args.count > 3 ? Int(args[3]) ?? 20 : 20))
                var runs: [[String: Any]] = []
                for index in 0...count {
                    let start = ContinuousClock.now
                    var response = try await worker.request(["action": "transcribe", "path": URL(fileURLWithPath: args[1]).path, "model": model])
                    let text = response["text"] as? String ?? ""
                    response["processed_text"] = TextPipeline.process(text, mode: .clean, replacements: [], spokenPunctuation: false)
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
    static func usage() { print("OSpr · local Apple Silicon dictation\nUsage: ospr-cli doctor | warm [model] | transcribe <audio> [model] | meeting <audio> [model] | benchmark <audio> [model] [repeats] | rewrite <text>\nRun from the checkout, or set OSPR_ROOT. Models: parakeet-v3, whisper-turbo, whisper-small, qwen3-asr, nemotron-streaming") }
}
