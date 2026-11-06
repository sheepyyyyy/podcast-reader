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
        let range: NSRange
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
        // A word with no frame takes its neighbor's, rather than appearing to be at the very
        // bottom of the page, where a lone number would be mistaken for a page number.
        var frames: [CGRect] = []
        frames.reserveCapacity(ranges.count)
        for range in ranges {
            let frame = page.selection(for: range)?.bounds(for: page) ?? .zero
            frames.append(frame.isEmpty ? (frames.last ?? .zero) : frame)
        }

        var tokens: [Token] = []
        var start = 0
        var lineNumber = 0
        while start < ranges.count {
            var end = start + 1
            while end < ranges.count, isSameLine(frames[end - 1], frames[end]) {
                end += 1
            }

            let lineText = ranges[start..<end].map { text.substring(with: $0) }.joined(separator: " ")
            let position = box.height > 0 && !frames[start].isEmpty ? 1 - (frames[start].midY - box.minY) / box.height : 0.5
            let line = MarginLine(page: index, text: lineText, verticalPosition: position)
            for tokenIndex in start..<end {
                tokens.append(Token(
                    text: text.substring(with: ranges[tokenIndex]),
                    range: ranges[tokenIndex],
                    lineNumber: lineNumber,
                    line: line
                ))
            }
            start = end
            lineNumber += 1
        }
        return tokens
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
                    location: WordLocation(page: page, ranges: [pageRange(token.range), pageRange(next.range)])
                ))
                index += 2
            } else {
                words.append(ReadableWord(
                    text: spokenForm(of: token.text),
                    location: WordLocation(page: page, ranges: [pageRange(token.range)])
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
