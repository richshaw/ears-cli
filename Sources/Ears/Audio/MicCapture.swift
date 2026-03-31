#if canImport(CoreAudio) && canImport(AudioToolbox) && canImport(AVFoundation)

import CoreAudio
import AudioToolbox
import AVFoundation
import Foundation

/// Captures audio from the default system input device (microphone).
/// Converts to 16kHz mono 16-bit PCM and delivers samples via a callback.
@available(macOS 14.2, *)
final class MicCapture {
    private var inputDeviceID: AudioObjectID = kAudioObjectUnknown
    private var ioProcID: AudioDeviceIOProcID?
    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?
    private let convertQueue = DispatchQueue(label: "com.ears.mic-convert", qos: .userInitiated)

    private let _stopped = LockedValue(false)
    private var stopped: Bool {
        get { _stopped.value }
        set { _stopped.value = newValue }
    }

    /// Called on `convertQueue` with converted 16kHz mono int16 PCM data.
    var onSamples: ((Data) -> Void)?

    init() {}

    // MARK: - Public

    func start() throws {
        let deviceID = try getDefaultInputDevice()
        self.inputDeviceID = deviceID

        let format = try getInputFormat(deviceID: deviceID)
        self.sourceFormat = format
        try setupConverter(sourceFormat: format)
        try startIOProc()
    }

    func stop() {
        guard !stopped else { return }
        stopped = true

        if let ioProcID = ioProcID {
            AudioDeviceStop(inputDeviceID, ioProcID)
            AudioDeviceDestroyIOProcID(inputDeviceID, ioProcID)
            self.ioProcID = nil
        }

        // Drain the convert queue
        convertQueue.sync {}
    }

    // MARK: - Device Discovery

    private func getDefaultInputDevice() throws -> AudioObjectID {
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0, nil,
            &size,
            &deviceID
        )

        guard status == noErr, deviceID != kAudioObjectUnknown else {
            throw MicCaptureError.noInputDevice
        }
        return deviceID
    }

    // MARK: - Format

    private func getInputFormat(deviceID: AudioObjectID) throws -> AVAudioFormat {
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamFormat,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &asbd)

        guard status == noErr, asbd.mSampleRate > 0,
              let format = AVAudioFormat(streamDescription: &asbd) else {
            throw MicCaptureError.formatQueryFailed
        }
        return format
    }

    // MARK: - Converter

    private func setupConverter(sourceFormat: AVAudioFormat) throws {
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16000,
            channels: 1,
            interleaved: true
        ) else {
            throw MicCaptureError.converterSetupFailed
        }

        guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            throw MicCaptureError.converterSetupFailed
        }
        self.converter = converter
    }

    // MARK: - IO Proc

    private func startIOProc() throws {
        var ioProcID: AudioDeviceIOProcID?

        let status = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, inputDeviceID, nil) {
            [weak self] _, inputData, _, _, _ in
            guard let self = self, !self.stopped else { return }
            self.handleMicBuffer(inputData)
        }

        guard status == noErr, let procID = ioProcID else {
            throw MicCaptureError.ioProcCreationFailed(status)
        }
        self.ioProcID = procID

        let startStatus = AudioDeviceStart(inputDeviceID, procID)
        guard startStatus == noErr else {
            throw MicCaptureError.deviceStartFailed(startStatus)
        }
    }

    // MARK: - Buffer Handling

    private func handleMicBuffer(_ inputData: UnsafePointer<AudioBufferList>) {
        // Mutable cast required for UnsafeMutableAudioBufferListPointer API ergonomics,
        // but we only read from the buffer—the input data is not modified.
        let bufferList = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: inputData)
        )

        for buffer in bufferList {
            guard let dataPointer = buffer.mData, buffer.mDataByteSize > 0 else { continue }

            let dataCopy = Data(bytes: dataPointer, count: Int(buffer.mDataByteSize))

            convertQueue.async { [weak self] in
                guard let self = self, !self.stopped else { return }
                self.convertAndDeliver(dataCopy)
            }
        }
    }

    private func convertAndDeliver(_ data: Data) {
        guard let converter = converter, let sourceFormat = sourceFormat else { return }

        let frameCount = UInt32(data.count) / sourceFormat.streamDescription.pointee.mBytesPerFrame
        guard frameCount > 0 else { return }

        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: frameCount) else {
            return
        }
        inputBuffer.frameLength = frameCount

        let copySize = min(data.count, Int(frameCount * sourceFormat.streamDescription.pointee.mBytesPerFrame))
        data.withUnsafeBytes { rawBuffer in
            guard let src = rawBuffer.baseAddress else { return }
            let ablPointer = UnsafeMutableAudioBufferListPointer(inputBuffer.mutableAudioBufferList)
            for buf in ablPointer {
                guard let dst = buf.mData else { continue }
                memcpy(dst, src, min(copySize, Int(buf.mDataByteSize)))
                break
            }
        }

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

        if error != nil { return }
        guard outputBuffer.frameLength > 0 else { return }

        let bytesPerFrame = outputFormat.streamDescription.pointee.mBytesPerFrame
        let byteCount = Int(outputBuffer.frameLength * bytesPerFrame)

        if let channelData = outputBuffer.int16ChannelData {
            let pcmData = Data(bytes: channelData[0], count: byteCount)
            onSamples?(pcmData)
        }
    }
}

// MARK: - Errors

enum MicCaptureError: Error, CustomStringConvertible {
    case noInputDevice
    case formatQueryFailed
    case converterSetupFailed
    case ioProcCreationFailed(OSStatus)
    case deviceStartFailed(OSStatus)

    var description: String {
        switch self {
        case .noInputDevice:
            return "No microphone found. Check System Settings > Sound > Input."
        case .formatQueryFailed:
            return "Failed to query microphone audio format."
        case .converterSetupFailed:
            return "Failed to set up microphone audio converter."
        case .ioProcCreationFailed(let status):
            return "Failed to create microphone IO proc (error \(status))."
        case .deviceStartFailed(let status):
            return "Failed to start microphone capture (error \(status))."
        }
    }
}

#else

import Foundation

final class MicCapture {
    var onSamples: ((Data) -> Void)?
    init() {}
    func start() throws { fatalError("MicCapture requires macOS 14.2+") }
    func stop() {}
}

enum MicCaptureError: Error, CustomStringConvertible {
    case notSupported
    var description: String { "MicCapture requires macOS 14.2+" }
}

#endif
