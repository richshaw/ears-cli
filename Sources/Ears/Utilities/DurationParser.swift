import Foundation

/// Parse duration strings like "10h", "1h30m", "45m", "90s" into TimeInterval.
enum DurationParser {
    static func parse(_ string: String) -> TimeInterval? {
        let pattern = #"^(?:(\d+)h)?(?:(\d+)m)?(?:(\d+)s)?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: string, range: NSRange(string.startIndex..., in: string)) else {
            return nil
        }

        var total: TimeInterval = 0
        var hasAnyComponent = false

        // Hours
        if let range = Range(match.range(at: 1), in: string), let hours = Double(string[range]) {
            total += hours * 3600
            hasAnyComponent = true
        }

        // Minutes
        if let range = Range(match.range(at: 2), in: string), let minutes = Double(string[range]) {
            total += minutes * 60
            hasAnyComponent = true
        }

        // Seconds
        if let range = Range(match.range(at: 3), in: string), let seconds = Double(string[range]) {
            total += seconds
            hasAnyComponent = true
        }

        return hasAnyComponent ? total : nil
    }
}
