import AppKit
import CoreText
import Foundation
import Testing
@testable import PodcastReaderCore

struct DocumentImporterTests {
    let root: URL
    let library: Library
    let importer: DocumentImporter

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "DocumentImporterTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        library = Library(directory: root.appending(path: "lectures", directoryHint: .isDirectory))
        importer = DocumentImporter(library: library)
    }

    func libraryFiles() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: library.directory.path)
    }

    /// A PDF long enough that rendering it takes well over a second.
    func makeLongPDF() -> URL {
        let url = root.appending(path: "long.pdf")
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = CGContext(url as CFURL, mediaBox: &box, nil)!
        let font = CTFontCreateWithName("Times New Roman" as CFString, 11, nil)
        let text = String(repeating: "Close the book, write down what you remember, and check what you missed. ", count: 60)
        let setter = CTFramesetterCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
        for _ in 0..<30 {
            context.beginPDFPage(nil)
            let frame = CTFramesetterCreateFrame(
                setter,
                CFRange(location: 0, length: 0),
                CGPath(rect: CGRect(x: 54, y: 100, width: 504, height: 580), transform: nil),
                nil
            )
            CTFrameDraw(frame, context)
            context.endPDFPage()
        }
        context.closePDF()
        return url
    }

    /// Stands in for a real voice: writes a known audio file and spaces words evenly.
    struct StandInEngine: SpeechEngine {
        let voiceName: String

        func render(words: [String], to url: URL, onProgress: @escaping @Sendable (Double) -> Void) async throws -> RenderedSpeech {
            try FileManager.default.copyItem(at: fixture("sample.m4a"), to: url)
            onProgress(1)
            let times = words.indices.map { WordTime(start: Double($0), end: Double($0 + 1)) }
            return RenderedSpeech(times: times, duration: Double(words.count), voiceName: voiceName)
        }
    }

    @Test func usesTheEngineItIsGiven() async throws {
        let importer = DocumentImporter(library: library, engine: StandInEngine(voiceName: "Stand-in"))
        let lecture = try await importer.importDocument(at: fixture("document.pdf"), onProgress: { _ in })
        #expect(lecture.document?.voiceName == "Stand-in")
        #expect(lecture.transcript.words[3].start == 3)
    }

    @Test func regeneratingWithAnotherEngineUpdatesTheVoice() async throws {
        let first = try await DocumentImporter(library: library, engine: StandInEngine(voiceName: "First"))
            .importDocument(at: fixture("document.pdf"), onProgress: { _ in })
        let second = try await DocumentImporter(library: library, engine: StandInEngine(voiceName: "Second"))
            .regenerateAudio(for: first, onProgress: { _ in })
        #expect(second.document?.voiceName == "Second")
        #expect(try library.load(id: first.id)?.document?.voiceName == "Second")
    }

    /// Makes a change to the saved lecture partway through rendering.
    struct InterruptedEngine: SpeechEngine {
        let library: Library
        let lectureID: String

        func render(words: [String], to url: URL, onProgress: @escaping @Sendable (Double) -> Void) async throws -> RenderedSpeech {
            var lecture = try #require(try library.load(id: lectureID))
            _ = lecture.addBookmark(wordIndex: 7)
            lecture.position = lecture.transcript.words[9].start
            try library.save(lecture)
            try FileManager.default.copyItem(at: fixture("sample.m4a"), to: url)
            let times = words.indices.map { WordTime(start: Double($0) * 2, end: Double($0 + 1) * 2) }
            return RenderedSpeech(times: times, duration: Double(words.count) * 2, voiceName: "New")
        }
    }

    @Test func changesMadeWhileRegeneratingAreKept() async throws {
        let first = try await DocumentImporter(library: library, engine: StandInEngine(voiceName: "First"))
            .importDocument(at: fixture("document.pdf"), onProgress: { _ in })
        let engine = InterruptedEngine(library: library, lectureID: first.id)
        let updated = try await DocumentImporter(library: library, engine: engine)
            .regenerateAudio(for: first, onProgress: { _ in })
        #expect(updated.bookmarks.map(\.wordIndex) == [7])
        #expect(updated.bookmarks[0].time == 14)
        #expect(updated.position == 18)
    }

    @Test func audioThatDoesntMatchTheSavedTimesCountsAsMissing() async throws {
        let lecture = try await DocumentImporter(library: library, engine: StandInEngine(voiceName: "First"))
            .importDocument(at: fixture("document.pdf"), onProgress: { _ in })
        #expect(library.audioURL(for: lecture) != nil)

        // What quitting between replacing the audio and saving the new times leaves behind.
        try Data("different audio".utf8).write(to: library.generatedAudioURL(forID: lecture.id))
        #expect(library.audioURL(for: lecture) == nil)
    }

    @Test func aLectureSavedBeforeAudioSizesStillOpens() async throws {
        var lecture = try await DocumentImporter(library: library, engine: StandInEngine(voiceName: "First"))
            .importDocument(at: fixture("document.pdf"), onProgress: { _ in })
        lecture.document?.audioBytes = nil
        #expect(library.audioURL(for: lecture) != nil)
    }

    @Test func regeneratingRecordsTheNewAudio() async throws {
        let first = try await DocumentImporter(library: library, engine: StandInEngine(voiceName: "First"))
            .importDocument(at: fixture("document.pdf"), onProgress: { _ in })
        let second = try await DocumentImporter(library: library, engine: StandInEngine(voiceName: "Second"))
            .regenerateAudio(for: first, onProgress: { _ in })
        #expect(library.audioURL(for: second) != nil)
    }

    struct ShortEngine: SpeechEngine {
        func render(words: [String], to url: URL, onProgress: @escaping @Sendable (Double) -> Void) async throws -> RenderedSpeech {
            try FileManager.default.copyItem(at: fixture("sample.m4a"), to: url)
            return RenderedSpeech(times: [WordTime(start: 0, end: 1)], duration: 1, voiceName: "Short")
        }
    }

    @Test func aWrongNumberOfWordTimesIsRefused() async throws {
        await #expect(throws: DocumentError.speechDidNotMatch) {
            _ = try await DocumentImporter(library: library, engine: ShortEngine())
                .importDocument(at: fixture("document.pdf"), onProgress: { _ in })
        }
        #expect(try libraryFiles().isEmpty)
    }

    @Test func importsAPDFEndToEnd() async throws {
        let lecture = try await importer.importDocument(at: fixture("document.pdf"), onProgress: { _ in })
        let document = try #require(lecture.document)
        #expect(lecture.title == "document")
        #expect(document.pageCount == 5)
        #expect(document.locations.count == lecture.transcript.words.count)
        #expect(!document.voiceName.isEmpty)
        #expect(lecture.duration > 1)
        #expect(library.audioURL(for: lecture) == library.generatedAudioURL(forID: lecture.id))
        #expect(library.documentURL(for: lecture) != nil)
        #expect(try library.load(id: lecture.id)?.document == document)
        #expect(try libraryFiles().count == 2)
    }

    @Test func transcriptWordsMatchTheReadableWords() async throws {
        let lecture = try await importer.importDocument(at: fixture("document.pdf"), onProgress: { _ in })
        let expected = try DocumentReader.read(pdfAt: fixture("document.pdf")).words
        #expect(lecture.transcript.words.map(\.text) == expected.map(\.text))
        #expect(lecture.document?.locations == expected.map(\.location))
    }

    @Test func scannedPDFThrowsAndSavesNothing() async throws {
        await #expect(throws: DocumentError.noReadableText) {
            _ = try await importer.importDocument(at: fixture("scanned.pdf"), onProgress: { _ in })
        }
        #expect(try libraryFiles().isEmpty)
    }

    @Test func cancellingLeavesNothingBehind() async throws {
        let url = makeLongPDF()
        let importer = importer
        let task = Task { try await importer.importDocument(at: url, onProgress: { _ in }) }
        try await Task.sleep(for: .milliseconds(500))
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(try libraryFiles().isEmpty)
    }

    @Test func regeneratingKeepsBookmarksAndPosition() async throws {
        var lecture = try await importer.importDocument(at: fixture("document.pdf"), onProgress: { _ in })
        _ = lecture.addBookmark(wordIndex: 5)
        lecture.position = lecture.transcript.words[8].start
        try library.save(lecture)
        try FileManager.default.removeItem(at: library.generatedAudioURL(forID: lecture.id))

        let updated = try await importer.regenerateAudio(for: lecture, onProgress: { _ in })
        #expect(library.audioURL(for: updated) != nil)
        #expect(updated.bookmarks.map(\.wordIndex) == [5])
        #expect(updated.bookmarks[0].time == updated.transcript.words[5].start)
        #expect(updated.position == updated.transcript.words[8].start)
        #expect(updated.document?.locations == lecture.document?.locations)
        #expect(try library.load(id: lecture.id)?.bookmarks.count == 1)
    }
}
