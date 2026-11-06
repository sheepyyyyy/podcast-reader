import Testing
@testable import PodcastReaderCore

struct WordClockTests {
    let clock = WordClock(words: [
        Word(text: "a", start: 1, end: 2),
        Word(text: "b", start: 2, end: 3),
        Word(text: "c", start: 10, end: 11),
    ])

    @Test func beforeFirstWordIsNil() {
        #expect(clock.activeWordIndex(at: 0.5) == nil)
    }

    @Test func onBoundaryIsTheNewWord() {
        #expect(clock.activeWordIndex(at: 2) == 1)
    }

    @Test func inPauseKeepsLastSpokenWord() {
        #expect(clock.activeWordIndex(at: 6) == 1)
    }

    @Test func afterLastWordKeepsLastWord() {
        #expect(clock.activeWordIndex(at: 500) == 2)
    }

    @Test func emptyIsNil() {
        #expect(WordClock(words: []).activeWordIndex(at: 1) == nil)
    }
}
