#if canImport(CoreAudio) && canImport(AudioToolbox) && canImport(AVFoundation)

import CoreAudio
import AudioToolbox
import AVFoundation
import Foundation

/// Captures audio from a specific process using macOS 14.4+ Core Audio process taps.
/// Reference: AudioCap (github.com/insidegui/AudioCap), audiotee (github.com/makeusabrew/audiotee)
@available(macOS 14.2, *)
final class ProcessTap {
    private var tapID: AudioObjectID = kAudioObjectUnknown
    private var aggregateDeviceID: AudioObjectID = kAudioObjectUnknown
    private var ioProcID: AudioDeviceIOProcID?
    private let wavWriter: WAVWriter
    private let writeQueue = DispatchQueue(label: "com.ears.audio-write", qos: .userInitiated)
    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?

    /// Thread-safe stopped flag. Checked on the IO callback thread and set from the caller's thread.
    private let _stopped = LockedValue(false)
    private var stopped: Bool {
        get { _stopped.value }
        set { _stopped.value = newValue }
    }

    /// Total bytes of audio written. Only access via `readBytesWritten()` from outside `writeQueue`.
    private var _bytesWritten: UInt64 = 0
    func readBytesWritten() -> UInt64 { writeQueue.sync { _bytesWritten } }

    /// Enqueue converted mic samples for mixing with the next tap audio buffer.
    /// Called from MicCapture's convert queue; dispatches to writeQueue for thread safety.
    func enqueueMicSamples(_ data: Data) {
        writeQueue.async { [weak self] in
            guard let self = self else { return }
            self.micBuffer.append(data)
            // Enforce maximum buffer size: discard oldest data if exceeded
            if self.micBuffer.count > self.micBufferMaxSize {
                let excessBytes = self.micBuffer.count - self.micBufferMaxSize
                self.micBuffer.removeFirst(excessBytes)
            }
        }
    }

    /// Number of zero-only buffers received (for permission detection). Only accessed on writeQueue.
    private var consecutiveSilentBuffers = 0
    private let silenceWarningThreshold = 20 // ~20 callbacks ≈ few seconds

    /// Called on `writeQueue` (background thread) when sustained silence is detected.
    var onSilenceWarning: (() -> Void)?

    /// Accumulated mic samples (16kHz mono int16 PCM) waiting to be mixed. Only accessed on writeQueue.
    private var micBuffer = Data()
    /// Maximum size for micBuffer: 5 seconds at 16kHz mono int16 = 16000 * 2 bytes/sample * 5 seconds = 160000 bytes.
    /// Prevents unbounded growth if the tap callback stalls or fires infrequently.
    private let micBufferMaxSize = 160000

    /// Timer that periodically flushes pending mic samples when app audio is idle.
    /// Prevents mic audio from being silently dropped during gaps in app audio.
    /// Only accessed from the caller thread (start/stop).
    private var micFlushTimer: DispatchSourceTimer?

    /// Tracks whether app audio arrived since the last mic flush check. Only accessed on writeQueue.
    private var appAudioReceivedSinceLastFlush = false

    private let appPid: pid_t
    private let mute: Bool

    init(pid: pid_t, wavWriter: WAVWriter, mute: Bool = false) {
        self.appPid = pid
        self.wavWriter = wavWriter
        self.mute = mute
    }

    // No deinit cleanup — callers must call stop() to tear down Core Audio resources.
    // Having both deinit and stop() call cleanup() creates a race if they run on different threads.

    // MARK: - Public

    /// Start capturing audio from the target process.
    func start() throws {
        let processObjectID = try translatePID(appPid)
        try createTap(processObjectID: processObjectID)
        try createAggregateDevice()
        try waitForDeviceReady()
        let format = try negotiateFormat()
        self.sourceFormat = format
        try setupConverter(sourceFormat: format)
        try startIOProc()
    }

    /// Stop capturing and finalize.
    func stop() {
        guard !stopped else { return }
        stopped = true

        // Cancel the mic flush timer before draining the queue
        micFlushTimer?.cancel()
        micFlushTimer = nil

        if let ioProcID = ioProcID {
            AudioDeviceStop(aggregateDeviceID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateDeviceID, ioProcID)
            self.ioProcID = nil
        }

        // Drain the write queue and flush any remaining mic samples before finalizing
        writeQueue.sync {
            if !self.micBuffer.isEmpty {
                let remaining = self.micBuffer
                self.micBuffer = Data()
                self.wavWriter.write(remaining)
                self._bytesWritten += UInt64(remaining.count)
            }
        }
        try? wavWriter.finalize()

        cleanup()
    }

    // MARK: - PID Translation

