import ArgumentParser
import Foundation

struct Stop: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Stop listening and transcribe."
    )

    mutating func run() throws {
        // Check for stale state first
        if let staleState = StateManager.checkAndCleanStaleState() {
            print("Previous recording '\(staleState.title)' was interrupted. State cleaned up.")
            if FileManager.default.fileExists(atPath: staleState.wavPath) {
                print("Audio file still exists at: \(staleState.wavPath)")
            }
            return
        }

        guard let state = StateManager.load() else {
            throw EarsError.notListening
        }

        guard StateManager.isProcessAlive(pid: state.pid) else {
            StateManager.clear()
            print("Recording process is not running. State cleaned up.")
            if FileManager.default.fileExists(atPath: state.wavPath) {
                print("Audio file still exists at: \(state.wavPath)")
            }
            return
        }

        // Send SIGINT to the listen process
        kill(state.pid, SIGINT)
        print("Stop signal sent to ears (PID \(state.pid)).")
        print("The recording terminal will handle transcription.")
    }
}
