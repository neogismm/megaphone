import Foundation

/// Resolves cloud transcription API keys from disk. Deliberately has no UI:
/// each key is a file the user places themselves, so it never passes through
/// the app's settings, UserDefaults, or any window.
///
/// Resolution order, per engine (see `TranscriptionEngine`):
///   1. The engine's environment variable (`OPENAI_API_KEY`,
///      `GEMINI_API_KEY`) — a convenience for `make run` / terminal launches.
///   2. The engine's key file under `~/.config/megaphone/`.
///
/// The env var is *not* the primary path: the app is `LSUIElement` and
/// registers with `SMAppService.mainApp`, so at login it inherits launchd's
/// environment rather than the user's shell. The file is what actually works
/// for a normal launch.
enum APIKeyStore {
    private static let lock = NSLock()
    private static var cache: [TranscriptionEngine: String?] = [:]

    /// The engine's current key, or nil when no source yields a non-empty
    /// value (always nil for engines that need no key). Cached in memory;
    /// call `reload(_:)` to re-read.
    static func currentKey(for engine: TranscriptionEngine) -> String? {
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[engine] { return cached }
        let resolved = resolveKey(for: engine)
        cache[engine] = .some(resolved)
        return resolved
    }

    /// Drop the cached key so the next `currentKey(for:)` re-reads it. Called
    /// on an auth failure so the user can fix the file without restarting the
    /// app, and by the Settings "Recheck" button.
    static func reload(_ engine: TranscriptionEngine) {
        lock.lock()
        cache[engine] = nil
        lock.unlock()
    }

    private static func resolveKey(for engine: TranscriptionEngine) -> String? {
        let environment = ProcessInfo.processInfo.environment
        for name in engine.apiKeyEnvironmentVariables {
            let trimmed = environment[name]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty { return trimmed }
        }

        guard let path = engine.apiKeyFilePath else { return nil }
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let trimmed = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
