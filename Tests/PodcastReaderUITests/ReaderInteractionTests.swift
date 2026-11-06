import Foundation
import PodcastReaderCore
import Testing
@testable import PodcastReaderUI

/// Controls, keyboard commands, full screen, search, bookmarks and saving.
@MainActor
struct ReaderInteractionTests {
    let library: Library
    let lecture: Lecture

    init() throws {
        let directory = try makeTemporaryDirectory()
        library = Library(directory: directory.appending(path: "lectures", directoryHint: .isDirectory))
        let words = ["Memory", "works.", "Testing", "yourself", "makes", "memory", "stronger", "today."]
            .enumerated()
            .map { index, text in Word(text: text, start: Double(index) + 1, end: Double(index) + 2) }
        lecture = try library.makeLecture(
            audioAt: fixture("sample.mp3"),
            transcript: Transcript(words: words),
            duration: 8
        )
        try library.save(lecture)
    }

    func makeReader(
        from lecture: Lecture? = nil,
        fadeDelay: TimeInterval = 3,
        saveInterval: TimeInterval = 5
    ) async throws -> ReaderModel {
        let reader = ReaderModel(
            lecture: lecture ?? self.lecture,
            audioURL: fixture("sample.mp3"),
            library: library,
            isMuted: true,
            controlsFadeDelay: fadeDelay,
            saveInterval: saveInterval
        )
        try await reader.start()
        return reader
    }

    // MARK: Commands

    @Test func togglePlayCommandPlaysAndPauses() async throws {
        let reader = try await makeReader()
        reader.perform(.togglePlay)
        #expect(reader.player.isPlaying)
        reader.perform(.togglePlay)
        #expect(!reader.player.isPlaying)
    }

    @Test func skipCommandMovesPlaybackAndStopsAtTheStart() async throws {
        let reader = try await makeReader()
        reader.perform(.skip(30))
        let afterForward = reader.player.currentTime
        #expect(afterForward == reader.player.duration)
        reader.perform(.skip(-5))
        #expect(abs(reader.player.currentTime - max(afterForward - 5, 0)) < 0.001)
        reader.perform(.skip(-30))
        #expect(reader.player.currentTime == 0)
    }

    @Test func speedButtonCyclesWithoutStartingPlayback() async throws {
        let reader = try await makeReader()
        reader.cycleSpeed()
        #expect(reader.player.rate == 1.25)
        #expect(!reader.player.isPlaying)
    }

    // MARK: Real input

    @Test func spaceTypesIntoAFocusedSearchField() async throws {
        let reader = try await makeReader()
        reader.openPanel(.search)
        reader.isSearchFieldFocused = true
        #expect(!reader.handleKey(keyCode: 49, modifiers: [], responderIsTextView: false))
        #expect(!reader.player.isPlaying)
    }

    @Test func leftoverSearchFocusOnTheBookmarksTabDoesNotSwallowKeys() async throws {
        let reader = try await makeReader()
        reader.openPanel(.search)
        reader.isSearchFieldFocused = true
        reader.openPanel(.bookmarks)
        #expect(reader.handleKey(keyCode: 49, modifiers: [], responderIsTextView: true))
        #expect(reader.player.isPlaying)
        reader.close()
    }

    @Test func spaceTypesWhenTheResponderIsATextView() async throws {
        let reader = try await makeReader()
        reader.openPanel(.search)
        #expect(!reader.handleKey(keyCode: 49, modifiers: [], responderIsTextView: true))
        #expect(!reader.player.isPlaying)
    }

    @Test func bookmarkingAVeryLongDocumentDoesNotHoldUpTheHighlight() async throws {
        let words = (0..<120_000).map { Word(text: "word\($0)", start: Double($0) * 0.0001, end: Double($0 + 1) * 0.0001) }
        var long = try library.makeLecture(audioAt: fixture("sample.mp3"), transcript: Transcript(words: words), duration: 8)
        long.document = DocumentInfo(
            voiceName: "Samantha",
            pageCount: 300,
            locations: words.indices.map { WordLocation(page: $0 / 400, ranges: [PageTextRange(location: $0, length: 5)]) }
        )
        let reader = try await makeReader(from: long)
        reader.player.seek(to: 4)

        let start = Date()
        reader.addBookmark()
        #expect(Date().timeIntervalSince(start) < 0.03)

        reader.finishSaving()
        #expect(try library.load(id: long.id)?.bookmarks.count == 1)
        reader.close()
    }

    @Test func aClosedReaderLeavesKeysForWhateverComesNext() async throws {
        let reader = try await makeReader()
        reader.close()
        #expect(!reader.handleKey(keyCode: 49, modifiers: [], responderIsTextView: false))
        #expect(!reader.player.isPlaying)
    }

    @Test func aLeftoverTextCursorAfterClosingThePanelDoesNotSwallowKeys() async throws {
        let reader = try await makeReader()
        reader.openPanel(.search)
        reader.closePanel()
        #expect(reader.handleKey(keyCode: 49, modifiers: [], responderIsTextView: true))
        #expect(reader.player.isPlaying)
        reader.close()
    }

