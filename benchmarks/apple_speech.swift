// macOS 26+ research helper. File input only; no microphone, UI or cloud API.
// API contract checked against the local macOS 26.5 SDK and Apple documentation.
import Foundation
import AVFoundation
import Speech

private struct Request: Decodable { let id: String; let path: String }
private func emit(_ value: [String: Any]) throws {
    let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    FileHandle.standardOutput.write(data + Data([10]))
}
private func milliseconds(_ start: Double) -> Double {
    (ProcessInfo.processInfo.systemUptime - start) * 1000
}
private func number(_ value: Double) -> Any { value.isFinite ? value : NSNull() }

@available(macOS 26.0, *)
private struct Recognition {
    static func module(_ locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange])
    }
    static func inventory() async -> [String: Any] {
        ["available": SpeechTranscriber.isAvailable,
         "supported_locales": await SpeechTranscriber.supportedLocales.map(\.identifier).sorted(),
         "installed_locales": await SpeechTranscriber.installedLocales.map(\.identifier).sorted(),
         "reserved_locales": await AssetInventory.reservedLocales.map(\.identifier).sorted(),
         "maximum_reserved_locales": AssetInventory.maximumReservedLocales,
         "os": ProcessInfo.processInfo.operatingSystemVersionString]
    }
    static func prepare(_ locale: Locale) async throws -> [String: Any] {
        guard SpeechTranscriber.isAvailable,
              await SpeechTranscriber.supportedLocale(equivalentTo: locale) != nil else {
            throw NSError(domain: "OSprAppleSpeech", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Device or requested locale is unsupported."])
        }
        let started = ProcessInfo.processInfo.systemUptime
        let transcriber = module(locale)
        let before = await AssetInventory.status(forModules: [transcriber])
        // Apple's asset manager assigns this executable a locale reservation.
        // Already shared assets may make installation finish immediately.
        let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber])
        if let request { try await request.downloadAndInstall() }
        let after = await AssetInventory.status(forModules: [transcriber])
        guard after == .installed else {
            throw NSError(domain: "OSprAppleSpeech", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Asset preparation did not reach installed state."])
        }
        return ["status_before": String(describing: before), "status_after": String(describing: after),
                "installation_request": request != nil, "asset_prepare_ms": milliseconds(started)]
    }
    static func transcribe(_ request: Request, locale: Locale) async throws -> [String: Any] {
        let started = ProcessInfo.processInfo.systemUptime
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: request.path))
        let duration = Double(file.length) / file.processingFormat.sampleRate
        let transcriber = module(locale)
        let analyzer = SpeechAnalyzer(modules: [transcriber],
                                      options: .init(priority: .userInitiated, modelRetention: .processLifetime))
        let receiver = Task { () throws -> [[String: Any]] in
            var segments = [[String: Any]]()
            for try await result in transcriber.results {
                var runs = [[String: Any]]()
                for run in result.text.runs {
                    var item: [String: Any] = ["text": String(result.text[run.range].characters)]
                    if let time = run.audioTimeRange {
                        item["start"] = number(time.start.seconds); item["end"] = number(time.end.seconds)
                    }
                    runs.append(item)
                }
                segments.append(["text": String(result.text.characters), "start": number(result.range.start.seconds),
                                 "end": number(result.range.end.seconds), "final": result.isFinal, "timed_runs": runs])
            }
            return segments
        }
        do {
            let analyzed = try await analyzer.analyzeSequence(from: file)
            if let analyzed { try await analyzer.finalizeAndFinish(through: analyzed) }
            else { await analyzer.cancelAndFinishNow() }
            let segments = try await receiver.value
            let text = segments.compactMap { $0["text"] as? String }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
            return ["id": request.id, "ok": true, "text": text, "segments": segments,
                    "audio_seconds": duration, "source_frames": file.length,
                    "source_sample_rate": file.processingFormat.sampleRate,
                    "analyzed_through": analyzed.map { number($0.seconds) } ?? NSNull(),
                    "native_wall_ms": milliseconds(started)]
        } catch {
            await analyzer.cancelAndFinishNow(); receiver.cancel()
            throw error
        }
    }
}

@main private struct AppleSpeechResearch {
    static func main() async {
        do {
            guard #available(macOS 26.0, *) else {
                throw NSError(domain: "OSprAppleSpeech", code: 3,
                              userInfo: [NSLocalizedDescriptionKey: "This research helper requires macOS 26 or later."])
            }
            let args = Array(CommandLine.arguments.dropFirst())
            if args == ["inventory"] { try await emit(Recognition.inventory()); return }
            guard args.count == 2, args[0] == "serve" else {
                fputs("Usage: apple-speech inventory | serve <locale>\n", stderr); exit(2)
            }
            let locale = Locale(identifier: args[1])
            let before = await Recognition.inventory()
            let prepared = try await Recognition.prepare(locale)
            try emit(["event": "ready", "locale": locale.identifier, "inventory": before, "preparation": prepared,
                      "boundary": "Research file API; final results only, process-lifetime retention. Assets managed by the system; compute units/model revision are not exposed. Preparation may download models; no microphone or insertion."])
            while let line = readLine() {
                let request = try JSONDecoder().decode(Request.self, from: Data(line.utf8))
                do { try await emit(Recognition.transcribe(request, locale: locale)) }
                catch { try emit(["id": request.id, "ok": false, "error": error.localizedDescription]) }
            }
        } catch { fputs("\(error)\n", stderr); exit(1) }
    }
}
