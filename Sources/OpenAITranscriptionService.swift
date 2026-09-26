import Foundation

enum OpenAITranscriptionError: Error, LocalizedError {
    case missingAPIKey
    case fileTooLarge(bytes: Int)
    case unauthorized
    case rateLimited(retryAfter: TimeInterval?)
    case serverError(status: Int)
    case badRequest(String)
    case emptyTranscript
    case malformedResponse

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "No OpenAI API key found."
        case .fileTooLarge(let bytes):
            return "Recording is \(bytes) bytes, over OpenAI's 25 MB upload limit."
        case .unauthorized:
            return "OpenAI rejected the API key."
        case .rateLimited:
            return "OpenAI rate limited the request."
        case .serverError(let status):
            return "OpenAI returned server error \(status)."
        case .badRequest(let message):
            return "OpenAI rejected the request: \(message)"
        case .emptyTranscript:
            return "OpenAI returned an empty transcript."
        case .malformedResponse:
            return "OpenAI returned a response Megaphone could not parse."
        }
    }
}

/// Upload-based transcription against OpenAI's `gpt-transcribe`.
///
/// Shaped like `SpeechAnalyzerService`: a namespace of statics, no instances,
/// no protocol. The whole request is hand-built on `URLSession` — the build is
/// a raw `swiftc` invocation with no package manager, so there is no SDK.
enum OpenAITranscriptionService {
    static let model = "gpt-transcribe"
    static let maxUploadBytes = 25 * 1024 * 1024
    static let endpoint = URL(string: "https://api.openai.com/v1/audio/transcriptions")!

    // MARK: - Public entry points

    /// Retry wrapper: 3 attempts total with 1s/2s backoff. See `isRetryable`
    /// for which failures are worth repeating.
    static func transcribe(
        fileURL: URL,
        apiKey: String,
        keywords: [String],
        languages: [String],
        prompt: String?
    ) async throws -> String {
        try await CloudTranscriptionTransport.withRetries(
            isRetryable: isRetryable,
            retryAfter: { error in
                if case OpenAITranscriptionError.rateLimited(let retryAfter) = error {
                    return retryAfter
                }
                return nil
            }
        ) {
            try await transcribeOnce(
                fileURL: fileURL,
                apiKey: apiKey,
                keywords: keywords,
                languages: languages,
                prompt: prompt
            )
        }
    }

    /// One attempt. No retry logic, no fallback — the caller decides.
    static func transcribeOnce(
        fileURL: URL,
        apiKey: String,
        keywords: [String],
        languages: [String],
        prompt: String?
    ) async throws -> String {
        try Task.checkCancellation()

        let fileData = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        // Check before building the body so an over-long recording fails
        // instantly instead of uploading 25 MB to earn a 413.
        guard fileData.count <= maxUploadBytes else {
            throw OpenAITranscriptionError.fileTooLarge(bytes: fileData.count)
        }

        let boundary = "megaphone-\(UUID().uuidString)"
        let body = multipartBody(
            boundary: boundary,
            fileData: fileData,
            fileName: fileURL.lastPathComponent,
            model: model,
            keywords: keywords,
            languages: languages,
            prompt: prompt
        )

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let (data, http) = try await CloudTranscriptionTransport.send(request)

        if let error = classify(status: http.statusCode, headers: http.allHeaderFields, body: data) {
            if case .unauthorized = error {
                // Let the user fix the key file without restarting the app.
                APIKeyStore.reload(.openAI)
            }
            throw error
        }

        return try parseTranscript(from: data)
    }

    // MARK: - Pure helpers

    /// Hand-rolled `multipart/form-data`. `keywords[]` and `languages[]` are
    /// repeated parts — one per term — and are omitted entirely when empty.
    static func multipartBody(
        boundary: String,
        fileData: Data,
        fileName: String,
        model: String,
        keywords: [String],
        languages: [String],
        prompt: String?
    ) -> Data {
        var body = Data()

        func appendString(_ string: String) {
            body.append(Data(string.utf8))
        }

        func appendField(name: String, value: String) {
            appendString("--\(boundary)\r\n")
            appendString("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            appendString(value)
            appendString("\r\n")
        }

        appendString("--\(boundary)\r\n")
        appendString("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\n")
        appendString("Content-Type: audio/wav\r\n\r\n")
        body.append(fileData)
        appendString("\r\n")

        appendField(name: "model", value: model)

        for keyword in keywords where !keyword.isEmpty {
            appendField(name: "keywords[]", value: keyword)
        }

        // Plural for this model. The legacy singular `language` field is not
        // what `gpt-transcribe` reads, so it is never sent.
        for language in languages where !language.isEmpty {
            appendField(name: "languages[]", value: language)
        }

        if let prompt, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            appendField(name: "prompt", value: prompt)
        }

        appendString("--\(boundary)--\r\n")
        return body
    }

    /// Pull `text` out of the default JSON response body.
    static func parseTranscript(from data: Data) throws -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = object["text"] as? String else {
            throw OpenAITranscriptionError.malformedResponse
        }
        // Never hand an empty string to the paste pipeline — downstream would
        // happily "paste" nothing and look like a silent failure.
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw OpenAITranscriptionError.emptyTranscript
        }
        return text
    }

    /// Map an HTTP status onto a typed error, or nil for success.
    static func classify(
        status: Int,
        headers: [AnyHashable: Any],
        body: Data
    ) -> OpenAITranscriptionError? {
        switch status {
        case 200..<300:
            return nil
        case 401, 403:
            return .unauthorized
        case 413:
            return .fileTooLarge(bytes: 0)
        case 429:
            return .rateLimited(retryAfter: CloudTranscriptionTransport.retryAfterSeconds(in: headers))
        case 400..<500:
            return .badRequest(errorMessage(in: body) ?? "status \(status)")
        default:
            return .serverError(status: status)
        }
    }

    /// Which failures are worth repeating. A wrong key or a malformed request
    /// will fail identically three times; a 429 or a 5xx may not.
    static func isRetryable(_ error: Error) -> Bool {
        if let openAIError = error as? OpenAITranscriptionError {
            switch openAIError {
            case .rateLimited, .serverError:
                return true
            case .missingAPIKey, .unauthorized, .badRequest, .fileTooLarge,
                 .emptyTranscript, .malformedResponse:
                return false
            }
        }

        return CloudTranscriptionTransport.isRetryableNetworkError(error)
    }

    // MARK: - Header / body parsing

    /// Best-effort `{"error": {"message": ...}}` extraction for 4xx bodies.
    static func errorMessage(in body: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let error = object["error"] as? [String: Any],
              let message = error["message"] as? String,
              !message.isEmpty else {
            return nil
        }
        return message
    }
}
