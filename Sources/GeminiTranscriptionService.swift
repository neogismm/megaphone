import Foundation

enum GeminiTranscriptionError: Error, LocalizedError {
    case missingAPIKey
    case fileTooLarge(bytes: Int)
    case unauthorized
    case rateLimited(retryAfter: TimeInterval?)
    case serverError(status: Int)
    case badRequest(String)
    case interactionFailed(String)
    case emptyTranscript
    case malformedResponse

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "No Gemini API key found."
        case .fileTooLarge(let bytes):
            return "Recording is \(bytes) bytes, over Gemini's inline upload limit."
        case .unauthorized:
            return "Gemini rejected the API key."
        case .rateLimited:
            return "Gemini rate limited the request."
        case .serverError(let status):
            return "Gemini returned server error \(status)."
        case .badRequest(let message):
            return "Gemini rejected the request: \(message)"
        case .interactionFailed(let message):
            return "Gemini could not transcribe the recording: \(message)"
        case .emptyTranscript:
            return "Gemini returned an empty transcript."
        case .malformedResponse:
            return "Gemini returned a response Megaphone could not parse."
        }
    }
}

/// Upload-based transcription against Google's `gemini-3.5-transcribe`, via
/// the Gemini Interactions API.
///
/// Shaped like `OpenAITranscriptionService`: a namespace of statics with the
/// request built by hand on `URLSession` — the build is a raw `swiftc`
/// invocation with no package manager, so there is no SDK. Unlike OpenAI's
/// multipart upload, Gemini takes JSON with the WAV inlined as base64.
enum GeminiTranscriptionService {
    static let model = "gemini-3.5-transcribe"
    static let endpoint = URL(string: "https://generativelanguage.googleapis.com/v1beta/interactions")!

    /// Inline audio rides inside a JSON request capped at roughly 20 MB, and
    /// base64 inflates it by a third. 14 MiB of 16 kHz mono PCM16 WAV is about
    /// 7.5 minutes — ample for dictation. Checked up front so an over-long
    /// recording fails instantly instead of uploading only to earn a 413.
    static let maxUploadBytes = 14 * 1024 * 1024

    /// `verbatim` returns the literal words and leaves cleanup to Megaphone.
    /// `smart` has Gemini drop fillers, resolve self-corrections and format.
    enum Mode: String {
        case verbatim
        case smart
    }

    // MARK: - Public entry points

    /// Retry wrapper: 3 attempts total with 1s/2s backoff. See `isRetryable`
    /// for which failures are worth repeating.
    static func transcribe(
        fileURL: URL,
        apiKey: String,
        mode: Mode,
        vocabulary: [String],
        languages: [String]
    ) async throws -> String {
        try await CloudTranscriptionTransport.withRetries(
            isRetryable: isRetryable,
            retryAfter: { error in
                if case GeminiTranscriptionError.rateLimited(let retryAfter) = error {
                    return retryAfter
                }
                return nil
            }
        ) {
            try await transcribeOnce(
                fileURL: fileURL,
                apiKey: apiKey,
                mode: mode,
                vocabulary: vocabulary,
                languages: languages
            )
        }
    }

    /// One attempt. No retry logic, no fallback — the caller decides.
    static func transcribeOnce(
        fileURL: URL,
        apiKey: String,
        mode: Mode,
        vocabulary: [String],
        languages: [String]
    ) async throws -> String {
        try Task.checkCancellation()

        let fileData = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        guard fileData.count <= maxUploadBytes else {
            throw GeminiTranscriptionError.fileTooLarge(bytes: fileData.count)
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try requestBody(
            audioData: fileData,
            mode: mode,
            vocabulary: vocabulary,
            languages: languages
        )

        let (data, http) = try await CloudTranscriptionTransport.send(request)

        if let error = classify(status: http.statusCode, headers: http.allHeaderFields, body: data) {
            if case .unauthorized = error {
                // Let the user fix the key file without restarting the app.
                APIKeyStore.reload(.gemini)
            }
            throw error
        }

        return try parseTranscript(from: data)
    }

    // MARK: - Pure helpers

    /// The Interactions API request. `custom_vocabulary` and `language_codes`
    /// are omitted entirely when empty — an empty `language_codes` already
    /// means auto-detect, and omitting keeps the request minimal. `store` is
    /// false so Google does not retain the interaction for later retrieval.
    static func requestBody(
        audioData: Data,
        mode: Mode,
        vocabulary: [String],
        languages: [String]
    ) throws -> Data {
        var transcriptionConfig: [String: Any] = ["mode": mode.rawValue]

        let vocabulary = vocabulary.filter { !$0.isEmpty }
        if !vocabulary.isEmpty {
            transcriptionConfig["custom_vocabulary"] = vocabulary
        }

        let languages = languages.filter { !$0.isEmpty }
        if !languages.isEmpty {
            transcriptionConfig["language_codes"] = languages
        }

        let body: [String: Any] = [
            "model": model,
            "input": [
                [
                    "type": "audio",
                    "mime_type": "audio/wav",
                    "data": audioData.base64EncodedString()
                ]
            ],
            "generation_config": [
                "transcription_config": transcriptionConfig
            ],
            "store": false
        ]

        return try JSONSerialization.data(withJSONObject: body, options: [.withoutEscapingSlashes])
    }

    /// Pull the transcript out of an Interaction: the text content of the
    /// trailing `model_output` step, concatenated. Falls back to a top-level
    /// `outputs` array, the shape earlier Interactions API revisions used.
    static func parseTranscript(from data: Data) throws -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GeminiTranscriptionError.malformedResponse
        }