    @Test func spaceControlsPlaybackWhenNotTyping() async throws {
        let reader = try await makeReader()
        #expect(reader.handleKey(keyCode: 49, modifiers: [], responderIsTextView: false))
        #expect(reader.player.isPlaying)
        reader.close()
    }

    @Test func wheelOverCaptionsStopsFollowing() async throws {
        let reader = try await makeReader()
        reader.noteScrollWheel(x: 100, windowWidth: 1000)
        #expect(!reader.isFollowing)
    }

    @Test func wheelOverCaptionsBesideThePanelStopsFollowing() async throws {
        let reader = try await makeReader()
        reader.openPanel(.search)
        reader.noteScrollWheel(x: 500, windowWidth: 1000)
        #expect(!reader.isFollowing)
    }

    @Test func wheelOverThePanelKeepsFollowing() async throws {
        let reader = try await makeReader()
        reader.openPanel(.search)
        reader.noteScrollWheel(x: 900, windowWidth: 1000)
        #expect(reader.isFollowing)
    }

    // MARK: Fading controls

    @Test func controlsStayVisibleInAWindow() async throws {
        let reader = try await makeReader(fadeDelay: 0.05)
        reader.noteMouseMoved()
        try await Task.sleep(for: .milliseconds(200))
        #expect(reader.controlsVisible)
    }

    @Test func controlsFadeInFullScreenAndReturnWithTheMouse() async throws {
        let reader = try await makeReader(fadeDelay: 0.05)
        reader.setFullScreen(true)
        #expect(reader.controlsVisible)
        try await waitUntil { !reader.controlsVisible }
        #expect(!reader.controlsVisible)
        reader.noteMouseMoved()
        #expect(reader.controlsVisible)
    }

    @Test func leavingFullScreenBringsControlsBack() async throws {
        let reader = try await makeReader(fadeDelay: 0.05)
        reader.setFullScreen(true)
        try await waitUntil { !reader.controlsVisible }
        reader.setFullScreen(false)
        #expect(reader.controlsVisible)
        try await Task.sleep(for: .milliseconds(200))
        #expect(reader.controlsVisible)
    }

    // MARK: Side panel

    @Test func panelCommandsOpenAndClose() async throws {
        let reader = try await makeReader()
        reader.perform(.openSearch)
        #expect(reader.panel == .search)
        reader.perform(.openBookmarks)
        #expect(reader.panel == .bookmarks)
        reader.perform(.closePanel)
        #expect(reader.panel == nil)
    }

    @Test func escapeOnlyCountsAsHandledWhenAPanelIsOpen() async throws {
        let reader = try await makeReader()
        #expect(!reader.handlesClosePanel)
        reader.openPanel(.search)
        #expect(reader.handlesClosePanel)
    }

    // MARK: Search

    @Test func searchFindsEveryPlaceAWordWasSaid() async throws {
        let reader = try await makeReader()
        reader.query = "memory"
        try await waitUntil(upTo: 3) { !reader.matches.isEmpty }
        #expect(reader.matches.map(\.time) == [1, 6])
    }

    @Test func changingTheQueryReplacesResults() async throws {
        let reader = try await makeReader()
        reader.query = "memory"
        try await waitUntil(upTo: 3) { reader.matches.count == 2 }
        reader.query = "stronger"
        try await waitUntil(upTo: 3) { reader.matches.count == 1 }
        #expect(reader.matches.first?.time == 7)
        reader.query = ""
        try await waitUntil(upTo: 3) { reader.matches.isEmpty }
        #expect(reader.matches.isEmpty)
    }

    @Test func choosingAResultJumpsThereAndFollows() async throws {
        let reader = try await makeReader()
        reader.isFollowing = false
        reader.jump(toWord: 5)
        #expect(reader.player.currentTime == 6)
        #expect(reader.isFollowing)
    }

    // MARK: Bookmarks

    @Test func addingABookmarkMarksTheCurrentWordAndSaves() async throws {
        let reader = try await makeReader()
        reader.player.seek(to: 4.5)
        reader.addBookmark()
        #expect(reader.lecture.bookmarks.map(\.wordIndex) == [3])
        #expect(reader.toast == "Bookmarked")
        reader.finishSaving()
        #expect(try library.load(id: lecture.id)?.bookmarks.map(\.wordIndex) == [3])
    }

    @Test func bookmarkingTheSameWordTwiceAddsOne() async throws {
        let reader = try await makeReader()
        reader.player.seek(to: 4.5)
        reader.addBookmark()
        reader.addBookmark()
        #expect(reader.lecture.bookmarks.count == 1)
    }

    @Test func bookmarkBeforeTheFirstWordMarksTheFirstWord() async throws {
        let reader = try await makeReader()
        reader.perform(.addBookmark)
        #expect(reader.lecture.bookmarks.map(\.wordIndex) == [0])
    }

