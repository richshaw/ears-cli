import ArgumentParser
import Foundation

struct Setup: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Install dependencies and download the Whisper model."
    )

    mutating func run() throws {
        print("ears setup\n")

        // 1. Check macOS version
        let osVersion = ProcessInfo.processInfo.operatingSystemVersion
        if osVersion.majorVersion < 14 || (osVersion.majorVersion == 14 && osVersion.minorVersion < 4) {
            print("✗ macOS 14.4 or later is required (you have \(osVersion.majorVersion).\(osVersion.minorVersion))")
            print("  ears uses Core Audio process taps which require macOS 14.4+")
            throw ExitCode.failure
        }
        print("✓ macOS \(osVersion.majorVersion).\(osVersion.minorVersion)")

        // 2. Check for Homebrew
        guard WhisperTranscriber.which("brew") != nil else {
            print("✗ Homebrew not found")
            print("  Install from https://brew.sh then re-run `ears setup`")
            throw ExitCode.failure
        }
        print("✓ Homebrew")

        // 3. Check for whisper-cpp
        if let whisperPath = try? WhisperTranscriber.findWhisperBinary() {
            print("✓ whisper-cpp (\(whisperPath))")
        } else {
            print("✗ whisper-cpp not found")
            print("  Install? (brew install whisper-cpp) [Y/n] ", terminator: "")

            let response = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "y"
            if response == "y" || response == "" {
                print("Installing whisper-cpp...")
                let success = runCommand("/opt/homebrew/bin/brew", arguments: ["install", "whisper-cpp"])
                if !success {
                    print("  Failed to install whisper-cpp. Try manually: brew install whisper-cpp")
                    throw ExitCode.failure
                }
                print("✓ whisper-cpp installed")
            } else {
                print("  Skipped. You'll need whisper-cpp for transcription.")
            }
        }

        // 4. Create directories
        try EarsPaths.ensureDirectories()
        print("✓ ~/.ears/ directory structure")

        // 5. Download Whisper model
        if FileManager.default.fileExists(atPath: EarsPaths.modelFile.path) {
            let attrs = try? FileManager.default.attributesOfItem(atPath: EarsPaths.modelFile.path)
            let size = (attrs?[.size] as? UInt64) ?? 0
            print("✓ Whisper model (\(formatBytes(size)))")
        } else {
            print("Downloading Whisper medium model (~1.5GB)...")
            let success = downloadModel()
            if success {
                print("✓ Whisper model downloaded")
            } else {
                print("✗ Failed to download model")
                print("  You can download manually:")
                print("  curl -L https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-medium.bin")
                print("    -o ~/.ears/models/ggml-medium.bin")
            }
        }

        print("")
        print("✓ Setup complete!")
        print("")
        print("Note: The first recording will request Screen Recording permission.")
        print("  Make sure to allow it in System Settings > Privacy > Screen Recording.")
        print("")
        print("Usage: ears listen --title \"My Book\" --app Libby")
    }

    // MARK: - Helpers

    /// Run a command directly (no shell interpretation) to avoid command injection risks.
    private func runCommand(_ executable: String, arguments: [String]) -> Bool {
        // Find brew in common locations
        let brewPaths = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
        let resolvedPath = executable.hasSuffix("brew")
            ? (brewPaths.first { FileManager.default.fileExists(atPath: $0) } ?? executable)
            : executable

        let process = Process()
        process.executableURL = URL(fileURLWithPath: resolvedPath)
        process.arguments = arguments

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private func downloadModel() -> Bool {
        let url = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-medium.bin"
        let outputPath = EarsPaths.modelFile.path

        // Use curl for download with progress
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        process.arguments = [
            "-L",              // Follow redirects
            "--progress-bar",  // Show progress
            "-o", outputPath,
            url,
        ]

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
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
