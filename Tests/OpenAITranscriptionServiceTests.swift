import Foundation

enum OpenAITranscriptionServiceTests {
    static func run() {
        testKeywordsAreRepeatedAndOmittedWhenEmpty()
        testLanguagesAreRepeatedAndOmittedWhenEmpty()
        testPromptIsOmittedWhenBlank()
        testParseTranscriptExtractsText()
        testParseTranscriptRejectsGarbageAndEmptyText()
        testClassifyMapsStatusCodes()
        testIsRetryable()
        testRetryAfterParsing()
    }

    private static let boundary = "test-boundary"

    private static func body(
        keywords: [String] = [],
        languages: [String] = [],
        prompt: String? = nil
    ) -> String {
        let data = OpenAITranscriptionService.multipartBody(
            boundary: boundary,
            fileData: Data("RIFF-fake-wav".utf8),
            fileName: "recording.wav",
            model: OpenAITranscriptionService.model,
            keywords: keywords,
            languages: languages,
            prompt: prompt
        )
        return String(decoding: data, as: UTF8.self)
    }

    private static func occurrences(of needle: String, in haystack: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var index = haystack.startIndex
        while let range = haystack.range(of: needle, range: index..<haystack.endIndex) {
            count += 1
            index = range.upperBound
        }
        return count
    }

    private static func testKeywordsAreRepeatedAndOmittedWhenEmpty() {
        let withKeywords = body(keywords: ["Megaphone", "SwiftUI", "Kuber"])
        expectEqual(occurrences(of: "name=\"keywords[]\"", in: withKeywords), 3,
                    "Expected one keywords[] part per term")
        for term in ["Megaphone", "SwiftUI", "Kuber"] {
            expect(withKeywords.contains(term), "Missing keyword \(term)")
        }
        // The multipart body must always carry the file and the model.
        expect(withKeywords.contains("name=\"file\"; filename=\"recording.wav\""), "Missing file part")
        expect(withKeywords.contains("name=\"model\""), "Missing model part")
        expect(withKeywords.contains("gpt-transcribe"), "Missing model value")
        expect(withKeywords.hasSuffix("--\(boundary)--\r\n"), "Body is not terminated")

        let withoutKeywords = body(keywords: [])
        expect(!withoutKeywords.contains("keywords[]"),
               "Empty keywords array must omit the field entirely")
    }

    private static func testLanguagesAreRepeatedAndOmittedWhenEmpty() {
        let withLanguages = body(languages: ["en-US", "fr-FR"])
        expectEqual(occurrences(of: "name=\"languages[]\"", in: withLanguages), 2,
                    "Expected one languages[] part per code")
        expect(withLanguages.contains("en-US") && withLanguages.contains("fr-FR"),
               "Missing language codes")
        // `gpt-transcribe` reads the plural field; the legacy singular must
        // never be sent.
        expect(!withLanguages.contains("name=\"language\"\r\n"),
               "Sent the legacy singular language field")

        // "auto" maps to an empty array upstream, which omits the field.
        let withoutLanguages = body(languages: [])
        expect(!withoutLanguages.contains("languages[]"),
               "Empty languages array must omit the field entirely")
    }

    private static func testPromptIsOmittedWhenBlank() {
        expect(body(prompt: "Medical dictation").contains("name=\"prompt\""), "Missing prompt part")
        expect(!body(prompt: nil).contains("name=\"prompt\""), "nil prompt must be omitted")
        expect(!body(prompt: "   \n ").contains("name=\"prompt\""), "Blank prompt must be omitted")
    }

