import CryptoKit
import Foundation

public struct Bookmark: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public let wordIndex: Int
    public let time: TimeInterval
    /// The caption line holding the bookmarked word.
    public let text: String
}

/// A stretch of a PDF page's text, in the units `PDFPage.selection(for:)` expects.
public struct PageTextRange: Codable, Hashable, Sendable {
    public let location: Int
    public let length: Int

    public init(location: Int, length: Int) {
        self.location = location
        self.length = length
    }

    public var nsRange: NSRange {
        NSRange(location: location, length: length)
    }
}

/// Where one spoken word is in a PDF. A word hyphenated across a line break has two ranges.
public struct WordLocation: Codable, Hashable, Sendable {
    public let page: Int
    public let ranges: [PageTextRange]

    public init(page: Int, ranges: [PageTextRange]) {
        self.page = page
        self.ranges = ranges
    }
}

/// What makes a lecture a PDF being read aloud. `locations` has one entry per transcript word.
public struct DocumentInfo: Codable, Hashable, Sendable {
    public var voiceName: String
    public var pageCount: Int
    public var locations: [WordLocation]
    /// The generated audio's size. Audio and word times are saved in two steps, so quitting
    /// between them would pair new audio with old times. Older lectures don't have this.
    public var audioBytes: Int?

    public init(voiceName: String, pageCount: Int, locations: [WordLocation], audioBytes: Int? = nil) {
        self.voiceName = voiceName
        self.pageCount = pageCount
        self.locations = locations
        self.audioBytes = audioBytes
    }
}

public struct Lecture: Codable, Sendable, Identifiable {
    public let id: String
    public var title: String
    public var duration: TimeInterval
    public var addedAt: Date
    public var lastOpenedAt: Date
    public var fileBookmark: Data?
    public var filePath: String
    public var transcript: Transcript
    public var bookmarks: [Bookmark]
    public var position: TimeInterval
    /// Set for a PDF being read aloud. `filePath` and `fileBookmark` then point at the PDF.
    /// Optional, because lectures saved before PDFs existed don't have it.
    public var document: DocumentInfo?

    /// Marks a word. Returns false if that word is already bookmarked or doesn't exist.
    public mutating func addBookmark(wordIndex: Int) -> Bool {
        guard transcript.words.indices.contains(wordIndex),
              !bookmarks.contains(where: { $0.wordIndex == wordIndex })
        else { return false }

        bookmarks.append(Bookmark(
            id: UUID(),
            wordIndex: wordIndex,
            time: transcript.words[wordIndex].start,
            text: transcript.text(ofLine: transcript.lineIndex(forWord: wordIndex))
        ))
        bookmarks.sort { $0.time < $1.time }
        return true
    }

    public mutating func removeBookmark(id: UUID) {
        bookmarks.removeAll { $0.id == id }
    }
}

private struct ReadingState: Codable {
    let position: TimeInterval
    let lastOpenedAt: Date
}

public enum LibraryError: Error, Equatable {
    /// The chosen file isn't the audio this lecture was transcribed from.
    case differentAudio
}

/// Saves each lecture as one JSON file. The audio itself stays where the user keeps it.
public struct Library: Sendable {
    private static let fingerprintLength = 1_048_576

    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public static var defaultDirectory: URL {
        URL.applicationSupportDirectory
            .appending(path: "Podcast Reader", directoryHint: .isDirectory)
            .appending(path: "lectures", directoryHint: .isDirectory)
    }

