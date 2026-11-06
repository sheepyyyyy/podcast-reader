import Testing
@testable import PodcastReaderCore

struct SearchIndexTests {
    /// Each word lasts 1 s, so a word's time equals its index.
    let index = SearchIndex(transcript: Transcript(words:
        "Memory is rebuilt, and memory's strength grows when testing. Don't cram the night before an exam or a test"
            .split(separator: " ")
            .enumerated()
            .map { Word(text: String($1), start: Double($0), end: Double($0) + 1) }
    ))

    @Test func ignoresCase() {
        #expect(index.search("MEMORY").first?.time == 0)
    }

    @Test func ignoresPunctuationInTranscript() {
        #expect(index.search("rebuilt").count == 1)
    }

    @Test func ignoresPunctuationInQuery() {
        #expect(index.search("dont").count == 1)
        #expect(index.search("don't").count == 1)
    }

    @Test func matchesPhraseAcrossWords() {
        let matches = index.search("the night before")
        #expect(matches.count == 1)
        #expect(matches[0].wordRange == 11..<14)
        #expect(matches[0].time == 11)
    }

    @Test func lastQueryWordMatchesAsPrefix() {
        #expect(index.search("test").map(\.time) == [8, 18])
    }

    @Test func earlierQueryWordsMustMatchWhole() {
        #expect(index.search("te cram").isEmpty)
    }

    @Test func contextIncludesFiveWordsEachSide() {
        #expect(index.search("cram")[0].context == "strength grows when testing. Don't cram the night before an exam")
        #expect(index.search("cram")[0].contextRange == 5..<16)
    }

    @Test func noMatchIsEmpty() {
        #expect(index.search("zebra").isEmpty)
    }

    @Test func blankOrPunctuationQueryIsEmpty() {
        #expect(index.search("  ").isEmpty)
        #expect(index.search("?!").isEmpty)
    }
}