        let contents: [[String: Any]]?
        if let steps = object["steps"] as? [[String: Any]] {
            let lastOutput = steps.last { ($0["type"] as? String) == "model_output" }
            contents = lastOutput?["content"] as? [[String: Any]]
        } else {
            contents = object["outputs"] as? [[String: Any]]
        }

        let text = (contents ?? [])
            .filter { ($0["type"] as? String) == "text" }
            .compactMap { $0["text"] as? String }
            .joined()

        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return text
        }

        // Never hand an empty string to the paste pipeline — downstream would
        // happily "paste" nothing and look like a silent failure.

        if (object["status"] as? String) == "failed" {
            let errors = object["errors"] as? [[String: Any]]
            let message = errors?.compactMap { $0["message"] as? String }.first
            throw GeminiTranscriptionError.interactionFailed(message ?? "status failed")
        }
        if contents == nil {
            throw GeminiTranscriptionError.malformedResponse
        }
        throw GeminiTranscriptionError.emptyTranscript
    }

    /// Map an HTTP status onto a typed error, or nil for success.
    ///
    /// Google reports a bad key as `400 INVALID_ARGUMENT` with reason
    /// `API_KEY_INVALID`, not as a 401, so the body decides that case.
    static func classify(
        status: Int,
        headers: [AnyHashable: Any],
        body: Data
    ) -> GeminiTranscriptionError? {
        let error = googleError(in: body)

        switch status {
        case 200..<300:
            return nil
        case 401, 403:
            return .unauthorized
        case 400 where error?.reasons.contains("API_KEY_INVALID") == true:
            return .unauthorized
        case 413:
            return .fileTooLarge(bytes: 0)
        case 429:
            let delay = error?.retryDelay ?? CloudTranscriptionTransport.retryAfterSeconds(in: headers)
            return .rateLimited(retryAfter: delay)
        case 400..<500:
            return .badRequest(error?.message ?? "status \(status)")
        default:
            return .serverError(status: status)
        }
    }

    /// Which failures are worth repeating. A wrong key or a malformed request
    /// will fail identically three times; a 429 or a 5xx may not.
    static func isRetryable(_ error: Error) -> Bool {
        if let geminiError = error as? GeminiTranscriptionError {
            switch geminiError {
            case .rateLimited, .serverError:
                return true
            case .missingAPIKey, .unauthorized, .badRequest, .fileTooLarge,
                 .interactionFailed, .emptyTranscript, .malformedResponse:
                return false
            }
        }
        return CloudTranscriptionTransport.isRetryableNetworkError(error)
    }

    // MARK: - Error body parsing

    struct GoogleError: Equatable {
        var message: String?
        /// `ErrorInfo.reason` values, e.g. `API_KEY_INVALID`.
        var reasons: [String]
        /// `RetryInfo.retryDelay`, in seconds.
        var retryDelay: TimeInterval?
    }

    /// Parse Google's `{"error": {...}}` envelope. The Interactions endpoint
    /// has been seen to wrap it in a one-element array, so accept both.
    static func googleError(in body: Data) -> GoogleError? {
        let root = try? JSONSerialization.jsonObject(with: body)
        let envelope = (root as? [String: Any]) ?? (root as? [[String: Any]])?.first
        guard let error = envelope?["error"] as? [String: Any] else { return nil }

        let details = error["details"] as? [[String: Any]] ?? []
        let reasons = details.compactMap { $0["reason"] as? String }
        let retryDelay = details
            .compactMap { $0["retryDelay"] as? String }
            .compactMap(durationSeconds)
            .first

        let message = (error["message"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return GoogleError(message: message, reasons: reasons, retryDelay: retryDelay)
    }

    /// Protobuf JSON durations are strings like `"13s"` or `"0.5s"`.
    static func durationSeconds(_ value: String) -> TimeInterval? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasSuffix("s"), let seconds = TimeInterval(trimmed.dropLast()) else {
            return nil
        }
        return max(0, seconds)
    }
}
