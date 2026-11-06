import Foundation

/// A piece of text Kokoro spoke, with its time within its chunk of audio.
public struct KokoroToken: Codable, Equatable, Sendable {
    public let text: String
    public let start: TimeInterval?
    public let end: TimeInterval?

    public init(text: String, start: TimeInterval?, end: TimeInterval?) {
        self.text = text
        self.start = start
        self.end = end
    }
}

/// Maps Kokoro's tokens onto the app's words. Kokoro can split a word, as with "well-known",
/// and can change the text a little, so the two are matched by position with whitespace
/// ignored, not one to one. A mismatch stays local instead of shifting everything after it.
public enum KokoroTimeline {
    public static func wordTimes(words: [String], tokens: [KokoroToken], duration: TimeInterval) -> [WordTime] {
        guard !words.isEmpty else { return [] }

        var wordOffsets: [Int] = []
        var wordLength = 0
        for word in words {
            wordOffsets.append(wordLength)
            wordLength += length(of: word)
        }
        let tokenLength = tokens.reduce(0) { $0 + length(of: $1.text) }
        let scale = tokenLength > 0 ? Double(wordLength) / Double(tokenLength) : 1

        var known = [Double?](repeating: nil, count: words.count)
        var latest = -1.0
        var tokenOffset = 0
        for token in tokens {
            defer { tokenOffset += length(of: token.text) }
            // Punctuation can have a time of its own, ahead of the word it's attached to.
            guard let start = token.start, token.text.contains(where: { $0.isLetter || $0.isNumber }) else { continue }

            let position = Int((Double(tokenOffset) * scale).rounded())
            let word = wordIndex(atOffset: position, offsets: wordOffsets)
            if known[word] == nil, start > latest {
                known[word] = start
                latest = start
            }
        }
        return SpeechTimeline.times(fromKnownStarts: known, total: duration)
    }

    private static func length(of text: String) -> Int {
        text.reduce(0) { $0 + ($1.isWhitespace ? 0 : 1) }
    }

    private static func wordIndex(atOffset offset: Int, offsets: [Int]) -> Int {
        var low = 0
        var high = offsets.count
        while low < high {
            let middle = (low + high) / 2
            if offsets[middle] <= offset {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return max(low - 1, 0)
    }

    /// Adds a chunk's times after those before it. Starts must stay in order for looking up
    /// the current word, and a chunk's last words can be squeezed slightly past its end.
    static func append(_ chunk: [WordTime], startingAt offset: TimeInterval, to all: inout [WordTime]) {
        for time in chunk {
            let start = max(offset + time.start, (all.last?.start ?? -0.001) + 0.001)
            all.append(WordTime(start: start, end: max(offset + time.end, start)))
        }
    }
}
