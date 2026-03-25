import ArgumentParser
import Foundation

struct Listen: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Start listening to an app's audio."
    )

    @Option(name: .long, help: "Name for the recording/transcript.")
    var title: String

    @Option(name: .long, help: "App display name to capture audio from.")
    var app: String

    @Option(name: .long, help: "Auto-stop after duration (e.g. \"10h\", \"1h30m\", \"45m\", \"90s\").")
    var duration: String?

    @Option(name: .long, help: "What to keep: md (default), audio, or both.")
    var output: String = "md"

    @Flag(name: .long, help: "Mute the app's audio output while recording.")
    var mute: Bool = false

    mutating func run() throws {
        try EarsPaths.requireSetup()
        try EarsPaths.ensureDirectories()

        // Parse output format
        guard let outputFormat = RecordingState.OutputFormat(rawValue: output) else {
            throw ValidationError("Invalid output format '\(output)'. Use: md, audio, or both.")
        }

        // Parse duration if provided
        var durationSeconds: TimeInterval?
        if let durationStr = duration {
            guard let seconds = DurationParser.parse(durationStr) else {
                throw ValidationError("Invalid duration '\(durationStr)'. Use format like: 10h, 1h30m, 45m, 90s")
            }
            durationSeconds = seconds
        }

        // Check for stale state
        if let staleState = StateManager.checkAndCleanStaleState() {
            print("Previous recording '\(staleState.title)' was interrupted. State cleaned up.")
        }

        // Check if already listening
        if let existingState = StateManager.load() {
            if StateManager.isProcessAlive(pid: existingState.pid) {
                throw EarsError.alreadyListening
            } else {
                StateManager.clear()
            }
        }

        // Check title collision
        let wavURL = EarsPaths.recordingFile(for: title)
        if FileManager.default.fileExists(atPath: wavURL.path) {
            throw EarsError.titleExists(title)
        }

        // Find app PID
        guard let appPid = ProcessLookup.findPID(appName: app) else {
            throw EarsError.appNotRunning(app)
        }

        // Wait for audio readiness
        print("Waiting for audio from \(app)... (press play in the app)")

        #if canImport(CoreAudio)
        guard #available(macOS 14.2, *) else {
            throw EarsError.unsupportedOS
        }
        guard let audioPid = ProcessTap.waitForAudio(pid: appPid) else {
            throw EarsError.audioTimeout(app)
        }
        if audioPid != appPid {
            print("Audio found on helper process (PID \(audioPid)).")
        }
        #else
        let audioPid = appPid
        #endif

        print("Audio detected. Recording started.")

        // Create WAV writer
        let writer = try WAVWriter(url: wavURL)

        // Create and start process tap using the audio-producing PID
        let tap = ProcessTap(pid: audioPid, wavWriter: writer, mute: mute)

        tap.onSilenceWarning = {
            print("")
            print("Only silence detected. Check System Settings > Privacy > Screen Recording")
            print("  and make sure your terminal app has permission.")
        }

        do {
            try tap.start()
        } catch {
            writer.close()
            try? FileManager.default.removeItem(at: wavURL)
            throw error
        }

        // Spawn caffeinate
        let caffeinateProcess = Listen.spawnCaffeinate()

        // Write state
        let state = RecordingState(
            pid: ProcessInfo.processInfo.processIdentifier,
            caffeinatePid: caffeinateProcess?.processIdentifier ?? 0,
            title: title,
            app: app,
            appPid: appPid,
            startTime: Date(),
            wavPath: wavURL.path,
            output: outputFormat,
            duration: duration
        )
        try StateManager.save(state)

        if mute {
            print("Listening to \(app) (muted). Run `ears stop` when done.")
        } else {
            print("Listening to \(app). Run `ears stop` when done.")
        }

        // Capture values for closures (Listen is a struct — closures capture a copy of self)
        let durationLabel = duration
        let appName = app

        // Set up duration timer if requested.
        // Multiple sources (duration timer, SIGINT, SIGTERM, app quit) may call CFRunLoopStop
        // concurrently. This is safe — CFRunLoopStop is idempotent and the shutdown sequence
        // runs on the main thread after the run loop exits.
        if let seconds = durationSeconds {
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
                print("\nDuration reached (\(durationLabel!)). Stopping...")
                CFRunLoopStop(CFRunLoopGetMain())
            }
        }

        // Set up SIGINT handler
        let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        signal(SIGINT, SIG_IGN) // Ignore default handler
        sigintSource.setEventHandler {
            print("\nStopping...")
            CFRunLoopStop(CFRunLoopGetMain())
        }
        sigintSource.resume()

        // Set up SIGTERM handler
        let sigtermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        signal(SIGTERM, SIG_IGN)
        sigtermSource.setEventHandler {
            print("\nStopping...")
            CFRunLoopStop(CFRunLoopGetMain())
        }
        sigtermSource.resume()

        // Set up app quit detection timer
        let appCheckTimer = DispatchSource.makeTimerSource(queue: .global())
        appCheckTimer.schedule(deadline: .now() + 5, repeating: 5)
        appCheckTimer.setEventHandler {
            if !StateManager.isProcessAlive(pid: appPid) {
                print("\n\(appName) quit. Finalizing recording...")
                CFRunLoopStop(CFRunLoopGetMain())
            }
        }
        appCheckTimer.resume()

        // Run until stopped
        CFRunLoopRun()

        // --- Shutdown sequence ---
        appCheckTimer.cancel()
        sigintSource.cancel()
        sigtermSource.cancel()

        // Stop audio capture
        tap.stop()

        // Kill caffeinate
        caffeinateProcess?.terminate()

        let recordingDuration = Date().timeIntervalSince(state.startTime)
        print("Recording complete. Duration: \(Listen.formatDuration(recordingDuration))")

        // Handle output
        Listen.handleOutput(
            format: outputFormat,
            wavURL: wavURL,
            title: title,
            duration: recordingDuration
        )

        // Clear state
        StateManager.clear()
    }

    // MARK: - Helpers

    /// Transcribe and/or clean up based on the output format preference.
    private static func handleOutput(
        format: RecordingState.OutputFormat,
        wavURL: URL,
        title: String,
        duration: TimeInterval
    ) {
        switch format {
        case .audio:
            print("Audio saved to: \(wavURL.path)")

        case .md, .both:
            let keepAudio = (format == .both)
            print("Transcribing...")
            do {
                try WhisperTranscriber.transcribe(
                    wavPath: wavURL.path,
                    title: title,
                    duration: duration
                )
                if keepAudio {
                    print("Audio saved to: \(wavURL.path)")
                } else {
                    try? FileManager.default.removeItem(at: wavURL)
                }
                print("Transcript saved to: \(EarsPaths.transcriptFile(for: title).path)")
            } catch {
                print("Transcription failed: \(error)")
                print("Audio saved at: \(wavURL.path)")
            }
        }
    }

    private static func spawnCaffeinate() -> Process? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        process.arguments = ["-i", "-w", String(ProcessInfo.processInfo.processIdentifier)]

        do {
            try process.run()
            return process
        } catch {
            print("Warning: could not start caffeinate (Mac may sleep during recording)")
            return nil
        }
    }

    static func formatDuration(_ seconds: TimeInterval) -> String {
        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60
        let secs = Int(seconds) % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, secs)
    }
}
