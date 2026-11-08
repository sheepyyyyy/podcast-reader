import Foundation
import PodcastReaderCore
import Testing
@testable import PodcastReaderUI

@MainActor
struct ReaderModelTests {
    /// Eight one-second words: two lines, split after "two."
    func makeReader() async throws -> ReaderModel {
        let directory = try makeTemporaryDirectory()
        let library = Library(directory: directory.appending(path: "lectures", directoryHint: .isDirectory))
        let words = ["One", "two.", "Three", "four", "five", "six", "seven", "eight"].enumerated().map { index, text in
            Word(text: text, start: Double(index), end: Double(index) + 1)
        }
        let audio = fixture("sample.mp3")
        let lecture = try library.makeLecture(audioAt: audio, transcript: Transcript(words: words), duration: 8)
        try library.save(lecture)
        let reader = ReaderModel(lecture: lecture, audioURL: audio, library: library, isMuted: true)
        try await reader.start()
        return reader
    }

    @Test func nothingIsActiveBeforeTheFirstWord() async throws {
        let reader = try await makeReader()
        reader.player.seek(to: 0)
        #expect(reader.activeWord == 0)
        let empty = try makeTemporaryDirectory()
        let library = Library(directory: empty)
        let late = [Word(text: "late", start: 5, end: 6)]
        let lecture = try library.makeLecture(audioAt: fixture("sample.mp3"), transcript: Transcript(words: late), duration: 8)
        let other = ReaderModel(lecture: lecture, audioURL: fixture("sample.mp3"), library: library, isMuted: true)
        try await other.start()
        #expect(other.activeWord == nil)
        #expect(other.activeLine == nil)
    }

    @Test func activeWordAndLineFollowPlaybackTime() async throws {
        let reader = try await makeReader()
        reader.player.seek(to: 4.5)
        #expect(reader.activeWord == 4)
        #expect(reader.activeLine == 1)
    }

    /// The highlight moves when each word starts, rather than at the next routine tick,
    /// because the reader asks the player to wake it then. That the player does so on time
    /// is checked in the player's own tests.
    @Test func theReaderAsksToWakeAtTheNextWord() async throws {
        let reader = try await makeReader()
        reader.player.seek(to: 2.5)
        #expect(reader.player.requestedTick == 3)
        reader.player.seek(to: 7.5)
        #expect(reader.player.requestedTick == nil)
        reader.setOnScreen(false)
        reader.player.seek(to: 0.5)
        #expect(reader.player.requestedTick == nil)
        reader.setOnScreen(true)
        #expect(reader.player.requestedTick == 1)
    }

    @Test func theHighlightWaitsWhileNoOneCanSeeIt() async throws {
        let reader = try await makeReader()
        reader.setOnScreen(false)
        reader.player.seek(to: 4.5)
        #expect(reader.activeWord == 0)
        reader.addBookmark()
        #expect(reader.lecture.bookmarks.map(\.wordIndex) == [4])
        reader.setOnScreen(true)
        #expect(reader.activeWord == 4)
    }

    @Test func jumpSeeksToTheWordAndStaysPaused() async throws {
        let reader = try await makeReader()
        reader.jump(toWord: 3)
        #expect(reader.player.currentTime == 3)
        #expect(reader.activeWord == 3)
        #expect(!reader.player.isPlaying)
    }

    @Test func jumpWhilePlayingKeepsPlaying() async throws {
        let reader = try await makeReader()
        reader.player.play()
        reader.jump(toWord: 3)
        #expect(reader.player.isPlaying)
        reader.close()
    }

    @Test func jumpTurnsFollowingBackOn() async throws {
        let reader = try await makeReader()
        reader.isFollowing = false
        reader.jump(toWord: 1)
        #expect(reader.isFollowing)
    }

    @Test func backToNowTurnsFollowingBackOn() async throws {
        let reader = try await makeReader()
        reader.isFollowing = false
        reader.backToNow()
        #expect(reader.isFollowing)
    }

    @Test func closeStopsTheAudio() async throws {
        let reader = try await makeReader()
        reader.player.play()
        reader.close()
        #expect(!reader.player.isPlaying)
    }

    @Test func aMissingWordIndexIsIgnored() async throws {
        let reader = try await makeReader()
        reader.jump(toWord: 999)
        #expect(reader.player.currentTime == 0)
    }
}
