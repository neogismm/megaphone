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

    /// Per-request timeout. Generous enough for a multi-minute recording on a
    /// slow uplink, short enough that a hung socket does not strand the user.
    static let requestTimeout: TimeInterval = 60

    private static let maxAttempts = 3
    /// Backoff before attempt 2 and attempt 3.
    private static let backoffSeconds: [TimeInterval] = [1, 2]
    /// A `Retry-After` longer than this fails immediately rather than
    /// silently stalling the user with a frozen overlay.
    private static let maxHonoredRetryAfter: TimeInterval = 10

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
        var lastError: Error?

        for attempt in 0..<maxAttempts {
            try Task.checkCancellation()
            do {
                return try await transcribeOnce(
                    fileURL: fileURL,
                    apiKey: apiKey,
                    keywords: keywords,
                    languages: languages,
                    prompt: prompt
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
                guard attempt < maxAttempts - 1, isRetryable(error) else { throw error }

                var delay = backoffSeconds[attempt]
                if case OpenAITranscriptionError.rateLimited(let retryAfter) = error,
                   let retryAfter {
                    // Too long to wait behind a blocking overlay — bail now.
                    guard retryAfter <= maxHonoredRetryAfter else { throw error }
                    delay = max(delay, retryAfter)
                }

                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }

        throw lastError ?? OpenAITranscriptionError.malformedResponse
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
        request.timeoutInterval = requestTimeout
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        // Ephemeral session per request, invalidated after: no shared cache,
        // no cookie jar, no connection kept alive holding a key-scoped socket.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = requestTimeout
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }

        let (data, response) = try await withTaskCancellationHandler {
            try await session.data(for: request)
        } onCancel: {
            // Abort the in-flight upload so the cancel shortcut is immediate
            // rather than waiting out the 60s timeout.
            session.invalidateAndCancel()
        }

        try Task.checkCancellation()

        guard let http = response as? HTTPURLResponse else {
            throw OpenAITranscriptionError.malformedResponse
        }

        if let error = classify(status: http.statusCode, headers: http.allHeaderFields, body: data) {
            if case .unauthorized = error {
                // Let the user fix the key file without restarting the app.
                OpenAIKeyStore.reload()
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
            return .rateLimited(retryAfter: retryAfterSeconds(in: headers))
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

        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut, .networkConnectionLost, .cannotConnectToHost,
                 .dnsLookupFailed, .cannotFindHost, .notConnectedToInternet:
                return true
            default:
                return false
            }
        }

        return false
    }

    // MARK: - Header / body parsing

    /// `Retry-After` is either delta-seconds or an HTTP-date. Accept both.
    static func retryAfterSeconds(in headers: [AnyHashable: Any]) -> TimeInterval? {
        let raw = headers.first { key, _ in
            (key as? String)?.caseInsensitiveCompare("Retry-After") == .orderedSame
        }?.value as? String

        guard let value = raw?.trimmingCharacters(in: .whitespaces), !value.isEmpty else {
            return nil
        }

        if let seconds = TimeInterval(value) {
            return max(0, seconds)
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        if let date = formatter.date(from: value) {
            return max(0, date.timeIntervalSinceNow)
        }

        return nil
    }

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