    @Test func removingABookmarkSaves() async throws {
        let reader = try await makeReader()
        reader.addBookmark()
        let id = try #require(reader.lecture.bookmarks.first?.id)
        reader.removeBookmark(id: id)
        #expect(reader.lecture.bookmarks.isEmpty)
        reader.finishSaving()
        #expect(try library.load(id: lecture.id)?.bookmarks.isEmpty == true)
    }

    @Test func toastGoesAway() async throws {
        let reader = ReaderModel(
            lecture: lecture,
            audioURL: fixture("sample.mp3"),
            library: library,
            isMuted: true,
            toastDuration: 0.05
        )
        try await reader.start()
        reader.addBookmark()
        #expect(reader.toast != nil)
        try await waitUntil { reader.toast == nil }
        #expect(reader.toast == nil)
    }

    // MARK: Saving and resuming

    @Test func resumesAtTheSavedPositionPaused() async throws {
        var saved = lecture
        saved.position = 3.5
        let reader = try await makeReader(from: saved)
        #expect(reader.player.currentTime == 3.5)
        #expect(!reader.player.isPlaying)
        #expect(reader.activeWord == 2)
    }

    @Test func pausingSavesThePosition() async throws {
        let reader = try await makeReader()
        reader.togglePlay()
        reader.player.seek(to: 4)
        reader.togglePlay()
        reader.finishSaving()
        #expect(try library.load(id: lecture.id)?.position == 4)
    }

    @Test func closingSavesThePosition() async throws {
        let reader = try await makeReader()
        reader.player.seek(to: 2.5)
        reader.close()
        #expect(try library.load(id: lecture.id)?.position == 2.5)
    }

    @Test func closingBeforeTheAudioLoadsKeepsTheSavedPosition() throws {
        var saved = lecture
        saved.position = 3.5
        try library.save(saved)
        let reader = ReaderModel(lecture: saved, audioURL: fixture("sample.mp3"), library: library, isMuted: true)
        reader.close()
        #expect(try library.load(id: lecture.id)?.position == 3.5)
    }

    @Test func escapeWithNoPanelIsLeftForTheSystem() async throws {
        let reader = try await makeReader()
        #expect(!reader.handle(.closePanel))
        reader.openPanel(.bookmarks)
        #expect(reader.handle(.closePanel))
        #expect(reader.panel == nil)
    }

    @Test func playingSavesPeriodically() async throws {
        let reader = try await makeReader(saveInterval: 0.05)
        reader.togglePlay()
        var saved = 0.0
        try await waitUntil(upTo: 3) {
            saved = (try? library.load(id: lecture.id)?.position) ?? 0
            return saved > 0
        }
        #expect(saved > 0)
        reader.close()
    }
}

/// Moved and missing audio files.
@MainActor
struct MissingAudioTests {
    let directory: URL
    let library: Library
    let model: AppModel

    init() throws {
        directory = try makeTemporaryDirectory()
        library = Library(directory: directory.appending(path: "lectures", directoryHint: .isDirectory))
        model = AppModel(library: library, isMuted: true)
    }

    func addLecture() throws -> (Lecture, URL) {
        let audio = directory.appending(path: "lecture.mp3")
        try FileManager.default.copyItem(at: fixture("sample.mp3"), to: audio)
        let words = [Word(text: "Hello", start: 0, end: 1)]
        let lecture = try library.makeLecture(audioAt: audio, transcript: Transcript(words: words), duration: 8)
        try library.save(lecture)
        return (lecture, audio)
    }

    @Test func deletedAudioShowsTheLocatePrompt() throws {
        let (lecture, audio) = try addLecture()
        try FileManager.default.removeItem(at: audio)
        model.open(lecture)
        guard case .missingAudio(let missing, let message) = model.screen else {
            Issue.record("Expected the locate prompt")
            return
        }
        #expect(missing.id == lecture.id)
        #expect(message == nil)
    }

    @Test func locatingADifferentFileIsRefused() throws {
        let (lecture, audio) = try addLecture()
        try FileManager.default.removeItem(at: audio)
        model.open(lecture)
        model.locateAudio(for: lecture, at: fixture("sample.wav"))
        guard case .missingAudio(_, let message) = model.screen else {
            Issue.record("Expected to stay on the locate prompt")
            return
        }
        #expect(message == "That's a different file from this lecture. Choose the original audio.")
    }

    @Test func locatingTheOriginalOpensWithBookmarksIntact() throws {
        let (added, audio) = try addLecture()
        var lecture = added
        _ = lecture.addBookmark(wordIndex: 0)
        try library.save(lecture)
        let moved = directory.appending(path: "new home.mp3")
        try FileManager.default.copyItem(at: audio, to: moved)
        try FileManager.default.removeItem(at: audio)
        model.open(lecture)
        model.locateAudio(for: lecture, at: moved)
        guard case .reader(let reader) = model.screen else {
            Issue.record("Expected the reader to open")
            return
        }
        #expect(reader.lecture.bookmarks.count == 1)
        #expect(try library.load(id: lecture.id)?.filePath == moved.path)
        model.closeReader()
    }
}
