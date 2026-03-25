import Foundation

/// Represents the current recording state, persisted to ~/.ears/state.json.
struct RecordingState: Codable {
    let pid: Int32
    let caffeinatePid: Int32
    let title: String
    let app: String
    let appPid: Int32
    let startTime: Date
    let wavPath: String
    let output: OutputFormat
    let duration: String?

    enum OutputFormat: String, Codable {
        case md
        case audio
        case both
    }
}

enum StateManager {
    /// Read current recording state. Returns nil if no state file exists.
    static func load() -> RecordingState? {
        let url = EarsPaths.stateFile
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        guard let data = try? Data(contentsOf: url) else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(RecordingState.self, from: data)
    }

    /// Write recording state to disk.
    static func save(_ state: RecordingState) throws {
        try EarsPaths.ensureDirectories()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(state)
        try data.write(to: EarsPaths.stateFile, options: .atomic)
    }

    /// Clear recording state.
    static func clear() {
        try? FileManager.default.removeItem(at: EarsPaths.stateFile)
    }

    /// Check if the PID in state is still alive.
    static func isProcessAlive(pid: Int32) -> Bool {
        // kill with signal 0 checks if process exists without sending a signal
        kill(pid, 0) == 0
    }

    /// Check for stale state (state exists but process is dead).
    /// Returns the stale state if found, nil otherwise.
    static func checkAndCleanStaleState() -> RecordingState? {
        guard let state = load() else { return nil }
        if !isProcessAlive(pid: state.pid) {
            clear()
            return state
        }
        return nil
    }
}
