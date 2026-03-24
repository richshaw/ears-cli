import Foundation

enum EarsPaths {
    static let baseDir: URL = {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ears")
    }()

    static let stateFile = baseDir.appendingPathComponent("state.json")
    static let recordingsDir = baseDir.appendingPathComponent("recordings")
    static let transcriptsDir = baseDir.appendingPathComponent("transcripts")
    static let modelsDir = baseDir.appendingPathComponent("models")
    static let modelFile = modelsDir.appendingPathComponent("ggml-medium.bin")

    static func recordingFile(for title: String) -> URL {
        recordingsDir.appendingPathComponent("\(sanitizeTitle(title)).wav")
    }

    static func transcriptFile(for title: String) -> URL {
        transcriptsDir.appendingPathComponent("\(sanitizeTitle(title)).md")
    }

    /// Sanitize a title for use as a filename.
    /// Strips path separators, lowercases, replaces spaces with hyphens.
    static func sanitizeTitle(_ title: String) -> String {
        let cleaned = title
            .lowercased()
            .replacingOccurrences(of: "..", with: "")
            .replacingOccurrences(of: "/", with: "")
            .replacingOccurrences(of: "\\", with: "")

        // Replace spaces and consecutive non-alphanumeric chars with hyphens
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let result = cleaned.unicodeScalars.map { scalar in
            allowed.contains(scalar) ? String(scalar) : "-"
        }.joined()

        // Collapse multiple hyphens
        let collapsed = result.replacingOccurrences(
            of: "-+", with: "-",
            options: .regularExpression
        )
        let trimmed = collapsed.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        guard !trimmed.isEmpty else { return "untitled" }
        return trimmed
    }

    /// Create all required directories.
    static func ensureDirectories() throws {
        let fm = FileManager.default
        for dir in [baseDir, recordingsDir, transcriptsDir, modelsDir] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    /// Check if setup has been completed (model file exists).
    static var isSetupComplete: Bool {
        FileManager.default.fileExists(atPath: modelFile.path)
    }

    /// Guard that requires setup to have been run.
    static func requireSetup() throws {
        guard isSetupComplete else {
            throw EarsError.setupRequired
        }
    }
}

enum EarsError: Error, CustomStringConvertible {
    case setupRequired
    case alreadyListening
    case notListening
    case appNotRunning(String)
    case titleExists(String)
    case audioTimeout(String)
    case staleState
    case whisperFailed(String)
    case missingDependency(String)

    var description: String {
        switch self {
        case .setupRequired:
            return "ears is not set up. Run `ears setup` first."
        case .alreadyListening:
            return "Already listening. Run `ears stop` first."
        case .notListening:
            return "Not listening. Nothing to stop."
        case .appNotRunning(let app):
            return "App '\(app)' is not running. Open it first."
        case .titleExists(let title):
            return "Recording '\(title)' already exists. Delete it or choose a different title."
        case .audioTimeout(let app):
            return "No audio detected from '\(app)' after 60 seconds. Is it playing?"
        case .staleState:
            return "Previous recording was interrupted. State has been cleaned up."
        case .whisperFailed(let msg):
            return "Transcription failed: \(msg)"
        case .missingDependency(let dep):
            return "\(dep) is not installed."
        }
    }
}
