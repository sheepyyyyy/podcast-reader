import Foundation

/// One spoken word and when it was said, in seconds from the start of the audio.
public struct Word: Codable, Hashable, Sendable {
    public let text: String
    public let start: TimeInterval
    public let end: TimeInterval

    public init(text: String, start: TimeInterval, end: TimeInterval) {
        self.text = text
        self.start = start
        self.end = end
    }
}

/// A run of consecutive words shown together as one caption line.
public struct Line: Codable, Hashable, Sendable, Identifiable {
    public let id: Int
    public let wordRange: Range<Int>

    public init(id: Int, wordRange: Range<Int>) {
        self.id = id
        self.wordRange = wordRange
    }
}

public struct Transcript: Codable, Hashable, Sendable {
    public let words: [Word]
    public let lines: [Line]

    public init(words: [Word]) {
        self.words = words
        self.lines = LineBuilder.lines(for: words)
    }

    /// The line holding a word. The word index must be valid.
    public func lineIndex(forWord wordIndex: Int) -> Int {
        var low = 0
        var high = lines.count - 1
        while low < high {
            let middle = (low + high) / 2
            if lines[middle].wordRange.upperBound <= wordIndex {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return low
    }

    public func text(ofLine lineIndex: Int) -> String {
        words[lines[lineIndex].wordRange].map(\.text).joined(separator: " ")
    }
}
