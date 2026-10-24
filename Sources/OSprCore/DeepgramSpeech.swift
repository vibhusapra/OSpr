import Foundation
import CoreFoundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Native prerecorded Listen API. No SDK, callback, remote URL, extra inference
/// feature or cross-job speaker identity. App/CLI normalize audio locally first.
/// Contract: https://developers.deepgram.com/reference/speech-to-text/listen-pre-recorded
enum DeepgramSpeech {
    static func transcribe(file: URL, base: String, model: String, key: String,
                           language: String, vocabulary: String) async throws -> [String: Any] {
        try Task.checkCancellation()
        let endpoint = try ProviderClient.speechEndpoint(base: base, provider: "deepgram")
        guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !model.lowercased().hasPrefix("flux") else {
            throw OSprError.message("Choose a Deepgram prerecorded model such as nova-3. Flux requires the streaming API.")
        }
        let hints = vocabulary.components(separatedBy: CharacterSet(charactersIn: ",\n\r"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard hints.isEmpty || model.lowercased().hasPrefix("nova-3") else {
            throw OSprError.message("Deepgram vocabulary hints use Nova-3 keyterms. Choose nova-3 or clear vocabulary hints.")
        }
        guard hints.count <= 100 else { throw OSprError.message("OSpr accepts up to 100 Deepgram vocabulary phrases. The provider also applies its token limit.") }
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        var query = [URLQueryItem(name: "model", value: model), URLQueryItem(name: "punctuate", value: "true"),
                     URLQueryItem(name: "smart_format", value: "false"), URLQueryItem(name: "numerals", value: "false"),
                     URLQueryItem(name: "filler_words", value: "true"), URLQueryItem(name: "utterances", value: "true"),
                     URLQueryItem(name: "multichannel", value: "false")]
        query.append(URLQueryItem(name: language.isEmpty ? "detect_language" : "language", value: language.isEmpty ? "true" : language))
        query += hints.map { URLQueryItem(name: "keyterm", value: $0) }
        components.queryItems = query
        // URLComponents leaves '+' legal in a query, but form-style servers
        // decode it as a space. Preserve vocabulary such as C++ literally.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let url = components.url, url.absoluteString.utf8.count <= 16_000 else {
            throw OSprError.message("Deepgram vocabulary is too long. Shorten the phrases in Dictionary.")
        }
        let mimeTypes = ["wav": "audio/wav", "mp3": "audio/mpeg", "m4a": "audio/mp4", "flac": "audio/flac", "ogg": "audio/ogg"]
        guard let mime = mimeTypes[file.pathExtension.lowercased()] else {
            throw OSprError.message("Prepare Deepgram audio locally as WAV, MP3, M4A, FLAC or OGG first.")
        }
        guard let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0, size < ProviderClient.maximumUploadBytes else {
            throw OSprError.message("Prepare smaller Deepgram audio parts with OSpr file import.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        if !key.isEmpty { request.setValue("Token " + key, forHTTPHeaderField: "Authorization") }
        request.setValue(mime, forHTTPHeaderField: "Content-Type")
        let data = try Data(contentsOf: file)
        guard !data.isEmpty, data.count < ProviderClient.maximumUploadBytes else {
            throw OSprError.message("Prepared Deepgram audio exceeds the upload budget.")
        }
        request.httpBody = data
        try Task.checkCancellation()
        let began = Date()
        let response = try await ProviderClient.send(request)
        try Task.checkCancellation()
        var result = try normalized(response, requestedModel: model, language: language)
        result["total_ms"] = Date().timeIntervalSince(began) * 1000
        return result
    }

    static func normalized(_ response: [String: Any], requestedModel: String, language: String) throws -> [String: Any] {
        guard let metadata = response["metadata"] as? [String: Any], let duration = number(metadata["duration"]),
              duration >= 0, duration <= 4 * 3600,
              let results = response["results"] as? [String: Any], let channels = results["channels"] as? [[String: Any]], channels.count == 1,
              let alternatives = channels[0]["alternatives"] as? [[String: Any]], let alternative = alternatives.first,
              let text = alternative["transcript"] as? String, duration > 0 || text.isEmpty else {
            throw OSprError.message("Deepgram returned an invalid mono transcription response.")
        }
        var result: [String: Any] = ["text": text, "model": requestedModel, "audio_seconds": duration,
            "language": channels[0]["detected_language"] as? String ?? language, "segments": [], "provider": "deepgram"]
        let words = times(alternative["words"], duration: duration, utterances: false)
        if let words, !words.isEmpty { result["words"] = words }
        if let segments = times(results["utterances"], duration: duration, utterances: true), !segments.isEmpty {
            result["segments"] = segments; result["timestamp_source"] = "provider-utterances"
        } else if !text.isEmpty {
            let start = words?.first?["start"] as? Double ?? 0
            let end = words?.compactMap { $0["end"] as? Double }.max() ?? duration
            result["segments"] = [["start": start, "end": end, "text": text]]
            result["timestamp_source"] = words?.isEmpty == false ? "provider-word-bounds" : "coarse-upload-part"
        }
        return result
    }

    private static func times(_ value: Any?, duration: Double, utterances: Bool) -> [[String: Any]]? {
        guard let entries = value as? [[String: Any]] else { return nil }
        var normalized: [[String: Any]] = [], previous = 0.0
        for entry in entries {
            let text = utterances ? entry["transcript"] : entry["punctuated_word"] ?? entry["word"]
            guard let text = text as? String, let start = number(entry["start"]), let end = number(entry["end"]),
                  start >= previous, end >= start, end <= duration + 0.25 else { return nil }
            normalized.append(["start": min(start, duration), "end": min(end, duration), "text": text])
            previous = start
        }
        return normalized
    }
    private static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else { return nil }
        return number.doubleValue
    }
}
