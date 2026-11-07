import Foundation
import PDFKit

public struct ReadableWord: Hashable, Sendable {
    public let text: String
    public let location: WordLocation
}

public struct ReadableDocument: Sendable {
    public let words: [ReadableWord]
    public let pageCount: Int
}

public enum DocumentError: Error, Equatable {
    case unreadable
    case passwordProtected
    case noReadableText
    case speechDidNotMatch
}

/// Pulls the words to speak out of a PDF, keeping where each one is on its page.
public enum DocumentReader {
    private struct Token {
        let text: String
        /// More than one when a word was in pieces in the page's text.
        let ranges: [NSRange]
        let lineNumber: Int
        let line: MarginLine
    }

    /// Words count as one line when they overlap vertically by at least this share of the
    /// smaller one's height. A shared baseline wouldn't do: superscripts sit above it.
    private static let lineOverlapShare = 0.3

    /// Whether two words' frames are on one line of text.
    public static func isSameLine(_ first: CGRect, _ second: CGRect) -> Bool {
        let overlap = min(first.maxY, second.maxY) - max(first.minY, second.minY)
        return overlap > min(first.height, second.height) * lineOverlapShare
    }

    /// How a piece of a page's text follows the one before it. PDFs made by Chrome, and perhaps
    /// others, come out of PDFKit with line breaks inside words, as in "w" then "ritten".
    public enum PieceJoin: Equatable, Sendable {
        case separate, touching, overlapping
    }

    /// Pieces closer than this share of their height touch. Real spaces measured about a quarter.
    private static let touchingGap = 0.1

    /// Only a line break between pieces on one line is in doubt. Any space, or a move to the
    /// next line, is a word break.
    public static func join(separator: String, first: CGRect, second: CGRect) -> PieceJoin {
        guard !separator.unicodeScalars.contains(where: CharacterSet.whitespaces.contains),
              isSameLine(first, second), second.minX >= first.minX
        else { return .separate }
        let gap = (second.minX - first.maxX) / max(1, min(first.height, second.height))
        if gap > touchingGap { return .separate }
        return gap >= -touchingGap ? .touching : .overlapping
    }

    /// Pieces drawn over each other can be one word ("li" and "mit") or two ("loan" and "minus"),
    /// so they join only into a real word that they don't already make on their own.
    public static func joinsOverlap(_ first: String, _ rest: String) -> Bool {
        guard first.contains(where: \.isLetter), rest.contains(where: \.isLetter) else { return false }
        return isWord(first + rest) && !(isWord(first) && isWord(rest))
    }

    /// The word list has rare short words, like "li" and "n", that as pieces are nearly always
    /// part of something longer, so only these common ones count.
    private static let shortWords: Set<String> = [
        "a", "i", "an", "as", "at", "be", "by", "do", "go", "he", "if", "in", "is", "it",
        "me", "my", "no", "of", "on", "or", "so", "to", "up", "us", "we",
    ]

    /// The word list every Mac has. Without it, overlapping pieces simply stay apart.
    private static let dictionary: Set<String> = {
        guard let words = try? String(contentsOfFile: "/usr/share/dict/words", encoding: .utf8) else { return [] }
        return Set(words.split(separator: "\n").map { $0.lowercased() })
    }()

    private static func isWord(_ text: String) -> Bool {
        let word = text.lowercased().filter(\.isLetter)
        if word.count <= 2 { return shortWords.contains(word) }
        if dictionary.contains(word) { return true }
        // The list has few plurals and other endings.
        let endings: [(String, String)] = [("s", ""), ("es", ""), ("ed", ""), ("ed", "e"), ("ing", ""), ("ing", "e"), ("ly", ""), ("er", ""), ("ers", "")]
        return endings.contains { ending, restore in
            word.hasSuffix(ending) && dictionary.contains(String(word.dropLast(ending.count)) + restore)
        }
    }

    /// The word as it should be spoken and searched. PDFs often store letter pairs as single
    /// ligature characters, such as "ﬁ" in "ﬁnd", which voices and searches can stumble on.
    public static func spokenForm(of text: String) -> String {
        text.precomposedStringWithCompatibilityMapping
    }

    public static func read(pdfAt url: URL) throws -> ReadableDocument {
        guard let document = PDFDocument(url: url) else { throw DocumentError.unreadable }
        guard !document.isLocked else { throw DocumentError.passwordProtected }

        let pages = (0..<document.pageCount).map { index in
            document.page(at: index).map { tokens(on: $0, index: index) } ?? []
        }
        let skipped = RunningTextFilter.skippedLines(in: pages.flatMap { $0.map(\.line) })

        var words: [ReadableWord] = []
        for (index, tokens) in pages.enumerated() {
            words += readableWords(from: tokens.filter { !skipped.contains($0.line) }, page: index)
        }
        guard !words.isEmpty else { throw DocumentError.noReadableText }
        return ReadableDocument(words: words, pageCount: document.pageCount)
    }

