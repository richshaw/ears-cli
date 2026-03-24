import Foundation

/// Writes raw PCM audio data to a WAV file with streaming support.
/// Writes a placeholder header first, then appends PCM data, and finalizes
/// by seeking back to update the sizes in the header.
final class WAVWriter {
    private let fileHandle: FileHandle
    private let url: URL
    private var dataSize: UInt32 = 0
    private let sampleRate: UInt32
    private let channels: UInt16
    private let bitsPerSample: UInt16

    init(url: URL, sampleRate: UInt32 = 16000, channels: UInt16 = 1, bitsPerSample: UInt16 = 16) throws {
        self.url = url
        self.sampleRate = sampleRate
        self.channels = channels
        self.bitsPerSample = bitsPerSample

        // Create the file
        FileManager.default.createFile(atPath: url.path, contents: nil)
        self.fileHandle = try FileHandle(forWritingTo: url)

        // Write placeholder header (sizes will be updated on finalize)
        try writePlaceholderHeader()
    }

    /// Append raw PCM data.
    func write(_ data: Data) {
        fileHandle.seekToEndOfFile()
        fileHandle.write(data)
        dataSize += UInt32(data.count)
    }

    /// Finalize the WAV file by updating header sizes.
    func finalize() throws {
        let byteRate = sampleRate * UInt32(channels) * UInt32(bitsPerSample / 8)
        let blockAlign = channels * (bitsPerSample / 8)

        // Seek to byte 4: RIFF chunk size = file size - 8
        let riffSize = 36 + dataSize
        fileHandle.seek(toFileOffset: 4)
        fileHandle.write(uint32Data(riffSize))

        // Seek to byte 40: data subchunk size
        fileHandle.seek(toFileOffset: 40)
        fileHandle.write(uint32Data(dataSize))

        try fileHandle.close()
    }

    /// Close without finalizing (for error cases).
    func close() {
        try? fileHandle.close()
    }

    // MARK: - Private

    private func writePlaceholderHeader() throws {
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