    /// Translate a process PID to a Core Audio AudioObjectID.
    /// The process must be actively producing audio for this to succeed.
    private func translatePID(_ pid: pid_t) throws -> AudioObjectID {
        var objectID = AudioObjectID(kAudioObjectUnknown)
        var pid = pid
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            UInt32(MemoryLayout<pid_t>.size),
            &pid,
            &size,
            &objectID
        )

        guard status == noErr, objectID != kAudioObjectUnknown else {
            throw ProcessTapError.pidTranslationFailed(pid)
        }
        return objectID
    }

    // MARK: - Tap Creation

    private func createTap(processObjectID: AudioObjectID) throws {
        let tapDescription = CATapDescription(stereoMixdownOfProcesses: [processObjectID])
        tapDescription.uuid = UUID()
        tapDescription.isPrivate = true
        tapDescription.muteBehavior = mute ? .muted : .unmuted

        var tapID = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateProcessTap(tapDescription, &tapID)

        guard status == noErr, tapID != kAudioObjectUnknown else {
            throw ProcessTapError.tapCreationFailed(status)
        }
        self.tapID = tapID
    }

    // MARK: - Aggregate Device

    private func createAggregateDevice() throws {
        // Get tap UID
        let tapUID = try getStringProperty(
            objectID: tapID,
            selector: kAudioTapPropertyUID
        )

        let description: [String: Any] = [
            kAudioAggregateDeviceUIDKey as String: UUID().uuidString,
            kAudioAggregateDeviceNameKey as String: "ears-capture",
            kAudioAggregateDeviceIsPrivateKey as String: true,
            kAudioAggregateDeviceIsStackedKey as String: false,
            kAudioAggregateDeviceTapListKey as String: [
                [kAudioSubTapUIDKey as String: tapUID]
            ],
        ]

        var aggregateID = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregateID)

        guard status == noErr, aggregateID != kAudioObjectUnknown else {
            throw ProcessTapError.aggregateDeviceCreationFailed(status)
        }
        self.aggregateDeviceID = aggregateID
    }

    // MARK: - Device Readiness

    /// Poll until the aggregate device is ready (up to 2 seconds).
    /// Blocks the calling thread (main thread) — acceptable since this runs during startup,
    /// before the run loop starts. Core Audio taps need stabilization time.
    private func waitForDeviceReady() throws {
        let timeout = Date().addingTimeInterval(2.0)
        while Date() < timeout {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreamConfiguration,
                mScope: kAudioObjectPropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )
            var size: UInt32 = 0
            let status = AudioObjectGetPropertyDataSize(aggregateDeviceID, &address, 0, nil, &size)
            if status == noErr && size > 0 {
                return
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw ProcessTapError.deviceNotReady
    }

    // MARK: - Format Negotiation

    /// Get the audio format from the tap object directly.
    /// AudioCap reads kAudioTapPropertyFormat from the tap rather than querying the aggregate device.
    private func negotiateFormat() throws -> AVAudioFormat {
        var formatAddress = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(
            tapID,
            &formatAddress,
            0, nil,
            &size,
            &asbd
        )

        if status == noErr, asbd.mSampleRate > 0 {
            if let format = AVAudioFormat(streamDescription: &asbd) {
                return format
            }
        }
        throw ProcessTapError.formatNegotiationFailed
    }

    // MARK: - Audio Converter

    private func setupConverter(sourceFormat: AVAudioFormat) throws {
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16000,
            channels: 1,
            interleaved: true
        ) else {
            throw ProcessTapError.converterSetupFailed
        }

        guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            throw ProcessTapError.converterSetupFailed
        }
        self.converter = converter
    }

    // MARK: - IO Proc

    private func startIOProc() throws {
        var ioProcID: AudioDeviceIOProcID?

        let status = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateDeviceID, nil) {
            [weak self] _, inputData, _, _, _ in
            guard let self = self, !self.stopped else { return }
            self.handleAudioBuffer(inputData)
        }

        guard status == noErr, let procID = ioProcID else {
            throw ProcessTapError.ioProcCreationFailed(status)
        }
        self.ioProcID = procID

        let startStatus = AudioDeviceStart(aggregateDeviceID, procID)
        guard startStatus == noErr else {
            throw ProcessTapError.deviceStartFailed(startStatus)
        }

        startMicFlushTimer()
    }

    // MARK: - Mic Flush Timer

    /// Start a repeating timer that flushes pending mic samples when app audio is idle.
    /// Fires every 100ms on the writeQueue. If no app audio has arrived since the last
    /// tick and there are pending mic samples, writes them with silence for the app channel.
    private func startMicFlushTimer() {
        let timer = DispatchSource.makeTimerSource(queue: writeQueue)
        timer.schedule(deadline: .now() + .milliseconds(100), repeating: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            guard let self = self, !self.stopped else { return }
            self.flushMicBufferIfIdle()
        }
        timer.resume()
        micFlushTimer = timer
    }

    /// Flush pending mic samples as mic-only frames (zero app audio) when the tap is idle.
    /// Must be called on writeQueue.
    private func flushMicBufferIfIdle() {
        // If app audio arrived recently, it already consumed mic samples via convertAndWrite.
        if appAudioReceivedSinceLastFlush {
            appAudioReceivedSinceLastFlush = false
            return
        }

        // No app audio since last tick — write mic samples with silence for app channel.
        guard !micBuffer.isEmpty else { return }

        let micData = micBuffer
        micBuffer = Data()

        wavWriter.write(micData)
        _bytesWritten += UInt64(micData.count)
    }

    // MARK: - Audio Buffer Handling

    private func handleAudioBuffer(_ inputData: UnsafePointer<AudioBufferList>) {
        let bufferList = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: inputData)
        )

        for buffer in bufferList {
            guard let dataPointer = buffer.mData, buffer.mDataByteSize > 0 else { continue }

            // Check for silence (all zeros = possible permission denial)
            let bytes = UnsafeBufferPointer<UInt8>(
                start: dataPointer.assumingMemoryBound(to: UInt8.self),
                count: Int(buffer.mDataByteSize)
            )
            let isSilent = bytes.allSatisfy { $0 == 0 }

            // Copy data for the write queue (no disk I/O on real-time thread)
            let dataCopy = Data(bytes: dataPointer, count: Int(buffer.mDataByteSize))

            writeQueue.async { [weak self] in
                guard let self = self, !self.stopped else { return }

                if isSilent {
                    self.consecutiveSilentBuffers += 1
                    if self.consecutiveSilentBuffers == self.silenceWarningThreshold {
                        self.onSilenceWarning?()
                    }
                } else {
                    self.consecutiveSilentBuffers = 0
                }

                self.convertAndWrite(dataCopy)
            }
        }
    }

    /// Convert audio data from source format to 16kHz mono 16-bit and write to WAV.
    private func convertAndWrite(_ data: Data) {
        appAudioReceivedSinceLastFlush = true
        guard let converter = converter, let sourceFormat = sourceFormat else { return }

        let frameCount = UInt32(data.count) / sourceFormat.streamDescription.pointee.mBytesPerFrame
        guard frameCount > 0 else { return }

        // Create input buffer and copy raw data into it via the AudioBufferList,
        // which handles any source format (float, integer, interleaved, deinterleaved).
        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: frameCount) else {
            return
        }
        inputBuffer.frameLength = frameCount

        let copySize = min(data.count, Int(frameCount * sourceFormat.streamDescription.pointee.mBytesPerFrame))
        data.withUnsafeBytes { rawBuffer in
            guard let src = rawBuffer.baseAddress else { return }
            let ablPointer = UnsafeMutableAudioBufferListPointer(inputBuffer.mutableAudioBufferList)
            // For mono tap output (CATapDescription stereoMixdown), there's a single buffer.
            // Copy raw data into it. AVAudioConverter handles format/channel conversion.
            for buf in ablPointer {
                guard let dst = buf.mData else { continue }
                memcpy(dst, src, min(copySize, Int(buf.mDataByteSize)))
                break // Only need the first buffer for our mono mixdown tap
            }
        }

        // Calculate output frame count based on sample rate ratio
        let ratio = 16000.0 / sourceFormat.sampleRate
        let outputFrameCount = AVAudioFrameCount(Double(frameCount) * ratio) + 1

        guard let outputFormat = converter.outputFormat as AVAudioFormat?,
              let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputFrameCount) else {
            return
        }

        var error: NSError?
        var inputConsumed = false
        converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            if inputConsumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            inputConsumed = true
            outStatus.pointee = .haveData
            return inputBuffer
        }

        if error != nil {
            return // Silently skip conversion errors
        }

        guard outputBuffer.frameLength > 0 else { return }

        // Extract int16 data from output buffer
        let bytesPerFrame = outputFormat.streamDescription.pointee.mBytesPerFrame
        let byteCount = Int(outputBuffer.frameLength * bytesPerFrame)

        if let channelData = outputBuffer.int16ChannelData {
            var pcmData = Data(bytes: channelData[0], count: byteCount)

            // Mix in mic samples if available
            if !micBuffer.isEmpty {
                let mixBytes = min(pcmData.count, micBuffer.count)
                // Both streams are 16kHz mono int16 — sum with clamping
                pcmData.withUnsafeMutableBytes { tapPtr in
                    micBuffer.withUnsafeBytes { micPtr in
                        let tapSamples = tapPtr.bindMemory(to: Int16.self)
                        let micSamples = micPtr.bindMemory(to: Int16.self)
                        let sampleCount = mixBytes / MemoryLayout<Int16>.size
                        for i in 0..<sampleCount {
                            let mixed = Int32(tapSamples[i]) + Int32(micSamples[i])
                            tapSamples[i] = Int16(clamping: mixed)
                        }
                    }
                }
                micBuffer.removeSubrange(0..<mixBytes)
            }

            wavWriter.write(pcmData)
            _bytesWritten += UInt64(pcmData.count)
        }
    }

    // MARK: - Cleanup

    private func cleanup() {
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = kAudioObjectUnknown
        }
        if aggregateDeviceID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = kAudioObjectUnknown
        }
    }

    // MARK: - Helpers

    private func getStringProperty(objectID: AudioObjectID, selector: AudioObjectPropertySelector) throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value)

        guard status == noErr else {
            throw ProcessTapError.propertyQueryFailed(selector, status)
        }
        return value as String
    }
}

