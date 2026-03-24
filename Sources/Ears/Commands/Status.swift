import ArgumentParser
import Foundation

struct Status: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show current recording status."
    )

    mutating func run() throws {
        // Check for stale state
        if let staleState = StateManager.checkAndCleanStaleState() {
            print("Previous recording '\(staleState.title)' was interrupted. State cleaned up.")
            return
        }

        guard let state = StateManager.load() else {
            print("Not listening.")
            return
        }

        guard StateManager.isProcessAlive(pid: state.pid) else {
            StateManager.clear()
            print("Not listening. (Stale state cleaned up.)")
            return
        }

        let elapsed = Date().timeIntervalSince(state.startTime)
        let hours = Int(elapsed) / 3600
        let minutes = (Int(elapsed) % 3600) / 60
        let seconds = Int(elapsed) % 60
        let durationStr = String(format: "%02d:%02d:%02d", hours, minutes, seconds)

        print("Listening to \(state.app)")
        print("  Title:    \(state.title)")
        print("  Duration: \(durationStr)")
        print("  Output:   \(state.output.rawValue)")

        // Show file size if WAV exists
        let fm = FileManager.default
        if let attrs = try? fm.attributesOfItem(atPath: state.wavPath),
           let size = attrs[.size] as? UInt64 {
            print("  Size:     \(formatBytes(size))")
        }

        if let dur = state.duration {
            print("  Auto-stop: \(dur)")
        }

        print("  PID:      \(state.pid)")
    }

    private func formatBytes(_ bytes: UInt64) -> String {
        let units = ["B", "KB", "MB", "GB"]
        var value = Double(bytes)
        var unitIndex = 0
        while value >= 1024 && unitIndex < units.count - 1 {
            value /= 1024
            unitIndex += 1
        }
        if unitIndex == 0 {
            return "\(bytes) B"
        }
        return String(format: "%.1f %@", value, units[unitIndex])
    }
}
