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
        return low == 0 ? nil : low - 1
    }
}
