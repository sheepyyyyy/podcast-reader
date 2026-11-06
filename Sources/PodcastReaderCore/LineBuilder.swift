import Foundation

/// Groups words into caption lines, using the rules from the design spec.
public enum LineBuilder {
    private static let pauseThreshold: TimeInterval = 0.7
    private static let softBreakMinimum = 6
    private static let hardMaximum = 12

    private static let closingMarks = CharacterSet(charactersIn: "\"'”’)]")

    public static func lines(for words: [Word]) -> [Line] {
        var lines: [Line] = []
        var lineStart = 0

        for index in words.indices.dropFirst() {
            if startsNewLine(at: index, lineStart: lineStart, words: words) {
                lines.append(Line(id: lines.count, wordRange: lineStart..<index))
                lineStart = index
            }
        }
        if !words.isEmpty {
            lines.append(Line(id: lines.count, wordRange: lineStart..<words.count))
        }
        return lines
    }

    private static func startsNewLine(at index: Int, lineStart: Int, words: [Word]) -> Bool {
        let previous = words[index - 1]
        let wordsInLine = index - lineStart
        let ending = previous.text.trimmingCharacters(in: closingMarks).last

        if let ending, ".?!".contains(ending) { return true }
        if words[index].start - previous.end > pauseThreshold + 1e-9 { return true }
        if wordsInLine >= softBreakMinimum, let ending, ",:;".contains(ending) { return true }
        return wordsInLine >= hardMaximum
    }
}