    /// Splits on whitespace, so words keep their punctuation and the voice pauses naturally.
    private static func tokens(on page: PDFPage, index: Int) -> [Token] {
        guard let string = page.string, !string.isEmpty,
              let pattern = try? NSRegularExpression(pattern: #"\S+"#)
        else { return [] }

        let text = string as NSString
        let box = page.bounds(for: .cropBox)
        let ranges = pattern.matches(in: string, range: NSRange(location: 0, length: text.length)).map(\.range)
        let pieceFrames = ranges.map { page.selection(for: $0)?.bounds(for: page) ?? .zero }
        let words = wholeWords(ranges, frames: pieceFrames, in: text)

        // A word with no frame takes its neighbor's, rather than appearing to be at the very
        // bottom of the page, where a lone number would be mistaken for a page number.
        var frames: [CGRect] = []
        frames.reserveCapacity(words.count)
        for word in words {
            let frame = word.map { pieceFrames[$0] }.filter { !$0.isEmpty }.reduce(CGRect.null) { $0.union($1) }
            frames.append(frame.isNull ? (frames.last ?? .zero) : frame)
        }
        let texts = words.map { $0.map { text.substring(with: ranges[$0]) }.joined() }

        var tokens: [Token] = []
        var start = 0
        var lineNumber = 0
        while start < words.count {
            var end = start + 1
            while end < words.count, isSameLine(frames[end - 1], frames[end]) {
                end += 1
            }

            let lineText = texts[start..<end].joined(separator: " ")
            let position = box.height > 0 && !frames[start].isEmpty ? 1 - (frames[start].midY - box.minY) / box.height : 0.5
            let line = MarginLine(page: index, text: lineText, verticalPosition: position)
            for wordIndex in start..<end {
                tokens.append(Token(
                    text: texts[wordIndex],
                    ranges: words[wordIndex].map { ranges[$0] },
                    lineNumber: lineNumber,
                    line: line
                ))
            }
            start = end
            lineNumber += 1
        }
        return tokens
    }

    /// Groups the pieces of the page's text into words, as indexes into `ranges`.
    private static func wholeWords(_ ranges: [NSRange], frames: [CGRect], in text: NSString) -> [[Int]] {
        func piece(_ index: Int) -> String { text.substring(with: ranges[index]) }
        func joinAfter(_ index: Int) -> PieceJoin {
            let end = ranges[index].location + ranges[index].length
            let separator = text.substring(with: NSRange(location: end, length: ranges[index + 1].location - end))
            return join(separator: separator, first: frames[index], second: frames[index + 1])
        }

        var words: [[Int]] = []
        var start = 0
        while start < ranges.count {
            var word = [start]
            while let last = word.last, last + 1 < ranges.count {
                switch joinAfter(last) {
                case .touching:
                    word.append(last + 1)
                    continue
                case .overlapping:
                    // Everything that would follow on, so the whole word is judged.
                    var rest = [last + 1]
                    while let end = rest.last, end + 1 < ranges.count, joinAfter(end) == .touching {
                        rest.append(end + 1)
                    }
                    if joinsOverlap(word.map(piece).joined(), rest.map(piece).joined()) {
                        word += rest
                        continue
                    }
                case .separate:
                    break
                }
                break
            }
            words.append(word)
            start = word.last! + 1
        }
        return words
    }

    /// Rejoins a word hyphenated across a line break, such as "re-" then "building".
    private static func readableWords(from tokens: [Token], page: Int) -> [ReadableWord] {
        var words: [ReadableWord] = []
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            let next = index + 1 < tokens.count ? tokens[index + 1] : nil
            if let next, token.text.count > 1, token.text.hasSuffix("-"),
               next.lineNumber != token.lineNumber, next.text.first?.isLowercase == true {
                words.append(ReadableWord(
                    text: spokenForm(of: token.text.dropLast() + next.text),
                    location: WordLocation(page: page, ranges: (token.ranges + next.ranges).map(pageRange))
                ))
                index += 2
            } else {
                words.append(ReadableWord(
                    text: spokenForm(of: token.text),
                    location: WordLocation(page: page, ranges: token.ranges.map(pageRange))
                ))
                index += 1
            }
        }
        return words
    }

    private static func pageRange(_ range: NSRange) -> PageTextRange {
        PageTextRange(location: range.location, length: range.length)
    }
}
