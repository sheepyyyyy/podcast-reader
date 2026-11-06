import Foundation

public struct SearchMatch: Hashable, Sendable, Identifiable {
    public let wordRange: Range<Int>
    public let time: TimeInterval
    /// The match with up to five words on each side.
    public let context: String
    /// Which words `context` covers.
    public let contextRange: Range<Int>

    public var id: Int { wordRange.lowerBound }
}

/// Finds where a word or phrase was said, ignoring case and punctuation.
public struct SearchIndex: Sendable {
    private static let contextWords = 5

    private let words: [Word]
    private let normalized: [String]

    public init(transcript: Transcript) {
        words = transcript.words
        normalized = transcript.words.map { Self.normalize($0.text) }
    }

    /// Query words must match consecutive transcript words. The last query word matches
    /// as a prefix, so results appear while a word is still being typed.
    public func search(_ query: String) -> [SearchMatch] {
        let tokens = query
            .split(whereSeparator: \.isWhitespace)
            .map { Self.normalize(String($0)) }
            .filter { !$0.isEmpty }
        guard let lastToken = tokens.last, tokens.count <= normalized.count else { return [] }

        var matches: [SearchMatch] = []
        for start in 0...(normalized.count - tokens.count) {
            let isMatch = tokens.indices.allSatisfy { offset in
                let word = normalized[start + offset]
                return offset == tokens.count - 1 ? word.hasPrefix(lastToken) : word == tokens[offset]
            }
            if isMatch {
                let range = start..<(start + tokens.count)
                let contextRange = max(0, range.lowerBound - Self.contextWords)..<min(words.count, range.upperBound + Self.contextWords)
                matches.append(SearchMatch(
                    wordRange: range,
                    time: words[start].start,
                    context: words[contextRange].map(\.text).joined(separator: " "),
                    contextRange: contextRange
                ))
            }
        }
        return matches
    }

    private static func normalize(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US"))
        return String(folded.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }
}
