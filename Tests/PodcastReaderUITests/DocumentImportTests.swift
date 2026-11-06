import Foundation
import PodcastReaderCore
import Testing
@testable import PodcastReaderUI

@MainActor
struct DocumentImportTests {
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

    func waitForImport() async throws {
        try await waitUntil { !model.isImporting }
    }

    var failureMessage: String? {
        if case .failed(let message, _) = model.importState { return message }
        return nil
    }

    var openReader: ReaderModel? {
        if case .reader(let reader) = model.screen { return reader }
        return nil
    }

    func importDocument(as name: String = "reading.pdf") async throws -> (ReaderModel, URL) {
        let url = try copyFixture("document.pdf", as: name)
        model.importFile(url)
        try await waitForImport()
        let reader = try #require(openReader)
        try await waitUntil { reader.player.duration > 0 }
        return (reader, url)
    }

    @Test func importingAPDFOpensTheReader() async throws {
        let (reader, url) = try await importDocument()
        #expect(reader.lecture.document != nil)
        #expect(reader.lecture.title == "reading")
        #expect(reader.documentURL?.lastPathComponent == url.lastPathComponent)
        #expect(reader.player.duration > 1)
        model.closeReader()
    }

    @Test func workingStateSaysItIsADocument() throws {
        model.importFile(try copyFixture("document.pdf", as: "reading.pdf"))
        guard case .working(let title, _, let isDocument) = model.importState else {
            Issue.record("Expected the working state")
            return
        }
        #expect(title == "reading")
        #expect(isDocument)
        model.cancelImport()
    }

    @Test func importingTheSamePDFAgainKeepsProgress() async throws {
        let (reader, url) = try await importDocument()
        reader.player.seek(to: 2)
        model.closeReader()

        model.importFile(url)
        try await waitForImport()
        #expect(openReader?.lecture.position == 2)
        #expect(library.all().count == 1)
        model.closeReader()
    }

    @Test func scannedPDFShowsItsMessage() async throws {
        model.importFile(try copyFixture("scanned.pdf", as: "scanned.pdf"))
        try await waitForImport()
        #expect(failureMessage == "This PDF has no readable text. It may be a scan, which isn't supported yet.")
    }

    @Test func lockedPDFShowsItsMessage() async throws {
        model.importFile(try copyFixture("locked.pdf", as: "locked.pdf"))
        try await waitForImport()
        #expect(failureMessage == "This PDF is password protected. Remove the password and try again.")
    }

    @Test func damagedPDFShowsTheUnreadableMessage() async throws {
        model.importFile(try copyFixture("notaudio.mp3", as: "damaged.pdf"))
        try await waitForImport()
        #expect(failureMessage == "This file couldn't be opened. Try an MP3, M4A, WAV or PDF file.")
    }

    @Test func movedPDFShowsTheLocatePrompt() async throws {
        let (reader, url) = try await importDocument()
        let lecture = reader.lecture
        model.closeReader()
        try FileManager.default.removeItem(at: url)

        model.open(lecture)
        guard case .missingAudio(let missing, let message) = model.screen else {
            Issue.record("Expected the locate prompt")
            return
        }
        #expect(missing.id == lecture.id)
        #expect(message == nil)
    }

    @Test func locatingADifferentPDFIsRefused() async throws {
        let (reader, url) = try await importDocument()
        let lecture = reader.lecture
        model.closeReader()
        try FileManager.default.removeItem(at: url)

        model.locateAudio(for: lecture, at: fixture("two-columns.pdf"))
        guard case .missingAudio(_, let message) = model.screen else {
            Issue.record("Expected to stay on the locate prompt")
            return
        }
        #expect(message == "That's a different PDF. Choose the original file.")
    }

    @Test func locatingTheOriginalPDFOpensIt() async throws {
        let (reader, url) = try await importDocument()
        let lecture = reader.lecture
        model.closeReader()
        let moved = directory.appending(path: "new home.pdf")
        try FileManager.default.copyItem(at: url, to: moved)
        try FileManager.default.removeItem(at: url)

        model.locateAudio(for: lecture, at: moved)
        #expect(openReader?.documentURL?.lastPathComponent == "new home.pdf")
        model.closeReader()
    }

    @Test func missingAudioIsPreparedAgainKeepingBookmarks() async throws {
        let (reader, _) = try await importDocument()
        reader.player.seek(to: 1)
        reader.addBookmark()
        model.closeReader()
        let saved = try #require(library.all().first)
        try FileManager.default.removeItem(at: library.generatedAudioURL(forID: saved.id))

        model.open(saved)
        #expect(model.isImporting)
        try await waitForImport()
        let reopened = try #require(openReader)
        #expect(reopened.lecture.bookmarks.count == 1)
        #expect(library.audioURL(for: reopened.lecture) != nil)
        model.closeReader()
    }

    @Test func missingAudioIsPreparedWhenImportingTheSamePDFAgain() async throws {
        let (reader, url) = try await importDocument()
        let id = reader.lecture.id
        model.closeReader()
        try FileManager.default.removeItem(at: library.generatedAudioURL(forID: id))

        model.importFile(url)
        try await waitForImport()
        try await waitUntil { openReader != nil }
        #expect(openReader != nil)
        #expect(FileManager.default.fileExists(atPath: library.generatedAudioURL(forID: id).path))
        model.closeReader()
    }

    @Test func readingControlsWorkOnAPDF() async throws {
        let (reader, _) = try await importDocument()

        reader.jump(toWord: 5)
        #expect(reader.activeWord == 5)
        reader.perform(.skip(30))
        #expect(reader.player.currentTime <= reader.player.duration)
        reader.jump(toWord: 3)
        reader.addBookmark()
        #expect(reader.lecture.bookmarks.map(\.wordIndex) == [3])

        reader.query = "rebuilt"
        try await waitUntil(upTo: 3) { !reader.matches.isEmpty }
        #expect(reader.matches.first?.wordRange == 2..<3)

        let position = reader.player.currentTime
        model.closeReader()
        let saved = try #require(library.all().first)
        #expect(saved.position == position)
        #expect(saved.document != nil)
    }

    @Test func removingAPDFDeletesItsAudioAndKeepsThePDF() async throws {
        let (reader, url) = try await importDocument()
        let lecture = reader.lecture
        model.closeReader()
        model.remove(lecture)
        #expect(library.all().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: library.generatedAudioURL(forID: lecture.id).path))
        #expect(FileManager.default.fileExists(atPath: url.path))
    }
}