    private static func testParseTranscriptExtractsText() {
        let data = Data(#"{"text": "the transcript", "usage": {"type": "duration"}}"#.utf8)
        expectEqual(try? OpenAITranscriptionService.parseTranscript(from: data), "the transcript",
                    "Did not extract text")
    }

    private static func testParseTranscriptRejectsGarbageAndEmptyText() {
        expectThrows(.malformedResponse, from: Data("not json at all".utf8))
        expectThrows(.malformedResponse, from: Data(#"{"usage": {}}"#.utf8))
        expectThrows(.emptyTranscript, from: Data(#"{"text": "  "}"#.utf8))
        expectThrows(.emptyTranscript, from: Data(#"{"text": ""}"#.utf8))
    }

    private static func testClassifyMapsStatusCodes() {
        expect(OpenAITranscriptionService.classify(status: 200, headers: [:], body: Data()) == nil,
               "200 must classify as success")

        guard case .unauthorized? = OpenAITranscriptionService.classify(
            status: 401, headers: [:], body: Data()
        ) else {
            return fail("401 did not map to .unauthorized")
        }

        guard case .rateLimited(let retryAfter)? = OpenAITranscriptionService.classify(
            status: 429, headers: ["Retry-After": "3"], body: Data()
        ) else {
            return fail("429 did not map to .rateLimited")
        }
        expectEqual(retryAfter, 3, "Retry-After was not carried through")

        guard case .serverError(let status)? = OpenAITranscriptionService.classify(
            status: 503, headers: [:], body: Data()
        ) else {
            return fail("503 did not map to .serverError")
        }
        expectEqual(status, 503, "Server error lost its status code")

        guard case .fileTooLarge? = OpenAITranscriptionService.classify(
            status: 413, headers: [:], body: Data()
        ) else {
            return fail("413 did not map to .fileTooLarge")
        }

        guard case .badRequest(let message)? = OpenAITranscriptionService.classify(
            status: 400,
            headers: [:],
            body: Data(#"{"error": {"message": "unknown model"}}"#.utf8)
        ) else {
            return fail("400 did not map to .badRequest")
        }
        expectEqual(message, "unknown model", "Did not surface the API's error message")
    }

    private static func testIsRetryable() {
        let notRetryable: [OpenAITranscriptionError] = [
            .unauthorized,
            .badRequest("bad"),
            .fileTooLarge(bytes: 26_000_000),
            .missingAPIKey,
            .emptyTranscript,
            .malformedResponse
        ]
        for error in notRetryable {
            expect(!OpenAITranscriptionService.isRetryable(error),
                   "\(error) must not be retried")
        }

        let retryable: [OpenAITranscriptionError] = [
            .rateLimited(retryAfter: nil),
            .serverError(status: 500),
            .serverError(status: 503)
        ]
        for error in retryable {
            expect(OpenAITranscriptionService.isRetryable(error), "\(error) must be retried")
        }

        expect(OpenAITranscriptionService.isRetryable(URLError(.timedOut)), "Timeouts must be retried")
        expect(OpenAITranscriptionService.isRetryable(URLError(.networkConnectionLost)),
               "Dropped connections must be retried")
        expect(!OpenAITranscriptionService.isRetryable(URLError(.unsupportedURL)),
               "Programming errors must not be retried")
    }

    private static func testRetryAfterParsing() {
        expectEqual(OpenAITranscriptionService.retryAfterSeconds(in: ["retry-after": "5"]), 5,
                    "Header match must be case-insensitive")
        expect(OpenAITranscriptionService.retryAfterSeconds(in: [:]) == nil,
               "Missing header must yield nil")
        expect(OpenAITranscriptionService.retryAfterSeconds(in: ["Retry-After": "later"]) == nil,
               "Unparseable header must yield nil")
    }

    // MARK: - Assertions

    private static func expectThrows(
        _ expected: OpenAITranscriptionError,
        from data: Data,
        file: StaticString = #file,
        line: UInt = #line
    ) {
        do {
            let transcript = try OpenAITranscriptionService.parseTranscript(from: data)
            fail("Expected \(expected) but got \(transcript.debugDescription)", file: file, line: line)
        } catch let error as OpenAITranscriptionError {
            expect("\(error)" == "\(expected)",
                   "Expected \(expected) but got \(error)", file: file, line: line)
        } catch {
            fail("Expected \(expected) but got \(error)", file: file, line: line)
        }
    }

    private static func expectEqual<T: Equatable>(
        _ actual: T?,
        _ expected: T,
        _ message: String,
        file: StaticString = #file,
        line: UInt = #line
    ) {
        expect(actual == expected, "\(message) (got \(String(describing: actual)))",
               file: file, line: line)
    }

    private static func expect(
        _ condition: Bool,
        _ message: String,
        file: StaticString = #file,
        line: UInt = #line
    ) {
        if !condition {
            fail(message, file: file, line: line)
        }
    }

    private static func fail(
        _ message: String,
        file: StaticString = #file,
        line: UInt = #line
    ) {
        fatalError("OpenAITranscriptionServiceTests: \(message)", file: file, line: line)
    }
}
