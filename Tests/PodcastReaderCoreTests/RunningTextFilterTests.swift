import Testing
@testable import PodcastReaderCore

struct RunningTextFilterTests {
    func line(_ page: Int, _ text: String, _ position: Double) -> MarginLine {
        MarginLine(page: page, text: text, verticalPosition: position)
    }

    @Test func bareNumbersInTheMarginAreSkipped() {
        let lines = [line(0, "12", 0.96), line(1, "Page 13", 0.96)]
        #expect(RunningTextFilter.skippedLines(in: lines) == Set(lines))
    }

    @Test func numbersInTheBodyAreKept() {
        #expect(RunningTextFilter.skippedLines(in: [line(0, "12", 0.5)]).isEmpty)
    }

    @Test func textRepeatedOnThreePagesIsSkipped() {
        let lines = (0..<3).map { line($0, "Chapter 4: How memory works", 0.03) }
        #expect(RunningTextFilter.skippedLines(in: lines).count == 3)
    }

    @Test func textRepeatedOnTwoPagesIsKept() {
        let lines = (0..<2).map { line($0, "Chapter 4", 0.03) }
        #expect(RunningTextFilter.skippedLines(in: lines).isEmpty)
    }

    @Test func repeatsOnOnePageDoNotCount() {
        let lines = (0..<3).map { line(0, "Note", 0.03 + Double($0) * 0.01) }
        #expect(RunningTextFilter.skippedLines(in: lines).isEmpty)
    }

    @Test func repeatsIgnoreDigitsAndCase() {
        let lines = [line(0, "Lecture 1 notes", 0.03), line(1, "LECTURE 2 NOTES", 0.03), line(2, "Lecture 3 notes", 0.03)]
        #expect(RunningTextFilter.skippedLines(in: lines).count == 3)
    }

    /// A long document, with a line of body text on every page.
    func bodyLines(pages: Int) -> [MarginLine] {
        (0..<pages).map { line($0, "Body text", 0.5) }
    }

    @Test func chapterTitlesInALongDocumentAreKept() {
        let titles = [line(10, "Chapter 1", 0.05), line(40, "Chapter 2", 0.05), line(70, "Chapter 3", 0.05)]
        #expect(RunningTextFilter.skippedLines(in: bodyLines(pages: 100) + titles).isEmpty)
    }

    @Test func figureAndTableLabelsInALongDocumentAreKept() {
        let labels = [line(1, "Figure 1", 0.95), line(5, "Figure 2", 0.95), line(9, "Figure 3", 0.95), line(12, "Figure 4", 0.95)]
        #expect(RunningTextFilter.skippedLines(in: bodyLines(pages: 100) + labels).isEmpty)
    }

    @Test func runningHeadsWithChangingNumbersAreSkipped() {
        let heads = (0..<50).map { line($0 * 2, "Smith et al. \($0 * 2 + 100)", 0.03) }
        #expect(RunningTextFilter.skippedLines(in: bodyLines(pages: 100) + heads).count == 50)
    }

    @Test func exactRepeatsAreSkippedEvenWhenRare() {
        let heads = (0..<4).map { line($0 * 20, "Part Two: Methods", 0.03) }
        #expect(RunningTextFilter.skippedLines(in: bodyLines(pages: 100) + heads).count == 4)
    }

    @Test func repeatsInTheBodyAreKept() {
        let lines = (0..<4).map { line($0, "Key idea", 0.5) }
        #expect(RunningTextFilter.skippedLines(in: lines).isEmpty)
    }

    @Test func marginsAreTheOuterTenPercent() {
        #expect(RunningTextFilter.skippedLines(in: [line(0, "7", 0.11)]).isEmpty)
        #expect(RunningTextFilter.skippedLines(in: [line(0, "7", 0.09)]).count == 1)
        #expect(RunningTextFilter.skippedLines(in: [line(0, "7", 0.91)]).count == 1)
    }
}
