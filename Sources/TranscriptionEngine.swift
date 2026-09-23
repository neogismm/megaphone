import SwiftUI

/// Which transcription backend a dictation session uses.
///
/// Apple's on-device `SpeechAnalyzer` is the default and needs no
/// configuration. OpenAI is opt-in, uploads the finished recording, and
/// requires an API key on disk (see `OpenAIKeyStore`).
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

    /// Overlay accent. Blue means the audio leaves the machine; green means
    /// it does not. Red stays reserved for the stop button and failure X.
    var overlayTint: Color {
        switch self {
        case .appleOnDevice: return Color(red: 0.37, green: 0.81, blue: 0.56)
        case .openAI:        return Color(red: 0.30, green: 0.64, blue: 1.00)
        }
    }

    var overlaySymbolName: String {
        switch self {
        case .appleOnDevice: return "laptopcomputer"
        case .openAI:        return "cloud"
        }
    }
}
