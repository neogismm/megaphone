import Foundation

/// Resolves the OpenAI API key from disk. Deliberately has no UI: the key is
/// a file the user places themselves, so it never passes through the app's
/// settings, UserDefaults, or any window.
///
/// Resolution order:
///   1. `OPENAI_API_KEY` in the environment — a convenience for
///      `make run` / terminal launches only.
///   2. `~/.config/megaphone/openai-key`.
///
/// The env var is *not* the primary path: the app is `LSUIElement` and
/// registers with `SMAppService.mainApp`, so at login it inherits launchd's
/// environment rather than the user's shell. The file is what actually works
/// for a normal launch.
enum OpenAIKeyStore {
    static let keyFilePath = "~/.config/megaphone/openai-key"

    private static let lock = NSLock()
    private static var cached: String??

    /// The current key, or nil when neither source yields a non-empty value.
    /// Cached in memory; call `reload()` to re-read.
    static func currentKey() -> String? {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }
        let resolved = resolveKey()
        cached = .some(resolved)
        return resolved
    }

    /// Drop the cache so the next `currentKey()` re-reads the file. Called on
    /// a 401 so the user can fix the file without restarting the app, and by
    /// the Settings "Recheck" button.
    static func reload() {
        lock.lock()
        cached = nil
        lock.unlock()
    }

    private static func resolveKey() -> String? {
        if let env = ProcessInfo.processInfo.environment["OPENAI_API_KEY"] {
            let trimmed = env.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }

        let url = URL(fileURLWithPath: (keyFilePath as NSString).expandingTildeInPath)
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let trimmed = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
