import Foundation
import Testing
@testable import PodcastReaderCore

struct SpeechChunkerTests {
    func words(_ count: Int, sentenceEvery: Int? = nil, commaAt: Set<Int> = []) -> [String] {
        (0..<count).map { index in
            if let sentenceEvery, (index + 1) % sentenceEvery == 0 { return "w\(index)." }
            return commaAt.contains(index) ? "w\(index)," : "w\(index)"
        }
    }

    @Test func breaksAtTheFirstSentenceEndAfterTheTarget() {
        let chunks = SpeechChunker.chunks(for: words(100, sentenceEvery: 12), targetWords: 30)
        #expect(chunks.first == 0..<36)
    }

    @Test func aSentenceEndInsideAClosingQuoteCounts() {
        var input = words(40)
        input[31] = "done.\""
        #expect(SpeechChunker.chunks(for: input, targetWords: 30).first == 0..<32)
    }

    @Test func withNoSentenceEndItPrefersACommaBeforeTheCap() {
        let chunks = SpeechChunker.chunks(for: words(100, commaAt: [40]), targetWords: 30)
        #expect(chunks.first == 0..<41)
    }

    @Test func withNoPunctuationItCutsAtTwiceTheTarget() {
        #expect(SpeechChunker.chunks(for: words(100), targetWords: 30).first == 0..<60)
    }

    @Test func everyWordIsCoveredOnceInOrder() {
        let chunks = SpeechChunker.chunks(for: words(1000, sentenceEvery: 17), targetWords: 30)
        #expect(chunks.flatMap { Array($0) } == Array(0..<1000))
    }

    @Test func shortInputIsOneChunk() {
        #expect(SpeechChunker.chunks(for: words(5), targetWords: 30) == [0..<5])
    }

    @Test func emptyInputHasNoChunks() {
        #expect(SpeechChunker.chunks(for: []).isEmpty)
    }
}

struct KokoroTimelineTests {
    func token(_ text: String, _ start: Double?) -> KokoroToken {
        KokoroToken(text: text, start: start, end: start.map { $0 + 0.5 })
    }

    func starts(_ words: [String], _ tokens: [KokoroToken], duration: Double = 10) -> [Double] {
        KokoroTimeline.wordTimes(words: words, tokens: tokens, duration: duration).map(\.start)
    }

    @Test func oneTokenPerWord() {
        #expect(starts(["One", "two"], [token("One", 1), token("two", 2)]) == [1, 2])
    }

    @Test func aSplitWordTakesItsFirstTokensTime() {
        let tokens = [token("A", 1), token("well", 2), token("-", 2.5), token("known", 3), token("idea", 4)]
        #expect(starts(["A", "well-known", "idea"], tokens) == [1, 2, 4])
    }

    @Test func punctuationTokensDontCreateWords() {
        let tokens = [token("Hello", 1), token(",", 1.5), token("there", 2), token(".", 2.5), token("Now", 3)]
        #expect(starts(["Hello,", "there.", "Now"], tokens) == [1, 2, 3])
    }

    @Test func anOpeningQuoteDoesntHideTheWordsTime() {
        let tokens = [token("\"", 0.9), token("Hello", 1), token("\"", 1.5), token("there", 2)]
        #expect(starts(["\"Hello\"", "there"], tokens) == [1, 2])
    }

    @Test func aWordWithNoTimeSharesTheGap() {
        let tokens = [token("One", 1), token("two", nil), token("three", 3)]
        #expect(starts(["One", "two", "three"], tokens) == [1, 2, 3])
    }

    @Test func aTextLengthDifferenceDoesntShiftLaterWordsFar() {
        let words = (0..<100).map { "word\($0)" }
        var tokens = words.enumerated().map { token($1, Double($0)) }
        tokens[0] = token("a much longer first token than the original", 0)
        let result = starts(words, tokens, duration: 100)
        #expect(abs(result[99] - 99) <= 1.5, "last word at \(result[99])")
        #expect(abs(result[50] - 50) <= 2, "middle word at \(result[50])")
    }

    @Test func noTokensSpreadsWordsEvenly() {
        #expect(starts(["One", "two"], [], duration: 4) == [0, 2])
    }

    @Test func everyWordHasItsOwnIncreasingMoment() {
        let tokens = [token("One", 1), token("two", 1), token("three", 0.5), token("four", 3)]
        let result = starts(["One", "two", "three", "four"], tokens)
        #expect(zip(result, result.dropFirst()).allSatisfy { $0 < $1 })
    }

    @Test func theLastWordEndsAtTheEndOfTheAudio() {
        let times = KokoroTimeline.wordTimes(words: ["One"], tokens: [token("One", 1)], duration: 7)
        #expect(times.last?.end == 7)
    }

    @Test func emptyWordsGiveNoTimes() {
        #expect(starts([], [token("One", 1)]).isEmpty)
    }
}

struct TimeRemainingTests {
    @Test func nothingBeforeThereIsEnoughToGoOn() {
        #expect(TimeRemaining.text(elapsed: 5, fraction: 0.01) == nil)
        #expect(TimeRemaining.text(elapsed: 100, fraction: 0) == nil)
        #expect(TimeRemaining.text(elapsed: 100, fraction: 1) == nil)
    }

    @Test func enoughProgressOrEnoughTimeIsEnough() {
        #expect(TimeRemaining.text(elapsed: 5, fraction: 0.05) != nil)
        #expect(TimeRemaining.text(elapsed: 20, fraction: 0.01) != nil)
    }

    @Test func minutes() {
        #expect(TimeRemaining.text(elapsed: 600, fraction: 0.2) == "About 40 minutes left")
        #expect(TimeRemaining.text(elapsed: 60, fraction: 0.5) == "About 1 minute left")
    }

    @Test func hours() {
        #expect(TimeRemaining.text(elapsed: 600, fraction: 600.0 / 4800.0) == "About 1 hour 10 minutes left")
        #expect(TimeRemaining.text(elapsed: 600, fraction: 600.0 / 4200.0) == "About 1 hour left")
        #expect(TimeRemaining.text(elapsed: 600, fraction: 600.0 / 8400.0) == "About 2 hours 10 minutes left")
    }

    @Test func underAMinute() {
        #expect(TimeRemaining.text(elapsed: 90, fraction: 0.9) == "Less than a minute left")
    }

    @Test func startsStayInOrderAcrossChunks() {
        var all = [WordTime(start: 0, end: 1), WordTime(start: 1.001, end: 1.5)]
        KokoroTimeline.append([WordTime(start: 0, end: 0.2), WordTime(start: 0.2, end: 0.4)], startingAt: 1, to: &all)
        #expect(zip(all, all.dropFirst()).allSatisfy { $0.start < $1.start })
        #expect(all.allSatisfy { $0.end >= $0.start })
        #expect(all[3].start == 1.2)
    }
}
