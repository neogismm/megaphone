# Spec — optional OpenAI `gpt-transcribe` engine for Megaphone

Status: ready to implement. Written against commit `5a9136b`.

## 1. Goal

Add OpenAI's `gpt-transcribe` as a **second, optional** transcription engine.
Apple's on-device SpeechAnalyzer remains the default and stays fully working.

Behaviour: hold the existing hotkey → speak → release → the completed recording
is uploaded to `gpt-transcribe` → the returned text is pasted at the cursor.

### Non-goals — do not implement

- No realtime / live / streaming transcription. No WebSocket. No
  `v1/realtime/transcription_sessions`.
- No voice-response, TTS, or conversational functionality.
- No changes to post-processing (Foundation Models cleanup, Dictionary,
  wake commands, voice macros, paste logic). Those are engine-agnostic and
  must keep working unchanged on both engines.
- No `stream=true`. The response is parsed as a single JSON body.
- No README / website / `llms.txt` changes. This is a personal-use build;
  the privacy copy is explicitly out of scope.
- No API-key entry UI inside the app.

## 2. Hard constraints — read before writing code

1. **No package manager.** The build is a raw `swiftc` invocation over
   `$(shell find Sources -name '*.swift' -type f)` — see `Makefile:13` and
   `Makefile:44`. There is no SPM, no `Package.swift`, no Xcode project.
   **Do not add the OpenAI Swift SDK or any third-party dependency.**
   Use `Foundation` / `URLSession` and hand-build the multipart body.
2. New files under `Sources/` are picked up automatically by that `find`.
   New files under `Tests/` are **not** — `Makefile:107` lists test sources
   explicitly, twice (prerequisite list and the `swiftc` command). Both
   occurrences must be updated together.
3. **The app is not sandboxed.** `Megaphone.entitlements` contains only
   `com.apple.security.device.audio-input`. No network entitlement is needed
   or should be added.
4. Everything compiles as a single module. New types are visible everywhere
   without `import`.
5. Target is `-target <arch>-apple-macosx26.0`. Swift 6 concurrency applies;
   match the surrounding code's actor/`Sendable` discipline.

## 3. Verified API reference

| Field | Value |
| --- | --- |
| Endpoint | `POST https://api.openai.com/v1/audio/transcriptions` |
| Auth | `Authorization: Bearer <key>` |
| Content type | `multipart/form-data` |
| Model | `gpt-transcribe` |
| Max upload | **25 MB** |
| Accepted formats | mp3, mp4, mpeg, mpga, m4a, **wav**, webm |

Multipart fields:

| Field | Notes |
| --- | --- |
| `file` | required — the recorded WAV |
| `model` | required — literal `gpt-transcribe` |
| `keywords[]` | optional, **repeated field**, one per term |
| `languages[]` | optional, **repeated field**, BCP-47 codes |
| `prompt` | optional, free-form context string |

`languages` is **plural** for this model. Do not send the legacy singular
`language` field.

Response (default JSON) — parse `text`:

```json
{ "text": "the transcript", "usage": { ... } }
```

## 4. Existing architecture — the seam

The recorder already produces two independent outputs from one capture session
(`Sources/AudioRecorder.swift`):

- a **16 kHz mono PCM16 WAV file** written to disk (`AudioRecorder.swift:99`
  documents it as being for upload-based transcription)
- a live 24 kHz PCM16 callback `onPCM16Samples`, currently feeding
  `SpeechAnalyzerStreamingSession`

All transcription funnels through **one function**:

`AppState.resolveRawTranscript(streamingSession:fileURL:)` — `Sources/AppState.swift:2865`

It takes `(SpeechAnalyzerStreamingSession?, URL)` and returns the raw
transcript string. Everything downstream of it — `parseTranscriptCommands`,
scratch detection, Dictionary corrections, Foundation Models cleanup, paste —
is already engine-agnostic.

**This function is the entire integration point.** Do not add engine branching
anywhere else in the pipeline.

At 16 kHz mono PCM16 the WAV is 32 KB/s, so the 25 MB cap is roughly
13 minutes of held hotkey.

## 5. New files

### 5.1 `Sources/TranscriptionEngine.swift`

```swift
enum TranscriptionEngine: String, CaseIterable, Identifiable {
    case appleOnDevice = "apple"
    case openAI = "openai"

    var id: String { rawValue }

    /// Settings picker label.
    var title: String {
        switch self {
        case .appleOnDevice: return "Apple (on-device)"
        case .openAI:        return "OpenAI"
        }
    }

    var isCloud: Bool { self == .openAI }
}
```

