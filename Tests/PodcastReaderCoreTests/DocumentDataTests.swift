import Foundation
import Testing
@testable import PodcastReaderCore

struct DocumentDataTests {
    let root: URL
    let library: Library

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "DocumentDataTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        library = Library(directory: root.appending(path: "lectures", directoryHint: .isDirectory))
    }

    let info = DocumentInfo(
        voiceName: "Samantha",
        pageCount: 2,
        locations: [WordLocation(page: 1, ranges: [PageTextRange(location: 4, length: 5)])]
    )

    func makeDocumentLecture() throws -> (Lecture, URL) {
        let pdf = root.appending(path: "reading.pdf")
        try Data("pdf bytes".utf8).write(to: pdf)
        var lecture = try library.makeLecture(
            audioAt: pdf,
            transcript: Transcript(words: [Word(text: "Hello", start: 0, end: 1)]),
            duration: 1
        )
        lecture.document = info
        return (lecture, pdf)
    }

    func writeGeneratedAudio(for lecture: Lecture) throws {
        try Data("audio".utf8).write(to: library.generatedAudioURL(forID: lecture.id))
    }

    @Test func lectureSavedBeforeThisFeatureStillLoads() throws {
        let json = """
        {"id":"old","title":"Old lecture","duration":60,"addedAt":0,"lastOpenedAt":0,
         "filePath":"/tmp/old.mp3",
         "transcript":{"words":[{"text":"Hello","start":1,"end":2}],"lines":[{"id":0,"wordRange":[0,1]}]},
         "bookmarks":[],"position":12.5}
        """
        try Data(json.utf8).write(to: library.directory.appending(path: "old.json"))

        let lecture = try #require(try library.load(id: "old"))
        #expect(lecture.document == nil)
        #expect(lecture.position == 12.5)
        #expect(lecture.transcript.words.first?.text == "Hello")
        #expect(library.all().map(\.id) == ["old"])
    }

    @Test func documentInfoRoundTrips() throws {
        let (lecture, _) = try makeDocumentLecture()
        try library.save(lecture)
        #expect(try library.load(id: lecture.id)?.document == info)
    }

    @Test func removingADocumentLectureDeletesItsAudioButNotThePDF() throws {
        let (lecture, pdf) = try makeDocumentLecture()
        try library.save(lecture)
        try writeGeneratedAudio(for: lecture)
        try library.remove(id: lecture.id)
        #expect(!FileManager.default.fileExists(atPath: library.generatedAudioURL(forID: lecture.id).path))
        #expect(FileManager.default.fileExists(atPath: pdf.path))
    }

    @Test func audioURLOfADocumentIsTheGeneratedAudio() throws {
        let (lecture, _) = try makeDocumentLecture()
        try writeGeneratedAudio(for: lecture)
        #expect(library.audioURL(for: lecture) == library.generatedAudioURL(forID: lecture.id))
    }

    @Test func audioURLOfADocumentWithNoGeneratedAudioIsNil() throws {
        let (lecture, _) = try makeDocumentLecture()
        #expect(library.audioURL(for: lecture) == nil)
    }

    @Test func documentURLFindsAMovedPDF() throws {
        let (lecture, pdf) = try makeDocumentLecture()
        let moved = root.appending(path: "moved.pdf")
        try FileManager.default.moveItem(at: pdf, to: moved)
        #expect(library.documentURL(for: lecture)?.lastPathComponent == "moved.pdf")
    }

    @Test func aDeletedPDFHasNoDocumentURL() throws {
        let (lecture, pdf) = try makeDocumentLecture()
        try FileManager.default.removeItem(at: pdf)
        #expect(library.documentURL(for: lecture) == nil)
    }

    @Test func audioLectureHasNoDocumentURL() throws {
        let audio = root.appending(path: "talk.mp3")
        try Data("audio".utf8).write(to: audio)
        let lecture = try library.makeLecture(
            audioAt: audio,
            transcript: Transcript(words: [Word(text: "Hello", start: 0, end: 1)]),
            duration: 1
        )
        #expect(library.documentURL(for: lecture) == nil)
        #expect(library.audioURL(for: lecture) != nil)
    }

    @Test func importKinds() {
        #expect(AudioImport.kind(of: URL(fileURLWithPath: "/a.PDF")) == .document)
        #expect(AudioImport.kind(of: URL(fileURLWithPath: "/a.pdf")) == .document)
        #expect(AudioImport.kind(of: URL(fileURLWithPath: "/a.mp3")) == .audio)
        #expect(AudioImport.kind(of: URL(fileURLWithPath: "/a.txt")) == nil)
    }
}
