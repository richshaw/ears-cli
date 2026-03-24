import Foundation

/// Writes raw PCM audio data to a WAV file with streaming support.
///
/// Writes a placeholder header first, then appends PCM data, and finalizes
/// by seeking back to update the sizes in the header.
///
/// **Threading**: This class is NOT thread-safe. All calls to `write()` and `finalize()`
/// must be serialized by the caller (e.g., via a serial DispatchQueue). In ears,
/// `ProcessTap.writeQueue` ensures this — `write()` is called from the serial write queue,
/// and `finalize()` is called after a `writeQueue.sync {}` barrier.
///
/// **WAV 4GB limit**: The RIFF/WAV format uses 32-bit sizes, limiting files to ~4GB.
/// At 16kHz mono 16-bit, this is ~37 hours. For longer recordings, `dataSize` will
/// saturate at UInt32.max and the header will indicate the maximum representable size.
/// Most tools (including whisper-cpp) can still read the file by inferring size from
/// the file system. A warning is printed when approaching the limit.
final class WAVWriter {
    private let fileHandle: FileHandle
    private let url: URL
    private var dataSize: UInt64 = 0
    private var warnedAboutLimit = false
    private let sampleRate: UInt32
    private let channels: UInt16
    private let bitsPerSample: UInt16

    /// Maximum data size representable in a WAV header (4GB - 36 byte header).
    private static let maxDataSize: UInt64 = UInt64(UInt32.max) - 36

    init(url: URL, sampleRate: UInt32 = 16000, channels: UInt16 = 1, bitsPerSample: UInt16 = 16) throws {
        self.url = url
        self.sampleRate = sampleRate
        self.channels = channels
        self.bitsPerSample = bitsPerSample

        // Create the file
        FileManager.default.createFile(atPath: url.path, contents: nil)
        self.fileHandle = try FileHandle(forWritingTo: url)

        // Write placeholder header (sizes will be updated on finalize)
        writePlaceholderHeader()
    }

    /// Append raw PCM data.
    func write(_ data: Data) {
        fileHandle.seekToEndOfFile()
        fileHandle.write(data)
        dataSize += UInt64(data.count)

        if !warnedAboutLimit && dataSize > WAVWriter.maxDataSize - 100_000_000 {
            warnedAboutLimit = true
            fputs("\nWarning: Approaching WAV 4GB size limit. Recording can continue but the file header will be capped.\n", stderr)
        }
    }

    /// Finalize the WAV file by updating header sizes.
    func finalize() throws {
        // Cap at WAV format's 32-bit limit
        let cappedDataSize = UInt32(min(dataSize, UInt64(UInt32.max) - 36))
        let riffSize = 36 + cappedDataSize

        // Seek to byte 4: RIFF chunk size = file size - 8
        fileHandle.seek(toFileOffset: 4)
        fileHandle.write(uint32Data(riffSize))

        // Seek to byte 40: data subchunk size
        fileHandle.seek(toFileOffset: 40)
        fileHandle.write(uint32Data(cappedDataSize))

        try fileHandle.close()
    }

    /// Close without finalizing (for error cases).
    func close() {
        try? fileHandle.close()
    }

    // MARK: - Private

    private func writePlaceholderHeader() {
        let byteRate = sampleRate * UInt32(channels) * UInt32(bitsPerSample / 8)
        let blockAlign = channels * (bitsPerSample / 8)

        var header = Data()

        // RIFF header
        header.append(contentsOf: "RIFF".utf8)          // ChunkID
        header.append(uint32Data(0))                     // ChunkSize (placeholder)
        header.append(contentsOf: "WAVE".utf8)           // Format

        // fmt subchunk
        header.append(contentsOf: "fmt ".utf8)           // Subchunk1ID
        header.append(uint32Data(16))                    // Subchunk1Size (PCM = 16)
        header.append(uint16Data(1))                     // AudioFormat (PCM = 1)
        header.append(uint16Data(channels))              // NumChannels
        header.append(uint32Data(sampleRate))            // SampleRate
        header.append(uint32Data(byteRate))              // ByteRate
        header.append(uint16Data(blockAlign))            // BlockAlign
        header.append(uint16Data(bitsPerSample))         // BitsPerSample

        // data subchunk
        header.append(contentsOf: "data".utf8)           // Subchunk2ID
        header.append(uint32Data(0))                     // Subchunk2Size (placeholder)

        fileHandle.write(header)
    }

    private func uint32Data(_ value: UInt32) -> Data {
        var v = value.littleEndian
        return Data(bytes: &v, count: 4)
    }

    private func uint16Data(_ value: UInt16) -> Data {
        var v = value.littleEndian
        return Data(bytes: &v, count: 2)
    }
}