Model this on `SmartCleanupMode` (`Sources/AppState.swift:23`), which is the
established pattern in this codebase.

### 5.2 `Sources/OpenAIKeyStore.swift`

Reads the API key from disk. **No UI.**

Resolution order:

1. `OPENAI_API_KEY` environment variable, if non-empty after trimming.
2. Contents of `~/.config/megaphone/openai-key`, trimmed of whitespace and
   newlines.

Return `nil` if neither yields a non-empty value.

```swift
enum OpenAIKeyStore {
    static func currentKey() -> String?   // cached
    static func reload()                  // clears the cache
}
```

Cache the resolved value in memory. Call `reload()` on a `401` so the user can
correct the file without restarting the app.

**Important:** the env var is a convenience only. The app is `LSUIElement` and
registers via `SMAppService.mainApp` (`AppState.swift:1385`), so at login it
inherits launchd's environment, not the user's shell. The file is the reliable
path; do not treat the env var as primary.

### 5.3 `Sources/OpenAITranscriptionService.swift`

Mirror the shape of `SpeechAnalyzerService` — an `enum` namespace of statics,
not a class, not a protocol.

```swift
enum OpenAITranscriptionError: Error, LocalizedError {
    case missingAPIKey
    case fileTooLarge(bytes: Int)
    case unauthorized
    case rateLimited(retryAfter: TimeInterval?)
    case serverError(status: Int)
    case badRequest(String)
    case emptyTranscript
    case malformedResponse
}

enum OpenAITranscriptionService {
    static let model = "gpt-transcribe"
    static let maxUploadBytes = 25 * 1024 * 1024

    /// One attempt. No retry logic here.
    static func transcribeOnce(
        fileURL: URL,
        apiKey: String,
        keywords: [String],
        languages: [String],
        prompt: String?
    ) async throws -> String

    /// Retry wrapper. See section 7 for policy.
    static func transcribe(
        fileURL: URL,
        apiKey: String,
        keywords: [String],
        languages: [String],
        prompt: String?
    ) async throws -> String

    // Pure, unit-testable helpers:
    static func multipartBody(
        boundary: String,
        fileData: Data,
        fileName: String,
        model: String,
        keywords: [String],
        languages: [String],
        prompt: String?
    ) -> Data

    static func parseTranscript(from data: Data) throws -> String

    static func classify(
        status: Int,
        headers: [AnyHashable: Any],
        body: Data
    ) -> OpenAITranscriptionError?

    static func isRetryable(_ error: Error) -> Bool
}
```

Implementation notes:

- Use an **ephemeral** `URLSession` created per request and invalidated after,
  matching the deleted `LLMAPITransport` pattern (recoverable at
  `git show 2fb6439^:Sources/LLMAPITransport.swift`). No shared session, no
  connection reuse.
- Check file size **before** building the body; throw `.fileTooLarge` rather
  than uploading and eating a 413.
- Honour cancellation. The transcription `Task` is cancelled by the cancel
  shortcut (`AppState.swift` cancels `transcriptionTask`); an in-flight upload
  must actually abort. Use `withTaskCancellationHandler` and/or check
  `Task.checkCancellation()` between retries.
- Set `request.timeoutInterval` to something sane (60s) and align the session
  configuration timeouts to it.
- `keywords` / `languages` are emitted as **repeated** multipart parts named
  exactly `keywords[]` and `languages[]`. Omit entirely when the array is empty.
- Empty or whitespace-only `text` in the response → throw `.emptyTranscript`.
  Do not return an empty string into the paste pipeline.

## 6. Wiring into `AppState`

### 6.1 Setting

Add alongside the other settings, following the existing pattern exactly:

```swift
private let transcriptionEngineStorageKey = "transcription_engine"

@Published var transcriptionEngine: TranscriptionEngine {
    didSet {
        UserDefaults.standard.set(transcriptionEngine.rawValue,
                                  forKey: transcriptionEngineStorageKey)
    }
}
```

Load in `init()` next to the `smartCleanupMode` load (`AppState.swift:745`):

```swift
let transcriptionEngine = TranscriptionEngine(
    rawValue: UserDefaults.standard.string(forKey: transcriptionEngineStorageKey) ?? ""
) ?? .appleOnDevice
```

