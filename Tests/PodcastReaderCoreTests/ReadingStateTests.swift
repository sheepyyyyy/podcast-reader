import Foundation
import Testing
@testable import PodcastReaderCore

/// Position is saved in a small file of its own, so that playing a long document doesn't
/// rewrite its whole lecture every few seconds.
struct ReadingStateTests {
    let root: URL
    let library: Library
    let lecture: Lecture

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "ReadingStateTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        library = Library(directory: root.appending(path: "lectures", directoryHint: .isDirectory))
        let audio = root.appending(path: "talk.mp3")
        try Data("audio".utf8).write(to: audio)
        lecture = try library.makeLecture(
            audioAt: audio,
            transcript: Transcript(words: [Word(text: "Hello", start: 0, end: 1)]),
            duration: 60
        )
        try library.save(lecture)
    }

    func lectureFile() -> URL {
        library.directory.appending(path: "\(lecture.id).json")
    }

    func updated(position: TimeInterval, opened: Date = Date(timeIntervalSince1970: 500)) -> Lecture {
        var copy = lecture
        copy.position = position
        copy.lastOpenedAt = opened
        return copy
    }

    @Test func readingStateLeavesTheLectureFileAlone() throws {
        let before = try Data(contentsOf: lectureFile())
        try library.saveReadingState(of: updated(position: 12))
        #expect(try Data(contentsOf: lectureFile()) == before)
    }

    @Test func loadingUsesTheReadingState() throws {
        try library.saveReadingState(of: updated(position: 12))
        let loaded = try #require(try library.load(id: lecture.id))
        #expect(loaded.position == 12)
        #expect(loaded.lastOpenedAt == Date(timeIntervalSince1970: 500))
    }

    @Test func listingUsesTheReadingState() throws {
        try library.saveReadingState(of: updated(position: 12))
        #expect(library.all().first?.position == 12)
    }

    @Test func aFullSaveReplacesTheReadingState() throws {
        try library.saveReadingState(of: updated(position: 12))
        try library.save(updated(position: 30))
        #expect(try library.load(id: lecture.id)?.position == 30)
    }

    @Test func aDamagedReadingStateIsIgnored() throws {
        try library.saveReadingState(of: updated(position: 12))
        let files = try FileManager.default.contentsOfDirectory(at: library.directory, includingPropertiesForKeys: nil)
        let state = try #require(files.first { $0.pathExtension != "json" })
        try Data("garbage".utf8).write(to: state)
        #expect(try library.load(id: lecture.id)?.position == 0)
    }

    @Test func removingALectureRemovesUnfinishedKokoroWork() throws {
        let work = library.kokoroWorkFolder(forID: lecture.id, voice: .heart)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try library.remove(id: lecture.id)
        #expect(!FileManager.default.fileExists(atPath: work.path))
    }

    @Test func removingALectureRemovesAudioLeftByQuitting() throws {
        let leftover = library.directory.appending(path: "\(lecture.id)-rendering.m4a")
        try Data("audio".utf8).write(to: leftover)
        try library.remove(id: lecture.id)
        #expect(!FileManager.default.fileExists(atPath: leftover.path))
    }

    @Test func unfinishedWorkCanBeClearedWithoutTouchingLectures() throws {
        let work = library.kokoroWorkFolder(forID: "another", voice: .heart)
        let audio = library.directory.appending(path: "another-rendering.m4a")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try Data("audio".utf8).write(to: audio)
        library.removeUnfinishedKokoroWork()
        #expect(!FileManager.default.fileExists(atPath: work.path))
        #expect(!FileManager.default.fileExists(atPath: audio.path))
        #expect(try library.load(id: lecture.id) != nil)
    }

    @Test func removingALectureRemovesItsReadingState() throws {
        try library.saveReadingState(of: updated(position: 12))
        try library.remove(id: lecture.id)
        #expect(try FileManager.default.contentsOfDirectory(atPath: library.directory.path).isEmpty)
    }
}
