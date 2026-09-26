import Foundation

/// HTTP plumbing shared by the upload-based cloud engines (OpenAI, Gemini):
/// one ephemeral request that honours task cancellation, and the retry loop
/// around it. Provider specifics — request shape, error mapping, what counts
/// as retryable — stay in each provider's service.
enum CloudTranscriptionTransport {
    /// Per-request timeout. Generous enough for a multi-minute recording on a
    /// slow uplink, short enough that a hung socket does not strand the user.
    static let requestTimeout: TimeInterval = 60

    static let maxAttempts = 3
    /// Backoff before attempt 2 and attempt 3.
    static let backoffSeconds: [TimeInterval] = [1, 2]
    /// A server-requested retry delay longer than this fails immediately
    /// rather than silently stalling the user with a frozen overlay.
    static let maxHonoredRetryAfter: TimeInterval = 10

    /// Send one request on an ephemeral session created for it and
    /// invalidated after: no shared cache, no cookie jar, no connection kept
    /// alive holding a key-scoped socket.
    static func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try Task.checkCancellation()

        var request = request
        request.timeoutInterval = requestTimeout

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
            throw URLError(.badServerResponse)
        }
        return (data, http)
    }

    /// Run `operation` up to `maxAttempts` times with 1s/2s backoff.
    ///
    /// - Parameters:
    ///   - isRetryable: whether a failure is worth repeating. A wrong key or a
    ///     malformed request will fail identically every time.
    ///   - retryAfter: a server-requested delay carried by the error, if any.
    ///     Honoured when it is at most `maxHonoredRetryAfter`; a longer one
    ///     fails immediately.
    static func withRetries<T>(
        isRetryable: (Error) -> Bool,
        retryAfter: (Error) -> TimeInterval?,
        operation: () async throws -> T
    ) async throws -> T {
        var attempt = 0
        while true {
            try Task.checkCancellation()
            do {
                return try await operation()
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                guard attempt < maxAttempts - 1, isRetryable(error) else { throw error }

                var delay = backoffSeconds[attempt]
                if let requested = retryAfter(error) {
                    // Too long to wait behind a blocking overlay — bail now.
                    guard requested <= maxHonoredRetryAfter else { throw error }
                    delay = max(delay, requested)
                }

                attempt += 1
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
    }

    /// Transient network failures worth another attempt.
    static func isRetryableNetworkError(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .timedOut, .networkConnectionLost, .cannotConnectToHost,
             .dnsLookupFailed, .cannotFindHost, .notConnectedToInternet:
            return true
        default:
            return false
        }
    }

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
}
