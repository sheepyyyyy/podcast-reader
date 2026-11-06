import Testing
@testable import PodcastReaderCore

struct DocumentWordIndexTests {
    let index = DocumentWordIndex(locations: [
        WordLocation(page: 0, ranges: [PageTextRange(location: 10, length: 5)]),
        WordLocation(page: 0, ranges: [PageTextRange(location: 16, length: 3), PageTextRange(location: 25, length: 8)]),
        WordLocation(page: 2, ranges: [PageTextRange(location: 0, length: 4)]),
    ])

    @Test func findsAWord() {
        #expect(index.wordIndex(page: 0, character: 12) == 0)
        #expect(index.wordIndex(page: 2, character: 1) == 2)
    }

    @Test func wordEdges() {
        #expect(index.wordIndex(page: 0, character: 10) == 0)
        #expect(index.wordIndex(page: 0, character: 14) == 0)
        #expect(index.wordIndex(page: 0, character: 15) == nil)
    }

    @Test func gapsAndSkippedTextAreNil() {
        #expect(index.wordIndex(page: 0, character: 3) == nil)
        #expect(index.wordIndex(page: 0, character: 20) == nil)
        #expect(index.wordIndex(page: 0, character: 500) == nil)
    }

    @Test func bothPartsOfAHyphenatedWordMatch() {
        #expect(index.wordIndex(page: 0, character: 17) == 1)
        #expect(index.wordIndex(page: 0, character: 30) == 1)
    }

    @Test func unknownPageIsNil() {
        #expect(index.wordIndex(page: 1, character: 0) == nil)
    }

    @Test func anUnknownCharacterIsNil() {
        #expect(index.wordIndex(page: 0, character: -1) == nil)
    }
}