// MARK: - Audio Readiness Polling

@available(macOS 14.2, *)
extension ProcessTap {
    /// Poll until the target process (or one of its child processes) is producing audio.
    /// Returns the audio-producing PID when ready, or nil on timeout.
    /// Some apps (e.g. Chrome) use a dedicated helper process for audio output,
    /// so we always check children first — a child audio process takes priority
    /// over the main PID, since tapping the main PID of a multi-process app
    /// can yield silence even though the main PID has a registered audio object.
    static func waitForAudio(pid: pid_t, timeout: TimeInterval = 60.0) -> pid_t? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            // Check child processes first — apps like Chrome route audio through
            // a dedicated helper (e.g. audio.mojom.AudioService). Tapping the
            // main process PID yields silence because the audio object on the
            // main PID is a registration stub, not the actual audio output.
            for childPid in childPIDs(of: pid) {
                if canTranslatePID(childPid) {
                    return childPid
                }
            }

            // Fall back to the main PID (single-process apps)
            if canTranslatePID(pid) {
                return pid
            }

            Thread.sleep(forTimeInterval: 0.5)
        }
        return nil
    }

    /// Check if Core Audio can translate this PID to an audio object.
    private static func canTranslatePID(_ pid: pid_t) -> Bool {
        var objectID = AudioObjectID(kAudioObjectUnknown)
        var pid = pid
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            UInt32(MemoryLayout<pid_t>.size),
            &pid,
            &size,
            &objectID
        )

        return status == noErr && objectID != kAudioObjectUnknown
    }

    /// Get child PIDs of a given process using pgrep.
    private static func childPIDs(of parentPid: pid_t) -> [pid_t] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-P", String(parentPid)]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8) else { return [] }
            return output
                .split(separator: "\n")
                .compactMap { pid_t($0.trimmingCharacters(in: .whitespaces)) }
        } catch {
            return []
        }
    }
}

