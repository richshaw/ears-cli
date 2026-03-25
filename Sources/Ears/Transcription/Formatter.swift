import Foundation

enum Formatter {
    /// Convert SRT content to a markdown transcript.
    static func srtToMarkdown(srt: String, title: String, duration: TimeInterval) -> String {
        let lines = parseSrt(srt)
        let dateStr = ISO8601DateFormatter.string(
            from: Date(), timeZone: .current, formatOptions: [.withFullDate, .withDashSeparatorInDate]
        )
        let durationStr = formatDuration(duration)

        var md = "# \(title) — Transcript\n\n"
        md += "Recorded: \(dateStr)\n"
        md += "Duration: \(durationStr)\n\n"

        for line in lines {
            md += "[\(line.timestamp)] \(line.text)\n"
        }

        return md
    }

    /// Parse SRT formatted text into timestamp + text pairs.
    static func parseSrt(_ srt: String) -> [(timestamp: String, text: String)] {
        var results: [(timestamp: String, text: String)] = []
        let blocks = srt.components(separatedBy: "\n\n")

        for block in blocks {
            let lines = block.trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: "\n")

            // SRT format: index, timestamp line, text line(s)
            guard lines.count >= 3 else { continue }

            // Parse timestamp line: "00:00:01,000 --> 00:00:08,000"
            let timestampLine = lines[1]
            let parts = timestampLine.components(separatedBy: " --> ")
            guard let startTime = parts.first else { continue }

            // Convert SRT timestamp (00:00:01,000) to display format (00:00:01)
            let displayTime = srtTimestampToDisplay(startTime)

            // Join all text lines
            let text = lines[2...].joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if !text.isEmpty {
                results.append((timestamp: displayTime, text: text))
            }
        }

        return results
    }

    /// Adjust timestamps in SRT content by adding an offset.
    static func adjustSrtTimestamps(srt: String, offsetSeconds: TimeInterval) -> String {
        guard offsetSeconds > 0 else { return srt }

        let blocks = srt.components(separatedBy: "\n\n")
        var adjusted: [String] = []

        for block in blocks {
            let lines = block.trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: "\n")
            guard lines.count >= 3 else {
                adjusted.append(block)
                continue
            }

            // Adjust timestamp line
            let timestampLine = lines[1]
            let parts = timestampLine.components(separatedBy: " --> ")
            guard parts.count == 2 else {
                adjusted.append(block)
                continue
            }

            let adjustedStart = addOffset(to: parts[0], seconds: offsetSeconds)
            let adjustedEnd = addOffset(to: parts[1], seconds: offsetSeconds)

            var newLines = lines
            newLines[1] = "\(adjustedStart) --> \(adjustedEnd)"
            adjusted.append(newLines.joined(separator: "\n"))
        }

        return adjusted.joined(separator: "\n\n")
    }

    // MARK: - Private

    /// Convert "00:01:23,456" to "00:01:23"
    private static func srtTimestampToDisplay(_ timestamp: String) -> String {
        let cleaned = timestamp.trimmingCharacters(in: .whitespaces)
        // Remove milliseconds
        if let commaIndex = cleaned.firstIndex(of: ",") {
            return String(cleaned[cleaned.startIndex..<commaIndex])
        }
        if let dotIndex = cleaned.firstIndex(of: ".") {
            return String(cleaned[cleaned.startIndex..<dotIndex])
        }
        return cleaned
    }

    /// Add seconds offset to an SRT timestamp "HH:MM:SS,mmm"
    private static func addOffset(to timestamp: String, seconds: TimeInterval) -> String {
        let cleaned = timestamp.trimmingCharacters(in: .whitespaces)
        let parts = cleaned.components(separatedBy: ",")
        let timeParts = (parts.first ?? "00:00:00").components(separatedBy: ":")
        let millis = parts.count > 1 ? parts[1] : "000"

        guard timeParts.count == 3,
              let h = Int(timeParts[0]),
              let m = Int(timeParts[1]),
              let s = Int(timeParts[2]) else {
            return timestamp
        }

        let totalSeconds = Double(h * 3600 + m * 60 + s) + seconds
        let newH = Int(totalSeconds) / 3600
        let newM = (Int(totalSeconds) % 3600) / 60
        let newS = Int(totalSeconds) % 60

        return String(format: "%02d:%02d:%02d,%@", newH, newM, newS, millis)
    }

    private static func formatDuration(_ seconds: TimeInterval) -> String {
        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60
        let secs = Int(seconds) % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, secs)
    }
}
