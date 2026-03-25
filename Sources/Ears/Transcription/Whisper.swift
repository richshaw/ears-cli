import Foundation

enum WhisperTranscriber {
    /// Transcribe a WAV file using whisper-cpp and output a markdown transcript.
    static func transcribe(wavPath: String, title: String, duration: TimeInterval) throws {
        let whisperBinary = try findWhisperBinary()
        let modelPath = EarsPaths.modelFile.path
        let metalResources = findMetalResources()

        // Check if we need to chunk (files > 1 hour)
        if duration > 3600 {
            try transcribeChunked(
                wavPath: wavPath, title: title, duration: duration,
                whisperBinary: whisperBinary, modelPath: modelPath, metalResources: metalResources
            )
        } else {
            let srtContent = try runWhisper(
                wavPath: wavPath, whisperBinary: whisperBinary,
                modelPath: modelPath, metalResources: metalResources
            )
            let markdown = Formatter.srtToMarkdown(srt: srtContent, title: title, duration: duration)
            let outputURL = EarsPaths.transcriptFile(for: title)
            try markdown.write(to: outputURL, atomically: true, encoding: .utf8)
        }
    }

    /// Run whisper-cpp on a single file and return the SRT content.
    private static func runWhisper(
        wavPath: String, whisperBinary: String,
        modelPath: String, metalResources: String?
    ) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: whisperBinary)
        process.arguments = [
            "--model", modelPath,
            "--file", wavPath,
            "--output-srt",
            "--no-prints",
        ]

        // Set Metal resources path for GPU acceleration
        var env = ProcessInfo.processInfo.environment
        if let metalPath = metalResources {
            env["GGML_METAL_PATH_RESOURCES"] = metalPath
        }
        process.environment = env

        let stderrPipe = Pipe()
        process.standardError = stderrPipe

        // Forward stderr to show progress
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty {
                FileHandle.standardError.write(data)
            }
        }

        try process.run()
        process.waitUntilExit()

        stderrPipe.fileHandleForReading.readabilityHandler = nil

        guard process.terminationStatus == 0 else {
            throw EarsError.whisperFailed("whisper-cpp exited with status \(process.terminationStatus)")
        }

        // Read the SRT file (whisper-cpp writes it next to the input file)
        let srtPath = wavPath + ".srt"
        guard FileManager.default.fileExists(atPath: srtPath) else {
            throw EarsError.whisperFailed("SRT output file not found at \(srtPath)")
        }

        let srtContent = try String(contentsOfFile: srtPath, encoding: .utf8)

        // Clean up the intermediate SRT file
        try? FileManager.default.removeItem(atPath: srtPath)

        return srtContent
    }

    /// Transcribe a long file by splitting into 1-hour chunks.
    private static func transcribeChunked(
        wavPath: String, title: String, duration: TimeInterval,
        whisperBinary: String, modelPath: String, metalResources: String?
    ) throws {
        let chunkDuration: TimeInterval = 3600 // 1 hour
        let numChunks = Int(ceil(duration / chunkDuration))

        print("Long recording (\(formatHours(duration))). Splitting into \(numChunks) chunks...")

        var allSrtContent = ""

        for i in 0..<numChunks {
            let startTime = TimeInterval(i) * chunkDuration
            let chunkLength = min(chunkDuration, duration - startTime)

            print("Transcribing chunk \(i + 1)/\(numChunks)...")

            // Use ffmpeg to extract chunk (if available), otherwise transcribe with offset
            // For simplicity, we pass the whole file with time offset to whisper-cpp
            let chunkSrt = try runWhisperWithOffset(
                wavPath: wavPath, whisperBinary: whisperBinary,
                modelPath: modelPath, metalResources: metalResources,
                offsetMs: Int(startTime * 1000), durationMs: Int(chunkLength * 1000)
            )

            // Adjust timestamps in SRT by adding the chunk's start offset
            let adjustedSrt = Formatter.adjustSrtTimestamps(srt: chunkSrt, offsetSeconds: startTime)
            allSrtContent += adjustedSrt + "\n"
        }

        let markdown = Formatter.srtToMarkdown(srt: allSrtContent, title: title, duration: duration)
        let outputURL = EarsPaths.transcriptFile(for: title)
        try markdown.write(to: outputURL, atomically: true, encoding: .utf8)
    }

    /// Run whisper-cpp with time offset and duration.
    private static func runWhisperWithOffset(
        wavPath: String, whisperBinary: String,
        modelPath: String, metalResources: String?,
        offsetMs: Int, durationMs: Int
    ) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: whisperBinary)
        process.arguments = [
            "--model", modelPath,
            "--file", wavPath,
            "--output-srt",
            "--no-prints",
            "--offset-t", String(offsetMs),
            "--duration", String(durationMs),
        ]

        var env = ProcessInfo.processInfo.environment
        if let metalPath = metalResources {
            env["GGML_METAL_PATH_RESOURCES"] = metalPath
        }
        process.environment = env

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw EarsError.whisperFailed("whisper-cpp exited with status \(process.terminationStatus)")
        }

        let srtPath = wavPath + ".srt"
        guard FileManager.default.fileExists(atPath: srtPath) else {
            throw EarsError.whisperFailed("SRT output file not found")
        }

        let srtContent = try String(contentsOfFile: srtPath, encoding: .utf8)
        try? FileManager.default.removeItem(atPath: srtPath)
        return srtContent
    }

    // MARK: - Helpers

    /// Find the whisper-cpp binary.
    static func findWhisperBinary() throws -> String {
        // Try common names
        // Search for known whisper-cpp binary names. "main" is intentionally excluded
        // as it's too generic and could match unrelated binaries.
        for name in ["whisper-cpp", "whisper-cli", "whisper"] {
            if let path = which(name) {
                return path
            }
        }
        throw EarsError.missingDependency("whisper-cpp")
    }

    /// Find the Metal resources path for GPU acceleration.
    private static func findMetalResources() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "brew --prefix whisper-cpp 2>/dev/null"]

        let pipe = Pipe()
        process.standardOutput = pipe

        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let prefix = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !prefix.isEmpty {
                return prefix + "/share/whisper-cpp"
            }
        } catch {}

        return nil
    }

    /// Check if a command exists in PATH.
    static func which(_ command: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = [command]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe() // suppress errors

        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        } catch {}
        return nil
    }

    private static func formatHours(_ seconds: TimeInterval) -> String {
        let hours = Int(seconds) / 3600
        let mins = (Int(seconds) % 3600) / 60
        if hours > 0 {
            return "\(hours)h\(mins > 0 ? "\(mins)m" : "")"
        }
        return "\(mins)m"
    }
}
