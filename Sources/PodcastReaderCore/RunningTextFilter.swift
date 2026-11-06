import Foundation

/// A line of text on a PDF page.
public struct MarginLine: Hashable, Sendable {
    public let page: Int
    public let text: String
    /// 0 at the top of the page, 1 at the bottom.
    public let verticalPosition: Double

    public init(page: Int, text: String, verticalPosition: Double) {
        self.page = page
        self.text = text
        self.verticalPosition = verticalPosition
    }
}

/// Decides which lines are repeated headers, footers or page numbers, so they aren't read aloud.
public enum RunningTextFilter {
    private static let marginFraction = 0.10
    private static let repeatedPageMinimum = 3
    /// Text that differs only by its numbers, like "Smith et al. 104", must be on this share
    /// of pages to count as a running head. Otherwise "Chapter 1", "Chapter 2" and "Figure 3"
    /// at the top of a page would silently go unread.
    private static let changingNumberPageShare = 0.25

    public static func skippedLines(in lines: [MarginLine]) -> Set<MarginLine> {
        let pageCount = Set(lines.map(\.page)).count
        let marginLines = lines.filter { $0.verticalPosition < marginFraction || $0.verticalPosition > 1 - marginFraction }

        var pagesByExactText: [String: Set<Int>] = [:]
        var pagesByTextWithoutNumbers: [String: Set<Int>] = [:]
        for line in marginLines {
            pagesByExactText[exactText(line.text), default: []].insert(line.page)
            pagesByTextWithoutNumbers[textWithoutNumbers(line.text), default: []].insert(line.page)
        }

        return Set(marginLines.filter { line in
            if isPageNumber(line.text) { return true }
            if (pagesByExactText[exactText(line.text)]?.count ?? 0) >= repeatedPageMinimum { return true }

            let withoutNumbers = textWithoutNumbers(line.text)
            let pages = pagesByTextWithoutNumbers[withoutNumbers]?.count ?? 0
            return !withoutNumbers.isEmpty
                && pages >= repeatedPageMinimum
                && Double(pages) >= Double(pageCount) * changingNumberPageShare
        })
    }

    private static func isPageNumber(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .range(of: #"^(page\s*)?\d+$"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func exactText(_ text: String) -> String {
        text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Digits removed, so "Lecture 1" and "LECTURE 2" count as the same text.
    private static func textWithoutNumbers(_ text: String) -> String {
        exactText(text.filter { !$0.isNumber })
    }
}