// MARK: - Errors

enum ProcessTapError: Error, CustomStringConvertible {
    case pidTranslationFailed(pid_t)
    case tapCreationFailed(OSStatus)
    case aggregateDeviceCreationFailed(OSStatus)
    case deviceNotReady
    case formatNegotiationFailed
    case converterSetupFailed
    case ioProcCreationFailed(OSStatus)
    case deviceStartFailed(OSStatus)
    case propertyQueryFailed(AudioObjectPropertySelector, OSStatus)

    var description: String {
        switch self {
        case .pidTranslationFailed(let pid):
            return "Failed to translate PID \(pid) to audio object. Make sure the app is playing audio."
        case .tapCreationFailed(let status):
            return "Failed to create audio tap (error \(status))."
        case .aggregateDeviceCreationFailed(let status):
            return "Failed to create aggregate device (error \(status))."
        case .deviceNotReady:
            return "Aggregate device did not become ready in time."
        case .formatNegotiationFailed:
            return "Failed to negotiate audio format with device."
        case .converterSetupFailed:
            return "Failed to set up audio format converter."
        case .ioProcCreationFailed(let status):
            return "Failed to create IO proc (error \(status))."
        case .deviceStartFailed(let status):
            return "Failed to start audio device (error \(status))."
        case .propertyQueryFailed(let selector, let status):
            return "Failed to query property \(selector) (error \(status))."
        }
    }
}

#else
// Stub for non-macOS platforms (allows compilation checks on Linux)

import Foundation

final class ProcessTap {
    var onSilenceWarning: (() -> Void)?
    func readBytesWritten() -> UInt64 { 0 }
    func enqueueMicSamples(_ data: Data) {}

    init(pid: pid_t, wavWriter: WAVWriter, mute: Bool = false) {}
    func start() throws { fatalError("ProcessTap requires macOS 14.4+") }
    func stop() {}

    static func waitForAudio(pid: pid_t, timeout: TimeInterval = 60.0) throws -> Bool {
        fatalError("ProcessTap requires macOS 14.4+")
    }
}

enum ProcessTapError: Error, CustomStringConvertible {
    case notSupported
    var description: String { "ProcessTap requires macOS 14.4+" }
}

#endif