**Default is `.appleOnDevice`.** Existing installs must not change behaviour.

### 6.2 Skip the Apple streaming session when OpenAI is selected

`startNativeStreamingSession()` is called unconditionally at
`AppState.swift:2344` inside `beginRecording(triggerMode:)`.

Gate it:

```swift
if !useOpenAIForThisSession {
    startNativeStreamingSession()
}
```

Running the Apple analyzer while OpenAI is selected would force the Apple
speech-model download and burn CPU for a result that is thrown away.

### 6.3 Pre-flight network check

Decide the engine for the session **at record start**, not at transcribe time,
and store it on the session.

```swift
private var activeSessionEngine: TranscriptionEngine = .appleOnDevice
```

In `beginRecording`:

- If `transcriptionEngine == .openAI` and `NetworkMonitor.shared.isOnline == false`:
  - set `activeSessionEngine = .appleOnDevice`
  - show the toast `"No network — using Apple for this one"`
  - start the Apple streaming session as normal
- If `transcriptionEngine == .openAI` and `OpenAIKeyStore.currentKey() == nil`:
  - same fallback, toast `"No API key — using Apple for this one"`
- Otherwise `activeSessionEngine = transcriptionEngine`.

`NetworkMonitor.shared.isOnline` already runs continuously from launch and is
currently dead code. This is what it exists for.

### 6.4 The switch in `resolveRawTranscript`

`AppState.swift:2865`. Keep the existing Apple logic byte-for-byte in its
branch; only add the new one.

```swift
private func resolveRawTranscript(
    streamingSession: SpeechAnalyzerStreamingSession?,
    fileURL: URL
) async throws -> String {
    switch activeSessionEngine {
    case .appleOnDevice:
        // ... existing body, unchanged ...
    case .openAI:
        guard let key = OpenAIKeyStore.currentKey() else {
            throw OpenAITranscriptionError.missingAPIKey
        }
        return try await OpenAITranscriptionService.transcribe(
            fileURL: fileURL,
            apiKey: key,
            keywords: Self.keywordList(from: speechRecognitionVocabulary),
            languages: Self.languageHints(from: transcriptionLanguage),
            prompt: customContextPrompt.isEmpty ? nil : customContextPrompt
        )
    }
}
```

Mapping helpers:

- `keywordList(from:)` — split `speechRecognitionVocabulary`
  (`AppState.swift:376`) on commas and newlines, trim, drop empties. This is
  the same source the Apple path feeds into `AnalysisContext.contextualStrings`
  (`SpeechAnalyzerService.vocabularyContext`).
- `languageHints(from:)` — `transcriptionLanguage` is a BCP-47 code or the
  literal `"auto"`. Return `[]` for `"auto"` or empty (which omits the field);
  otherwise `[code]`.

The Dictionary's exact `wordCorrections` run **after** transcription and need
no changes — they already apply to both engines.

### 6.5 Error surfacing

Extend `formattedTranscriptionError(_:)` (`AppState.swift:2432`) with cases for
`OpenAITranscriptionError`. Its existing `URLError` classification is currently
unreachable dead code and becomes live again — leave it intact.

Messages must be **≤ 90 characters** — `RecordingOverlayManager.showError`
truncates beyond that (`RecordingOverlay.swift:192`).

| Condition | Message |
| --- | --- |
| `.missingAPIKey` | `No API key — add ~/.config/megaphone/openai-key` |
| `.unauthorized` | `OpenAI rejected the key — check ~/.config/megaphone/openai-key` |
| `.fileTooLarge` | `Recording too long for OpenAI (25 MB limit)` |
| `.rateLimited` | `OpenAI rate limited — record again shortly` |
| `.serverError` / retries exhausted | `OpenAI failed after 3 tries — record again` |
| offline (`URLError`) | existing `No internet — check connection` |

The failure path at `AppState.swift:3172` already calls
`overlayManager.showError(userFacingErrorMessage)`. No new UI needed.

## 7. Retry policy

`OpenAITranscriptionService.transcribe` wraps `transcribeOnce`:

- **3 attempts total** (1 initial + 2 retries).
- Exponential backoff: 1s, then 2s. Total added latency ceiling ~3s.
- Honour `Retry-After` on a `429` when present and ≤ 10s; if larger, fail
  immediately rather than stalling the user.
- Check `Task.checkCancellation()` before each attempt.

