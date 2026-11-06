import Testing
@testable import PodcastReaderCore

struct SpeechTimelineTests {
    /// 4 bytes per frame at 100 frames a second, so 400 bytes is one second.
    /// Each marker is its text location, its byte offset and its chunk.
    func times(_ markers: [(Int, Int, Int)], offsets: [Int], chunks: [Int64] = [0], total: Int64 = 1000) -> [WordTime] {
        SpeechTimeline.wordTimes(
            wordOffsets: offsets,
            markers: markers.map { SpeechMarker(textLocation: $0.0, byteOffset: $0.1, chunk: $0.2) },
            chunkStartFrames: chunks,
            bytesPerFrame: 4,
            sampleRate: 100,
            totalFrames: total
        )
    }

    @Test func offsetsAreBytesPerFrame() {
        #expect(times([(0, 0, 0), (5, 400, 0)], offsets: [0, 5]).map(\.start) == [0, 1])
    }

    @Test func timesAccumulateAcrossChunks() {
        let result = times([(0, 0, 0), (5, 400, 0), (9, 0, 1), (14, 400, 1)], offsets: [0, 5, 9, 14], chunks: [0, 300])
        #expect(result.map(\.start) == [0, 1, 3, 4])
    }

    @Test func aChunkOfOneWordStillStartsANewChunk() {
        let result = times([(0, 0, 0), (5, 0, 1), (9, 0, 2)], offsets: [0, 5, 9], chunks: [0, 200, 500])
        #expect(result.map(\.start) == [0, 2, 5])
    }

    @Test func equalOffsetsInAChunkShareTheTimeToTheNextWord() {
        let result = times([(0, 0, 0), (5, 400, 0), (8, 400, 0), (12, 800, 0)], offsets: [0, 5, 8, 12], chunks: [0, 1000])
        #expect(result.map(\.start) == [0, 1, 1.5, 2])
    }

    @Test func anEmptyChunkDoesNotShiftLaterWords() {
        let result = times([(0, 0, 0), (5, 0, 2)], offsets: [0, 5], chunks: [0, 100, 100])
        #expect(result.map(\.start) == [0, 1])
    }

    @Test func aWordEndsWhereTheNextStarts() {
        #expect(times([(0, 0, 0), (5, 400, 0)], offsets: [0, 5]).first?.end == 1)
    }

    @Test func theLastWordEndsAtTheEndOfTheAudio() {
        #expect(times([(0, 0, 0)], offsets: [0], total: 800).last?.end == 8)
    }

    @Test func aWordWithNoMarkerSharesTheGapEvenly() {
        let result = times([(0, 0, 0), (10, 800, 0)], offsets: [0, 5, 10])
        #expect(result.map(\.start) == [0, 1, 2])
    }

    @Test func wordsBeforeTheFirstMarkerStartAtZero() {
        #expect(times([(5, 400, 0)], offsets: [0, 5]).first?.start == 0)
    }

    @Test func wordsAfterTheLastMarkerShareTheRemainingTime() {
        let result = times([(0, 0, 0)], offsets: [0, 5, 10], total: 300)
        #expect(result.map(\.start) == [0, 1, 2])
        #expect(result.last?.end == 3)
    }

    @Test func aMarkerInsideAWordCountsForThatWord() {
        #expect(times([(0, 0, 0), (7, 400, 0)], offsets: [0, 5]).map(\.start) == [0, 1])
    }

    @Test func noMarkersAtAllSpreadsWordsEvenly() {
        #expect(times([], offsets: [0, 5], total: 400).map(\.start) == [0, 2])
    }

    @Test func everyWordGetsItsOwnMoment() {
        let backward = times([(0, 0, 0), (5, 800, 0), (9, 0, 1), (14, 400, 1)], offsets: [0, 5, 9, 14], chunks: [0, 100])
        #expect(zip(backward, backward.dropFirst()).allSatisfy { $0.start < $1.start })
        #expect(backward.allSatisfy { $0.end >= $0.start })

        let noAudio = times([(0, 0, 0)], offsets: [0, 5, 10], total: 0)
        #expect(zip(noAudio, noAudio.dropFirst()).allSatisfy { $0.start < $1.start })
    }

    @Test func emptyWordsGiveNoTimes() {
        #expect(times([], offsets: []).isEmpty)
    }

    @Test func spokenTextIsWordsJoinedBySpaces() {
        let (text, offsets) = SpeechTimeline.spokenText(for: ["One", "two."])
        #expect(text == "One two.")
        #expect(offsets == [0, 4])
    }

    @Test func spokenTextOffsetsAreUTF16() {
        let (_, offsets) = SpeechTimeline.spokenText(for: ["😀", "two"])
        #expect(offsets == [0, 3])
    }
}
