import Foundation

/// Words for how long a long job has left, based on its progress so far.
public enum TimeRemaining {
    private static let minimumFraction = 0.05
    private static let minimumElapsed: TimeInterval = 20

    /// Returns nil until there's enough to go on, as an early guess can be far off.
    public static func text(elapsed: TimeInterval, fraction: Double) -> String? {
        guard fraction > 0, fraction < 1, fraction >= minimumFraction || elapsed >= minimumElapsed else { return nil }

        let remaining = elapsed * (1 - fraction) / fraction
        let minutes = Int((remaining / 60).rounded())
        if minutes < 1 { return "Less than a minute left" }
        if minutes < 60 { return "About \(minutes) minute\(minutes == 1 ? "" : "s") left" }

        let hours = minutes / 60
        let leftover = minutes % 60
        let hourText = "\(hours) hour\(hours == 1 ? "" : "s")"
        return leftover == 0 ? "About \(hourText) left" : "About \(hourText) \(leftover) minutes left"
    }
}