| Status | Retry | Reason |
| --- | --- | --- |
| 401 | **No** | key is wrong; retrying wastes time |
| 400 | **No** | malformed request — a bug |
| 413 | **No** | file exceeds 25 MB |
| 429 | Yes | rate limited |
| 5xx | Yes | transient server error |
| timeout / connection lost | Yes | transient |

On final failure: surface the toast and stop. **Do not** silently fall back to
Apple, and **do not** auto-retry with the saved WAV — the user records again.
(`saveAudioFile` does retain the WAV for pipeline history; that retention is
unchanged, it is simply not used for retry.)

## 8. Overlay engine indicator

Two channels. **Tint is unconditional; the glyph is opportunistic.**

### 8.1 Colors and symbols

| Engine | Tint | SF Symbol |
| --- | --- | --- |
| OpenAI | blue `Color(red: 0.30, green: 0.64, blue: 1.00)` | `cloud` |
| Apple | green `Color(red: 0.37, green: 0.81, blue: 0.56)` | `laptopcomputer` |

Red stays reserved for the stop button and failure X. Do not reuse it.

Add to `TranscriptionEngine` (in `TranscriptionEngine.swift`, importing
SwiftUI):

```swift
var overlayTint: Color
var overlaySymbolName: String
```

### 8.2 State plumbing

Add to `RecordingOverlayState` (`RecordingOverlay.swift:6`):

```swift
@Published var engine: TranscriptionEngine = .appleOnDevice
```

Set it from `AppState` using `activeSessionEngine` (section 6.3) — i.e. the
engine actually in use for this session, **not** the raw setting, so a
network-forced Apple fallback shows green, not blue.

`RecordingOverlayManager` needs the value threaded through
`showInitializing(...)`, `showRecording(...)`, `transitionToRecording(...)`
and `showTranscribing()`. Add an `engine:` parameter to each, defaulting to
`.appleOnDevice`.

### 8.3 Tint — replace hardcoded white

These lines hardcode white and must take the tint:

| Line | View |
| --- | --- |
| `RecordingOverlay.swift:581` | `WaveformBar` |
| `RecordingOverlay.swift:704` | `CompactWaveformBar` |
| `RecordingOverlay.swift:762` | `ProcessingPill` |
| `RecordingOverlay.swift:777` | `ProcessingIndicatorView` spinner stroke |
| `RecordingOverlay.swift:820` | `CompactProcessingIndicatorView` spinner stroke |
| `RecordingOverlay.swift:902` | `CompactProcessingPill` |
| `RecordingOverlay.swift:916` | `InitializingDotsView` dots |

Thread a `tint: Color` parameter down through `WaveformView`,
`CompactWaveformView`, `ProcessingWaveformView`,
`CompactProcessingWaveformView`, `ProcessingIndicatorView`,
`CompactProcessingIndicatorView` and `InitializingDotsView` to reach them.

**Leave white alone** at lines 516, 546, 554, 995, 1022, 1031, 1051, 1067,
1073 — those are the command-mode pencil, stop button, failure X, error text
and update overlay. They are not engine signals.

### 8.4 Glyph placement

The glyph renders **only when a slot is free**:

| State | Winged layout | Pill layout |
| --- | --- | --- |
| Recording, hold | glyph in right wing | glyph in leading slot |
| Recording, toggle | none — stop button owns the wing | glyph in leading slot |
| Recording, toggle + command mode | none | none — pencil + stop own both slots |
| Transcribing | glyph in right wing | glyph in leading slot |

Relevant existing logic:

- `WingedRecordingView.showsStopButton` = `phase == .recording && triggerMode == .toggle`
  (`RecordingOverlay.swift:481-493`). The right wing is therefore **empty
  during `.transcribing`** — that is the free slot.
- `RecordingOverlayView` has `leadingAccessoryWidth: CGFloat = 24`
  (`RecordingOverlay.swift:941`), currently holding `CommandModeIndicator`
  when `state.isCommandMode`.

Sizing: `font(.system(size: 11, weight: .semibold))` in the winged layout
(matching the command-mode pencil at line 515); `size: 12` in the pill.

### 8.5 Width lock

`setTranscribingPhase()` (`RecordingOverlay.swift:283`) locks
`lockedOverlayWidth` to the current panel width, deliberately, to stop the pill
jumping when recording ends.

The glyph must fit **inside the existing width**. Do not widen the overlay and
do not bypass the lock — it exists to prevent visible jitter.

