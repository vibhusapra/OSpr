import Foundation
import CoreFoundation

/// Native async Files/Transcriptions API; no SDK, remote audio URL, translation,
/// diarization, webhook or background inference retry. Each call owns its IDs.
/// https://soniox.com/docs/api-reference/stt/transcriptions/create_transcription
enum SonioxSpeech {
    struct Policy: Sendable {
        var pollInterval: Duration = .seconds(1)
        var deadline: Duration = .seconds(600)
    }

    static func transcribe(file: URL, base: String, model: String, key: String,
                           language: String, vocabulary: String, policy: Policy = Policy()) async throws -> [String: Any] {
        try Task.checkCancellation()
        _ = try ProviderClient.endpoint(base: base, path: "files")
        guard !key.isEmpty else { throw OSprError.message("Enter a Soniox API key before uploading audio.") }
        guard model.hasPrefix("stt-async-"), model.utf8.count <= 32 else {
            throw OSprError.message("Choose a Soniox async model such as stt-async-v5. Real-time models require its streaming API.")
        }
        let hints = language.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let terms = vocabulary.components(separatedBy: CharacterSet(charactersIn: ",\n\r"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard hints.count <= 100, hints.allSatisfy({ $0.utf8.count <= 10 }), terms.count <= 100,
              vocabulary.utf8.count <= 16_000 else { throw OSprError.message("Shorten the Soniox language/vocabulary hints.") }
        let body = try multipart(file: file)
        let transport = Transport(base: base, key: key)
        defer { transport.close() }
        let began = ContinuousClock.now
        let stop = began.advanced(by: policy.deadline)
        let watchdog = Task {
            do { try await Task.sleep(for: policy.deadline) } catch { return }
            transport.close()
        }
        defer { watchdog.cancel() }
        var fileID: UUID?, jobID: UUID?
        var unknownJob = false
        do {
            let upload = try await transport.json(path: "files", method: "POST", body: body.data, contentType: body.contentType)
            fileID = try identifier(upload)
            try Task.checkCancellation()
            var config: [String: Any] = ["model": model, "file_id": fileID!.uuidString.lowercased(),
                "enable_speaker_diarization": false, "enable_language_identification": true,
                "client_reference_id": "OSpr-" + UUID().uuidString]
            if !hints.isEmpty { config["language_hints"] = hints; config["language_hints_strict"] = false }
            if !terms.isEmpty { config["context"] = ["terms": terms] }
            unknownJob = true
            var state: [String: Any]
            do { state = try await transport.json(path: "transcriptions", method: "POST", body: JSONSerialization.data(withJSONObject: config)) }
            catch Transport.Failure.http(let code) {
                // A rejected client request did not admit a transcription. A
                // timeout/server error has an ambiguous creation outcome.
                if (400..<500).contains(code), code != 408 { unknownJob = false }
                throw Transport.Failure.http(code)
            }
            jobID = try identifier(state); unknownJob = false
            while true {
                try Task.checkCancellation()
                guard let status = state["status"] as? String else { throw OSprError.message("Soniox returned an invalid job status.") }
                if status == "completed" { break }
                if status == "error" { throw OSprError.message("Soniox could not transcribe this audio. Check its console; the provider error body was not retained.") }
                guard ["queued", "processing"].contains(status) else { throw OSprError.message("Soniox returned an unsupported job status.") }
                guard ContinuousClock.now < stop else { throw OSprError.message("Soniox is still processing after OSpr's ten-minute wait limit.") }
                try await Task.sleep(for: min(policy.pollInterval, ContinuousClock.now.duration(to: stop)))
                state = try await transport.json(path: "transcriptions/" + jobID!.uuidString.lowercased())
                guard try identifier(state) == jobID else { throw OSprError.message("Soniox returned a different transcription ID.") }
            }
            let transcript = try await transport.json(path: "transcriptions/" + jobID!.uuidString.lowercased() + "/transcript")
            guard try identifier(transcript) == jobID else { throw OSprError.message("Soniox returned a different transcript ID.") }
            var result = try normalized(transcript, state: state, model: model, language: language)
            let cleanup = await cleanup(base: base, key: key, file: fileID, job: jobID, unknownJob: false)
            if let cleanup { result["warning"] = cleanup }
            else { fileID = nil; jobID = nil }
            try Task.checkCancellation()
            let elapsed = began.duration(to: .now).components
            result["total_ms"] = Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
            return result
        } catch {
            let cleanup = await cleanup(base: base, key: key, file: fileID, job: jobID, unknownJob: unknownJob)
            if Task.isCancelled { throw CancellationError() }
            let description = ContinuousClock.now >= stop ? "Soniox reached OSpr's wait limit." : error.localizedDescription
            if let cleanup { throw OSprError.message(description + " " + cleanup) }
            if ContinuousClock.now >= stop { throw OSprError.message(description) }
            throw error
        }
    }

    private static func identifier(_ value: [String: Any]) throws -> UUID {
        guard let raw = value["id"] as? String, let id = UUID(uuidString: raw) else {
            throw OSprError.message("Soniox returned an invalid resource ID. Check its console for pending uploads/jobs.")
        }
        return id
    }

    private static func multipart(file: URL) throws -> (data: Data, contentType: String) {
        let types = ["wav": "audio/wav", "mp3": "audio/mpeg", "m4a": "audio/mp4", "flac": "audio/flac", "ogg": "audio/ogg"]
        let ext = file.pathExtension.lowercased()
        guard let type = types[ext], let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size > 0, size < ProviderClient.maximumUploadBytes else { throw OSprError.message("Prepare smaller Soniox audio parts locally with OSpr file import.") }
        let boundary = "OSpr-" + UUID().uuidString
        var body = Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"client_reference_id\"\r\n\r\nOSpr-\(UUID().uuidString)\r\n--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"recording.\(ext)\"\r\nContent-Type: \(type)\r\n\r\n".utf8)
        let audio = try Data(contentsOf: file)
        guard !audio.isEmpty, audio.count < ProviderClient.maximumUploadBytes else { throw OSprError.message("Prepared Soniox audio exceeds the upload budget.") }
        body.append(audio); body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        guard body.count < ProviderClient.maximumUploadBytes else { throw OSprError.message("Soniox multipart request exceeds 25 MB. Use OSpr file import to prepare smaller parts.") }
        return (body, "multipart/form-data; boundary=" + boundary)
    }

    /// A canceled caller must not cancel its cleanup requests. No automatic
    /// recognition retry: processing/ambiguous jobs may remain at the provider.
    private static func cleanup(base: String, key: String, file: UUID?, job: UUID?, unknownJob: Bool) async -> String? {
        guard file != nil || job != nil else { return nil }
        return await Task.detached(priority: .utility) {
            let transport = Transport(base: base, key: key, timeout: 2)
            defer { transport.close() }
            do {
                if unknownJob { throw OSprError.message("Unknown job outcome") }
                if let job { try await transport.remove(path: "transcriptions/" + job.uuidString.lowercased()) }
                if let file { try await transport.remove(path: "files/" + file.uuidString.lowercased()) }
                return nil
            } catch {
                return "Soniox cleanup is incomplete; processing jobs cannot always be deleted. Check its console. File: \(file?.uuidString.lowercased() ?? "unknown"); transcription: \(job?.uuidString.lowercased() ?? "unknown")."
            }
        }.value
    }

    static func normalized(_ transcript: [String: Any], state: [String: Any], model: String, language: String) throws -> [String: Any] {
        guard let text = transcript["text"] as? String, let ms = number(state["audio_duration_ms"]), ms >= 0, ms <= 4 * 3600 * 1000,
              ms > 0 || text.isEmpty, let tokens = transcript["tokens"] as? [[String: Any]] else {
            throw OSprError.message("Soniox returned an invalid transcription response.")
        }
        let duration = ms / 1000
        var result: [String: Any] = ["text": text, "raw_text": text, "model": model, "provider": "soniox", "audio_seconds": duration,
            "language": language, "segments": text.isEmpty ? [] : [["start": 0.0, "end": duration, "text": text]], "timestamp_source": "coarse-upload-part"]
        var valid: [(text: String, start: Double, end: Double)] = [], previous = 0.0, languages = Set<String>()
        for token in tokens {
            guard let fragment = token["text"] as? String, let start = number(token["start_ms"]), let end = number(token["end_ms"]),
                  let confidence = number(token["confidence"]), (0...1).contains(confidence), start >= previous, end >= start, end <= ms + 250 else { return result }
            valid.append((fragment, min(start / 1000, duration), min(end / 1000, duration))); previous = start
            if let tag = token["language"] as? String, !tag.isEmpty { languages.insert(tag) }
        }
        guard !valid.isEmpty, valid.map(\.text).joined() == text else { return result }
        result["language"] = languages.count == 1 ? languages.first! : languages.count > 1 ? "mul" : language
        result["segments"] = [["start": valid[0].start, "end": valid.map(\.end).max()!, "text": text]]
        result["timestamp_source"] = "provider-token-bounds"
        // Group whitespace-delimited words only when boundaries coincide with
        // token boundaries. Never divide one token's time across multiple words.
        var words: [[String: Any]] = [], pending = "", start = 0.0, end = 0.0
        func finish() { if !pending.isEmpty { words.append(["start": start, "end": end, "text": pending]); pending = "" } }
        for token in valid {
            let runs = token.text.split(whereSeparator: \.isWhitespace)
            guard runs.count <= 1 else { return result }
            if token.text.first?.isWhitespace == true { finish() }
            if let run = runs.first {
                if pending.isEmpty { start = token.start; end = token.end }
                pending += run; end = max(end, token.end)
            }
            if token.text.last?.isWhitespace == true { finish() }
        }
        finish()
        if !words.isEmpty { result["words"] = words; result["timestamp_source"] = "provider-token-grouped-words" }
        return result
    }

    private static func number(_ value: Any?) -> Double? {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite else { return nil }
        return value.doubleValue
    }

    private final class Transport: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        enum Failure: LocalizedError {
            case http(Int)
            var errorDescription: String? { if case .http(let code) = self { return "Soniox returned HTTP \(code). Check the endpoint, model, key, quota and network." }; return nil }
        }
        let base: String, key: String, timeout: TimeInterval
        private var session: URLSession!
        private let lock = NSLock()
        private var closed = false
        init(base: String, key: String, timeout: TimeInterval = 120) {
            self.base = base; self.key = key; self.timeout = timeout
            super.init()
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = timeout; config.timeoutIntervalForResource = timeout
            config.httpCookieStorage = nil; config.urlCredentialStorage = nil; config.urlCache = nil
            session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        }
        func close() {
            lock.lock()
            let invalidate = !closed; closed = true
            lock.unlock()
            if invalidate { session.invalidateAndCancel() }
        }
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
        private func request(path: String, method: String, body: Data? = nil, contentType: String = "application/json") async throws -> (Data, Int) {
            var request = URLRequest(url: try ProviderClient.endpoint(base: base, path: path))
            request.httpMethod = method; request.httpBody = body
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
            if !key.isEmpty { request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization") }
            let cancellation = Cancellation()
            let (data, response): (Data, URLResponse) = try await withTaskCancellationHandler(operation: {
                try Task.checkCancellation()
                return try await withCheckedThrowingContinuation { continuation in
                    // Creating a task in an invalidated URLSession raises an
                    // Objective-C exception, not a Swift error. Fence creation
                    // against close; an already-created canceled task can safely
                    // be bound/resumed and reports through its completion.
                    lock.lock()
                    guard !closed else {
                        lock.unlock(); continuation.resume(throwing: URLError(.cancelled)); return
                    }
                    let task = session.dataTask(with: request) { data, response, error in
                        if let error { continuation.resume(throwing: error) }
                        else if let data, let response { continuation.resume(returning: (data, response)) }
                        else { continuation.resume(throwing: URLError(.badServerResponse)) }
                    }
                    lock.unlock()
                    cancellation.bind(task); task.resume()
                }
            }, onCancel: { cancellation.cancel() })
            guard let response = response as? HTTPURLResponse else { throw Failure.http(0) }
            return (data, response.statusCode)
        }
        func json(path: String, method: String = "GET", body: Data? = nil, contentType: String = "application/json") async throws -> [String: Any] {
            let (data, code) = try await request(path: path, method: method, body: body, contentType: contentType)
            guard (200..<300).contains(code) else { throw Failure.http(code) }
            guard data.count <= 32 * 1024 * 1024, let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw OSprError.message("Soniox returned an invalid or oversized JSON response.")
            }
            return object
        }
        func remove(path: String) async throws {
            let (_, code) = try await request(path: path, method: "DELETE")
            guard (200..<300).contains(code) || code == 404 else { throw Failure.http(code) }
        }

        private final class Cancellation: @unchecked Sendable {
            private let lock = NSLock()
            private var task: URLSessionTask?
            private var cancelled = false
            func bind(_ task: URLSessionTask) {
                lock.lock(); self.task = task; let cancel = cancelled; lock.unlock()
                if cancel { task.cancel() }
            }
            func cancel() {
                lock.lock(); cancelled = true; let task = task; lock.unlock()
                task?.cancel()
            }
        }
    }
}
