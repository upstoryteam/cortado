import Foundation

nonisolated enum Format {
    private static let megabyte: UInt64 = 1_048_576
    private static let gigabyte = Double(megabyte * 1024)

    /// "42m", "2h", "1h 42m". Rounds up so a fresh 30-minute session reads "30m".
    static func duration(_ interval: TimeInterval) -> String {
        let minutes = max(1, Int((interval / 60).rounded(.up)))
        let (hours, remainder) = minutes.quotientAndRemainder(dividingBy: 60)
        if hours == 0 { return "\(minutes)m" }
        return remainder == 0 ? "\(hours)h" : "\(hours)h \(remainder)m"
    }

    /// "42 min", "2 hrs", "1 hr 42 min": the same, for a sentence rather than a button.
    static func spelledDuration(_ interval: TimeInterval) -> String {
        let minutes = max(1, Int((interval / 60).rounded(.up)))
        let (hours, remainder) = minutes.quotientAndRemainder(dividingBy: 60)
        if hours == 0 { return "\(minutes) min" }
        let whole = "\(hours) \(hours == 1 ? "hr" : "hrs")"
        return remainder == 0 ? whole : "\(whole) \(remainder) min"
    }

    /// "3.8 GB" or "994 MB": one decimal is as much as anyone reads at a glance.
    /// Megabytes stop at three digits, so nothing reads "1000 MB".
    static func bytes(_ count: UInt64) -> String {
        count >= megabyte * 1000 ? "\(gigabytes(count)) GB" : "\(count / megabyte) MB"
    }

    /// "17.4 of 24 GB".
    static func usage(_ used: UInt64, of total: UInt64) -> String {
        "\(gigabytes(used)) of \(Int((Double(total) / gigabyte).rounded())) GB"
    }

    static func percent(_ fraction: Double) -> String {
        fraction.formatted(.percent.precision(.fractionLength(0)))
    }

    private static func gigabytes(_ count: UInt64) -> String {
        (Double(count) / gigabyte).formatted(.number.precision(.fractionLength(1)))
    }
}
