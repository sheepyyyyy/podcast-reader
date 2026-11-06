import Foundation
import Testing
@testable import PodcastReaderCore

struct LibraryTests {
    let root: URL
    let library: Library

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "LibraryTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        library = Library(directory: root.appending(path: "lectures", directoryHint: .isDirectory))
    }

    func writeAudio(_ name: String, bytes: Data) throws -> URL {
        let url = root.appending(path: name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: url)
        return url
    }

    let transcript = Transcript(words: [
        Word(text: "First", start: 1, end: 2),
        Word(text: "line.", start: 2, end: 3),
        Word(text: "Second", start: 3, end: 4),
        Word(text: "line", start: 4, end: 5),
        Word(text: "ends", start: 5, end: 6),
        Word(text: "here.", start: 6, end: 7),
    ])

    func makeLecture(_ name: String = "a lecture.mp3", bytes: Data = Data("audio".utf8)) throws -> Lecture {
        let url = try writeAudio(name, bytes: bytes)
        return try library.makeLecture(audioAt: url, transcript: transcript, duration: 60)
    }

    @Test func makeLectureUsesFileNameAsTitle() throws {
        let lecture = try makeLecture()
        #expect(lecture.title == "a lecture")
        #expect(lecture.position == 0)
        #expect(lecture.duration == 60)
    }

    @Test func saveThenLoadRoundTrips() throws {
        var lecture = try makeLecture()
        lecture.position = 12.5
        _ = lecture.addBookmark(wordIndex: 2)
        try library.save(lecture)

        let loaded = try #require(try library.load(id: lecture.id))
        #expect(loaded.title == lecture.title)
        #expect(loaded.position == 12.5)
        #expect(loaded.transcript == lecture.transcript)
        #expect(loaded.bookmarks == lecture.bookmarks)
        #expect(loaded.fileBookmark == lecture.fileBookmark)
        #expect(loaded.filePath == lecture.filePath)
    }

    @Test func loadingAnUnknownIDIsNil() throws {
        #expect(try library.load(id: "missing") == nil)
    }

    @Test func allIsSortedByLastOpenedNewestFirst() throws {
        var older = try makeLecture("older.mp3", bytes: Data("older".utf8))
        older.lastOpenedAt = Date(timeIntervalSince1970: 100)
        var newer = try makeLecture("newer.mp3", bytes: Data("newer".utf8))
        newer.lastOpenedAt = Date(timeIntervalSince1970: 200)
        try library.save(older)
        try library.save(newer)
        #expect(library.all().map(\.title) == ["newer", "older"])
    }

    @Test func damagedFileIsSkipped() throws {
        try library.save(try makeLecture("one.mp3", bytes: Data("one".utf8)))
        try library.save(try makeLecture("two.mp3", bytes: Data("two".utf8)))
        try Data("garbage".utf8).write(to: library.directory.appending(path: "damaged.json"))
        #expect(library.all().count == 2)
    }

    @Test func removeDeletesTheSavedLectureButNotTheAudio() throws {
        let lecture = try makeLecture()
        try library.save(lecture)
        try library.remove(id: lecture.id)
        #expect(try library.load(id: lecture.id) == nil)
        #expect(FileManager.default.fileExists(atPath: lecture.filePath))
    }

    @Test func sameBytesAtTwoPathsGiveSameID() throws {
        let bytes = Data("same".utf8)
        let first = try writeAudio("one/a.mp3", bytes: bytes)
        let second = try writeAudio("two/b.MP3", bytes: bytes)
        #expect(try library.lectureID(forAudioAt: first) == library.lectureID(forAudioAt: second))
    }

    @Test func differentSizeGivesDifferentID() throws {
        let start = Data(repeating: 7, count: 1_048_576)
        let short = try writeAudio("short.mp3", bytes: start)
        let long = try writeAudio("long.mp3", bytes: start + Data("tail".utf8))
        #expect(try library.lectureID(forAudioAt: short) != library.lectureID(forAudioAt: long))
    }

    @Test func differentStartGivesDifferentID() throws {
        let first = try writeAudio("first.mp3", bytes: Data("aaaa".utf8))
        let second = try writeAudio("second.mp3", bytes: Data("bbbb".utf8))
        #expect(try library.lectureID(forAudioAt: first) != library.lectureID(forAudioAt: second))
    }

    @Test func movedAudioIsStillFound() throws {
        let lecture = try makeLecture()
        let destination = root.appending(path: "moved.mp3")
        try FileManager.default.moveItem(atPath: lecture.filePath, toPath: destination.path)
        let found = try #require(library.audioURL(for: lecture))
        #expect(found.lastPathComponent == "moved.mp3")
    }

    @Test func deletedAudioIsNil() throws {
        let lecture = try makeLecture()
        try FileManager.default.removeItem(atPath: lecture.filePath)
        #expect(library.audioURL(for: lecture) == nil)
    }

    @Test func trashedAudioCountsAsMissing() throws {
        var lecture = try makeLecture("in trash/.Trash/a.mp3")
        lecture.fileBookmark = nil
        #expect(library.audioURL(for: lecture) == nil)
    }

    @Test func audioTrashedOnAnExternalDriveCountsAsMissing() throws {
        var lecture = try makeLecture("external/.Trashes/501/a.mp3")
        lecture.fileBookmark = nil
        #expect(library.audioURL(for: lecture) == nil)
    }

    @Test func relocateAcceptsTheSameAudio() throws {
        let lecture = try makeLecture()
        let copy = try writeAudio("elsewhere/copy.mp3", bytes: Data("audio".utf8))
        let updated = try library.relocate(lecture, to: copy)
        #expect(updated.filePath == copy.path)
        try FileManager.default.removeItem(atPath: lecture.filePath)
        #expect(library.audioURL(for: updated)?.lastPathComponent == "copy.mp3")
    }

    @Test func relocateRefusesDifferentAudio() throws {
        let lecture = try makeLecture()
        let other = try writeAudio("other.mp3", bytes: Data("different".utf8))
        #expect(throws: LibraryError.differentAudio) {
            try library.relocate(lecture, to: other)
        }
    }

    @Test func addBookmarkAddsOnceAndKeepsTimeOrder() throws {
        var lecture = try makeLecture()
        let first = lecture.addBookmark(wordIndex: 3)
        let second = lecture.addBookmark(wordIndex: 0)
        let repeated = lecture.addBookmark(wordIndex: 3)
        #expect(first)
        #expect(second)
        #expect(!repeated)
        #expect(lecture.bookmarks.map(\.wordIndex) == [0, 3])
        #expect(lecture.bookmarks[1].time == 4)
        #expect(lecture.bookmarks[1].text == "Second line ends here.")
    }

    @Test func removeBookmarkRemovesOnlyThatOne() throws {
        var lecture = try makeLecture()
        _ = lecture.addBookmark(wordIndex: 0)
        _ = lecture.addBookmark(wordIndex: 3)
        lecture.removeBookmark(id: lecture.bookmarks[0].id)
        #expect(lecture.bookmarks.map(\.wordIndex) == [3])
    }
}