    /// Derived from the file size and a hash of the first megabyte, so the same audio
    /// is recognized wherever it lives and whatever it's called.
    public func lectureID(forAudioAt url: URL) throws -> String {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let start = try handle.read(upToCount: Self.fingerprintLength) ?? Data()

        var hasher = SHA256()
        hasher.update(data: Data("\(size):".utf8))
        hasher.update(data: start)
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public func makeLecture(audioAt url: URL, transcript: Transcript, duration: TimeInterval) throws -> Lecture {
        let now = Date()
        return Lecture(
            id: try lectureID(forAudioAt: url),
            title: url.deletingPathExtension().lastPathComponent,
            duration: duration,
            addedAt: now,
            lastOpenedAt: now,
            fileBookmark: try? url.bookmarkData(),
            filePath: url.path,
            transcript: transcript,
            bookmarks: [],
            position: 0
        )
    }

    public func load(id: String) throws -> Lecture? {
        let url = fileURL(forID: id)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return withReadingState(try JSONDecoder().decode(Lecture.self, from: Data(contentsOf: url)))
    }

    public func save(_ lecture: Lecture) throws {
        try JSONEncoder().encode(lecture).write(to: fileURL(forID: lecture.id), options: .atomic)
        // The lecture file now holds the newest position.
        try? FileManager.default.removeItem(at: readingStateURL(forID: lecture.id))
    }

    /// Saves only where the person is up to, in a small file of its own. A long document's
    /// lecture file runs to many megabytes, too much to rewrite every few seconds of playing.
    public func saveReadingState(of lecture: Lecture) throws {
        let state = ReadingState(position: lecture.position, lastOpenedAt: lecture.lastOpenedAt)
        try JSONEncoder().encode(state).write(to: readingStateURL(forID: lecture.id), options: .atomic)
    }

    private func withReadingState(_ lecture: Lecture) -> Lecture {
        guard let data = try? Data(contentsOf: readingStateURL(forID: lecture.id)),
              let state = try? JSONDecoder().decode(ReadingState.self, from: data)
        else { return lecture }
        var updated = lecture
        updated.position = state.position
        updated.lastOpenedAt = state.lastOpenedAt
        return updated
    }

    private func readingStateURL(forID id: String) -> URL {
        directory.appending(path: "\(id).state")
    }

    public func remove(id: String) throws {
        for url in [fileURL(forID: id), generatedAudioURL(forID: id), readingStateURL(forID: id)]
        where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        // Unfinished Kokoro work can run to gigabytes.
        let contents = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for url in contents where url.lastPathComponent.hasPrefix("\(id)-kokoro-") || url.lastPathComponent == "\(id)-rendering.m4a" {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Where a Kokoro job keeps finished chunks, so that it can pick up after quitting.
    /// Clears anything left by quitting partway through a job.
    public func removeUnfinishedKokoroWork() {
        let contents = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for url in contents where url.lastPathComponent.contains("-kokoro-") || url.lastPathComponent.hasSuffix("-rendering.m4a") {
            try? FileManager.default.removeItem(at: url)
        }
    }

    public func kokoroWorkFolder(forID id: String, voice: KokoroVoice) -> URL {
        directory.appending(path: "\(id)-kokoro-\(voice.id)", directoryHint: .isDirectory)
    }

    /// Where a PDF's generated speech is kept, beside its saved lecture.
    public func generatedAudioURL(forID id: String) -> URL {
        directory.appending(path: "\(id).m4a")
    }

    /// Every readable lecture, most recently opened first. Damaged files are left out.
    public func all() -> [Lecture] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { try? JSONDecoder().decode(Lecture.self, from: Data(contentsOf: $0)) }
            .map(withReadingState)
            .sorted { $0.lastOpenedAt > $1.lastOpenedAt }
    }

    /// The audio to play: the file itself for a lecture, or the generated speech for a PDF.
    /// Returns nil if it's gone.
    public func audioURL(for lecture: Lecture) -> URL? {
        guard lecture.document != nil else { return sourceURL(for: lecture) }
        let generated = generatedAudioURL(forID: lecture.id)
        guard let size = fileSize(of: generated) else { return nil }
        if let expected = lecture.document?.audioBytes, expected != size { return nil }
        return generated
    }

    /// The size of a file, or nil if it isn't there.
    func fileSize(of url: URL) -> Int? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
    }

    /// The PDF being read aloud, even if it was moved. Nil for a lecture or a missing PDF.
    public func documentURL(for lecture: Lecture) -> URL? {
        lecture.document == nil ? nil : sourceURL(for: lecture)
    }

    /// Finds the user's own file even if it was moved. Returns nil if it's gone or in the Trash.
    private func sourceURL(for lecture: Lecture) -> URL? {
        var candidate = URL(fileURLWithPath: lecture.filePath)
        if let data = lecture.fileBookmark {
            var isStale = false
            if let resolved = try? URL(
                resolvingBookmarkData: data,
                options: [.withoutUI, .withoutMounting],
                bookmarkDataIsStale: &isStale
            ) {
                candidate = resolved
            }
        }
        // Drives other than the startup disk keep trashed files in /.Trashes/.
        guard !candidate.path.contains("/.Trash/"), !candidate.path.contains("/.Trashes/"),
              FileManager.default.fileExists(atPath: candidate.path)
        else { return nil }
        return candidate
    }

    /// Points a lecture at its audio's new location, refusing a different recording
    /// because the captions wouldn't match it.
    public func relocate(_ lecture: Lecture, to url: URL) throws -> Lecture {
        guard try lectureID(forAudioAt: url) == lecture.id else {
            throw LibraryError.differentAudio
        }
        var updated = lecture
        updated.filePath = url.path
        updated.fileBookmark = try? url.bookmarkData()
        return updated
    }

    private func fileURL(forID id: String) -> URL {
        directory.appending(path: "\(id).json")
    }
}