## 9. Settings

`Sources/SettingsView.swift`. Add a `transcriptionEngineSection` and register
it in the General tab body (the section list is at `SettingsView.swift:435-483`).
Place it **above** `cleanupSection`, since engine choice precedes cleanup
choice.

Model it on `cleanupSection` (`SettingsView.swift:713`):

```swift
Picker("Engine", selection: $appState.transcriptionEngine) {
    ForEach(TranscriptionEngine.allCases) { engine in
        Text(engine.title).tag(engine)
    }
}
.pickerStyle(.segmented)
```

Below the picker, when `.openAI` is selected, show a caption stating the key is
read from `~/.config/megaphone/openai-key`, plus a live status line —
`Key found` / `No key file found` — derived from `OpenAIKeyStore.currentKey()`.
Include a small "Recheck" button calling `OpenAIKeyStore.reload()`.

Do **not** add a text field for the key.

## 10. Setup flow

`Sources/SetupView.swift`.

`canContinueFromCurrentStep` (`SetupView.swift:928`) gates only
`micPermission`, `accessibility` and `testTranscription`. The
`appleIntelligence` step already clicks straight through and relabels its
button to "Continue with Basic" — **no change needed there.**

The step that does need work is **`testTranscription`**, which currently
requires a successful transcription:

```swift
case .testTranscription:
    return testPhase == .done && !testTranscript.isEmpty && testError == nil
```

With OpenAI selected and no key file present, this hard-blocks setup. Add a
visible "Skip this step" button on that step that advances via
`nextStep(currentStep)` regardless of `testPhase`. Keep the existing
Continue-button gating as-is; the skip is an additional, clearly secondary
affordance.

## 11. Tests

Pure functions only — there is no `URLProtocol` injection in this codebase and
you should not add a networking abstraction just to test it.

Add `Tests/OpenAITranscriptionServiceTests.swift` covering:

1. `multipartBody` emits `keywords[]` once per term, and omits the field
   entirely for an empty array.
2. `multipartBody` emits `languages[]` and omits it for `"auto"`.
3. `parseTranscript` extracts `text` from a well-formed body.
4. `parseTranscript` throws `.malformedResponse` on garbage and
   `.emptyTranscript` on `{"text": "  "}`.
5. `classify` maps 401 → `.unauthorized`, 429 → `.rateLimited`,
   503 → `.serverError`, 200 → `nil`.
6. `isRetryable` is false for 401/400/413 and true for 429/5xx.

**Then update `Makefile:107` in both places** — the prerequisite list and the
`swiftc` argument list — adding
`Sources/OpenAITranscriptionService.swift Sources/TranscriptionEngine.swift Tests/OpenAITranscriptionServiceTests.swift`.
The test binary is built from an explicit file list, not a glob; missing either
occurrence breaks `make test`.

## 12. Acceptance criteria

1. `make` builds clean. `make test` passes.
2. With the engine set to Apple, behaviour is **identical to today** — the
   streaming session still starts, latency is unchanged, no network calls occur.
3. With the engine set to OpenAI and a valid key file: hold hotkey → speak →
   release → transcript is pasted at the cursor. No Apple speech model is
   downloaded or started.
4. Overlay is blue with a cloud glyph while OpenAI is in use, green with a
   laptop glyph while Apple is. Colours follow the *actual* session engine.
5. Overlay width does not change or jitter when the glyph appears.
6. With OpenAI selected and Wi-Fi off, pressing the hotkey immediately shows
   `No network — using Apple for this one`, the overlay is green, and dictation
   completes on-device.
7. With OpenAI selected and a deliberately invalid key, the failure toast names
   the key file and does **not** retry three times.
8. The cancel shortcut aborts an in-flight upload.
9. Setup can be completed end-to-end with no key file present.

## 13. Reference — recoverable prior art

The pre-existing cloud stack was deleted in commit `2fb6439`
("refactor: remove legacy cloud plumbing entirely"). Useful for reference:

```bash
git show 2fb6439^:Sources/LLMAPITransport.swift      # ephemeral URLSession pattern
git show 2fb6439^:Sources/LLMCooldownManager.swift   # Retry-After parsing
git show 2fb6439^:Sources/KeychainStorage.swift      # 0600 file-backed settings store
```

`LLMCooldownManager` is more machinery than this needs — reference it for
`Retry-After` parsing only, do not restore it wholesale.
