import Testing
@testable import PodcastReaderCore

struct LineBuilderTests {
    /// Words 0.3 s long, 0.1 s apart.
    func make(_ texts: [String]) -> [Word] {
        texts.enumerated().map { index, text in
            let start = Double(index) * 0.4
            return Word(text: text, start: start, end: start + 0.3)
        }
    }

    func sizes(_ words: [Word]) -> [Int] {
        LineBuilder.lines(for: words).map(\.wordRange.count)
    }

    @Test func breaksAfterSentenceEnd() {
        #expect(sizes(make(["Hello", "world.", "Next"])) == [2, 1])
    }

    @Test func breaksAfterQuestionAndExclamation() {
        #expect(sizes(make(["Why?", "Stop!", "Go"])) == [1, 1, 1])
    }

    @Test func breaksAfterPeriodInsideClosingQuote() {
        #expect(sizes(make(["He", "said", "done.\"", "Then"])) == [3, 1])
    }

    @Test func decimalDoesNotBreak() {
        #expect(sizes(make(["About", "3.5", "percent"])) == [3])
    }

    @Test func pauseOver0_7Breaks() {
        let words = [Word(text: "a", start: 0, end: 1), Word(text: "b", start: 1.71, end: 2)]
        #expect(LineBuilder.lines(for: words).count == 2)
    }

    @Test func pauseOfExactly0_7DoesNotBreak() {
        let words = [Word(text: "a", start: 0, end: 1), Word(text: "b", start: 1.7, end: 2)]
        #expect(LineBuilder.lines(for: words).count == 1)
    }

    @Test func commaBreaksAtSixWords() {
        #expect(sizes(make(["1", "2", "3", "4", "5", "6,", "7"])) == [6, 1])
    }

    @Test func commaIgnoredBeforeSixWords() {
        #expect(sizes(make(["1", "2", "3", "4", "5,", "6", "7"])) == [7])
    }

    @Test func colonAndSemicolonBreakAtSixWords() {
        #expect(sizes(make(["1", "2", "3", "4", "5", "6:", "7", "8", "9", "10", "11", "12;", "13"])) == [6, 6, 1])
    }

    @Test func hardCapAtTwelve() {
        #expect(sizes(make((1...30).map(String.init))) == [12, 12, 6])
    }

    @Test func emptyInput() {
        #expect(LineBuilder.lines(for: []).isEmpty)
    }

    @Test func linesCoverEveryWordOnce() {
        let transcript = Transcript(words: make(["One.", "Two", "three,", "four.", "Five"]))
        #expect(transcript.lines.flatMap { Array($0.wordRange) } == Array(0..<5))
        #expect(transcript.lines.map(\.id) == Array(0..<transcript.lines.count))
        #expect(transcript.lineIndex(forWord: 2) == 1)
        #expect(transcript.text(ofLine: 1) == "Two three, four.")
    }
}
