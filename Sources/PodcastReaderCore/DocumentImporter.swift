import Foundation

/// Turns a PDF into a saved lecture: its words, their places on the page, and generated speech.
public struct DocumentImporter: Sendable {
    private let library: Library
    private let engine: any SpeechEngine

    public init(library: Library, engine: any SpeechEngine = SpeechRenderer()) {
        self.library = library
        self.engine = engine
    }

    public func importDocument(
        at url: URL,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> Lecture {
        let document = try await Task.detached { try DocumentReader.read(pdfAt: url) }.value
        try Task.checkCancellation()

        let id = try library.lectureID(forAudioAt: url)
        let speech = try await renderSpeech(words: document.words.map(\.text), id: id, onProgress: onProgress)

        var lecture = try library.makeLecture(
            audioAt: url,
            transcript: Transcript(words: timedWords(document.words.map(\.text), speech.times)),
            duration: speech.duration
        )
        lecture.document = DocumentInfo(
            voiceName: speech.voiceName,
            pageCount: document.pageCount,
            locations: document.words.map(\.location),
            audioBytes: library.fileSize(of: library.generatedAudioURL(forID: id))
        )
        try save(lecture)
        return lecture
    }

    /// Renders the audio again, keeping bookmarks and position on the same words.
    public func regenerateAudio(
        for lecture: Lecture,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> Lecture {
        let texts = lecture.transcript.words.map(\.text)
        let speech = try await renderSpeech(words: texts, id: lecture.id, onProgress: onProgress)
        let transcript = Transcript(words: timedWords(texts, speech.times))

        // A long job can take a while, so this uses what's saved now, not at the start.
        let latest = (try? library.load(id: lecture.id)) ?? lecture
        var updated = latest
        updated.transcript = transcript
        updated.duration = speech.duration
        updated.document?.voiceName = speech.voiceName
        updated.document?.audioBytes = library.fileSize(of: library.generatedAudioURL(forID: lecture.id))
        updated.bookmarks = latest.bookmarks.map { bookmark in
            Bookmark(
                id: bookmark.id,
                wordIndex: bookmark.wordIndex,
                time: transcript.words[bookmark.wordIndex].start,
                text: bookmark.text
            )
        }
        if let word = WordClock(words: latest.transcript.words).activeWordIndex(at: latest.position) {
            updated.position = transcript.words[word].start
        }
        try save(updated)
        return updated
    }

    /// Writes to a temporary file first, so a canceled or failed job leaves nothing behind.
    private func renderSpeech(
        words: [String],
        id: String,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> RenderedSpeech {
        let temporary = library.directory.appending(path: "\(id)-rendering.m4a")
        let final = library.generatedAudioURL(forID: id)
        defer { try? FileManager.default.removeItem(at: temporary) }

        let speech = try await engine.render(words: words, to: temporary, onProgress: onProgress)
        try Task.checkCancellation()
        // Saved word times must line up with the saved words, or later lookups go wrong.
        guard speech.times.count == words.count else { throw DocumentError.speechDidNotMatch }
        try? FileManager.default.removeItem(at: final)
        try FileManager.default.moveItem(at: temporary, to: final)
        return speech
    }

    private func timedWords(_ texts: [String], _ times: [WordTime]) -> [Word] {
        zip(texts, times).map { Word(text: $0, start: $1.start, end: $1.end) }
    }

    /// Writing is the last step of an import, so a failure here takes the audio with it.
    private func save(_ lecture: Lecture) throws {
        do {
            try library.save(lecture)
        } catch {
            try? FileManager.default.removeItem(at: library.generatedAudioURL(forID: lecture.id))
            throw error
        }
    }
}
