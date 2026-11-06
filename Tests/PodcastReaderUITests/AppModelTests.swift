import Foundation
import PodcastReaderCore
import Testing
@testable import PodcastReaderUI

@MainActor
struct AppModelTests {
    let directory: URL
    let library: Library
    let model: AppModel

    init() throws {
        directory = try makeTemporaryDirectory()
        library = Library(directory: directory.appending(path: "lectures", directoryHint: .isDirectory))
        model = AppModel(library: library, isMuted: true)
    }

    func copyFixture(_ name: String, as newName: String) throws -> URL {
        let url = directory.appending(path: newName)
        try FileManager.default.copyItem(at: fixture(name), to: url)
        return url
    }

    func waitForImportToFinish() async throws {
        try await waitUntil { !model.isImporting }
    }

    var failureMessage: String? {
        if case .failed(let message, _) = model.importState { return message }
        return nil
    }

    var openedLecture: Lecture? {
        if case .reader(let reader) = model.screen { return reader.lecture }
        return nil
    }

    @Test func importTranscribesSavesAndOpens() async throws {
        model.importFile(try copyFixture("sample.mp3", as: "my lecture.mp3"))
        try await waitForImportToFinish()
        let lecture = try #require(openedLecture)
        #expect(lecture.title == "my lecture")
        #expect(lecture.duration > 1)
        #expect(!lecture.transcript.words.isEmpty)
        #expect(library.all().count == 1)
        model.closeReader()
    }

    @Test func importingTheSameAudioAgainKeepsSavedProgress() async throws {
        let url = try copyFixture("sample.mp3", as: "lecture.mp3")
        model.importFile(url)
        try await waitForImportToFinish()
        var saved = try #require(openedLecture)
        model.closeReader()
        saved.position = 5
        try library.save(saved)

        model.importFile(url)
        try await waitForImportToFinish()
        #expect(openedLecture?.position == 5)
        #expect(library.all().count == 1)
        model.closeReader()
    }

    @Test func capitalExtensionIsTheSameLecture() async throws {
        model.importFile(try copyFixture("sample.mp3", as: "lecture.mp3"))
        try await waitForImportToFinish()
        model.closeReader()

        model.importFile(try copyFixture("sample.mp3", as: "renamed.MP3"))
        try await waitForImportToFinish()
        #expect(openedLecture?.title == "lecture")
        #expect(library.all().count == 1)
        model.closeReader()
    }

    @Test func secondFileDuringAnImportIsIgnored() async throws {
        model.importFile(try copyFixture("sample.mp3", as: "first.mp3"))
        model.importFile(try copyFixture("sample.wav", as: "second.wav"))
        try await waitForImportToFinish()
        #expect(library.all().map(\.title) == ["first"])
        model.closeReader()
    }

    @Test func silenceShowsTheNoSpeechMessage() async throws {
        model.importFile(try copyFixture("silence.mp3", as: "silence.mp3"))
        try await waitForImportToFinish()
        #expect(failureMessage == "No speech was found in this file.")
        #expect(library.all().isEmpty)
    }

    @Test func nonAudioShowsTheUnreadableMessage() async throws {
        model.importFile(try copyFixture("notaudio.mp3", as: "notaudio.mp3"))
        try await waitForImportToFinish()
        #expect(failureMessage == "This file couldn't be opened. Try an MP3, M4A, WAV or PDF file.")
        #expect(library.all().isEmpty)
    }

    @Test func unsupportedFormatShowsTheUnreadableMessage() throws {
        model.importFile(URL(fileURLWithPath: "/tmp/notes.txt"))
        #expect(failureMessage == "This file couldn't be opened. Try an MP3, M4A, WAV or PDF file.")
    }

    @Test func missingFileShowsTheUnreadableMessage() async throws {
        model.importFile(directory.appending(path: "gone.mp3"))
        try await waitForImportToFinish()
        #expect(failureMessage == "This file couldn't be opened. Try an MP3, M4A, WAV or PDF file.")
    }

    @Test func cancellingSavesNothing() async throws {
        model.importFile(try copyFixture("sample.mp3", as: "lecture.mp3"))
        model.cancelImport()
        try await waitForImportToFinish()
        if case .idle = model.importState {} else {
            Issue.record("Expected idle after cancelling, got \(model.importState)")
        }
        #expect(library.all().isEmpty)
    }

    @Test func reopeningAtOnceKeepsTheNewestPositionAndBookmarks() async throws {
        model.importFile(try copyFixture("sample.mp3", as: "lecture.mp3"))
        try await waitForImportToFinish()
        model.closeReader()
        try await waitUntil { !model.lectures.isEmpty }

        model.open(model.lectures[0])
        guard case .reader(let reader) = model.screen else {
            Issue.record("Expected the reader to open")
            return
        }
        try await waitUntil { reader.player.duration > 0 }
        reader.player.seek(to: 2.5)
        reader.addBookmark()
        model.closeReader()

        // Straight away, before the list has been reloaded from disk.
        model.open(model.lectures[0])
        #expect(openedLecture?.position == 2.5)
        #expect(openedLecture?.bookmarks.count == 1)
        model.closeReader()

        let saved = try #require(library.all().first)
        #expect(saved.bookmarks.count == 1)
        #expect(saved.position == 2.5)
    }

    @Test func aLectureJustAddedIsListedOnClosing() async throws {
        model.importFile(try copyFixture("sample.mp3", as: "lecture.mp3"))
        try await waitForImportToFinish()
        model.closeReader()
        #expect(model.lectures.map(\.title) == ["lecture"])
    }

    @Test func openingAMissingAudioPDFDuringAnImportExplainsWhy() async throws {
        let pdf = try copyFixture("document.pdf", as: "reading.pdf")
        model.importFile(pdf)
        try await waitForImportToFinish()
        guard case .reader(let reader) = model.screen else {
            Issue.record("Expected the reader to open")
            return
        }
        let lecture = reader.lecture
        model.closeReader()
        try FileManager.default.removeItem(at: library.generatedAudioURL(forID: lecture.id))

        model.importFile(try copyFixture("sample.mp3", as: "other.mp3"))
        model.open(lecture)
        #expect(model.notice == "Finish or cancel the current import first, then open this PDF.")
        try await waitForImportToFinish()
        #expect(model.notice == nil)
        model.closeReader()
    }

    @Test func removingALectureKeepsTheAudio() async throws {
        let url = try copyFixture("sample.mp3", as: "lecture.mp3")
        model.importFile(url)
        try await waitForImportToFinish()
        let lecture = try #require(openedLecture)
        model.closeReader()
        model.remove(lecture)
        #expect(library.all().isEmpty)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test func closingTheReaderStopsAudioAndGoesHome() async throws {
        model.importFile(try copyFixture("sample.mp3", as: "lecture.mp3"))
        try await waitForImportToFinish()
        guard case .reader(let reader) = model.screen else {
            Issue.record("Expected the reader to open")
            return
        }
        reader.player.play()
        model.closeReader()
        #expect(!reader.player.isPlaying)
        if case .home = model.screen {} else {
            Issue.record("Expected the home screen")
        }
    }
}
