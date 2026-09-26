import SwiftUI

/// Which transcription backend a dictation session uses.
///
/// Apple's on-device `SpeechAnalyzer` is the default and needs no
/// configuration. OpenAI and Gemini are opt-in, upload the finished
/// recording, and require an API key on disk (see `APIKeyStore`).
enum TranscriptionEngine: String, CaseIterable, Identifiable {
    case appleOnDevice = "apple"
    case openAI = "openai"
    case gemini = "gemini"

    var id: String { rawValue }

    /// Settings picker label.
    var title: String {
        switch self {
        case .appleOnDevice: return "Apple (on-device)"
        case .openAI:        return "OpenAI"
        case .gemini:        return "Gemini"
        }
    }

    /// Short name for toasts and captions.
    var providerName: String {
        switch self {
        case .appleOnDevice: return "Apple"
        case .openAI:        return "OpenAI"
        case .gemini:        return "Gemini"
        }
    }

    var isCloud: Bool { self != .appleOnDevice }

    /// Overlay accent. Blue means the audio leaves the machine; green means
    /// it does not. Red stays reserved for the stop button and failure X.
    /// The provider is told apart by `TranscriptionEngineMark`, not colour.
    var overlayTint: Color {
        switch self {
        case .appleOnDevice:   return Color(red: 0.37, green: 0.81, blue: 0.56)
        case .openAI, .gemini: return Color(red: 0.30, green: 0.64, blue: 1.00)
        }
    }

    // MARK: API key location

    /// Environment variables checked, in order, before the key file. A
    /// convenience for `make run` / terminal launches only — see `APIKeyStore`.
    var apiKeyEnvironmentVariables: [String] {
        switch self {
        case .appleOnDevice: return []
        case .openAI:        return ["OPENAI_API_KEY"]
        case .gemini:        return ["GEMINI_API_KEY"]
        }
    }

    /// Where the key file lives, tilde-abbreviated for display. Nil for
    /// engines that need no key.
    var apiKeyFilePath: String? {
        switch self {
        case .appleOnDevice: return nil
        case .openAI:        return "~/.config/megaphone/openai-key"
        case .gemini:        return "~/.config/megaphone/gemini-key"
        }
    }
}
