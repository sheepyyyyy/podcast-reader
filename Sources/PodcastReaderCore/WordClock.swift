import Foundation

/// Answers "which word is being spoken at this moment?"
public struct WordClock: Sendable {
    private let starts: [TimeInterval]

    public init(words: [Word]) {
        starts = words.map(\.start)
    }

    /// The last word that has started by `time`, so a pause keeps the previous word active.
    /// Returns nil before the first word.
    public func activeWordIndex(at time: TimeInterval) -> Int? {
        let next = firstWord(startingAfter: time)
        return next == 0 ? nil : next - 1
    }

    /// When the active word next changes, or nil once the last word has started.
    public func nextChange(after time: TimeInterval) -> TimeInterval? {
        let next = firstWord(startingAfter: time)
        return next < starts.count ? starts[next] : nil
    }

    private func firstWord(startingAfter time: TimeInterval) -> Int {
        var low = 0
        var high = starts.count
        while low < high {
            let middle = (low + high) / 2
            if starts[middle] <= time {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return low
    }
}
