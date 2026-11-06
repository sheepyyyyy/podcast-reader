import Foundation
import Synchronization
import Testing
@testable import PodcastReaderCore

struct TranscriberTests {
    @Test(arguments: ["sample.mp3", "sample_vbr.mp3", "sample.m4a", "sample.wav"])
    func transcribesWithOrderedTimes(file: String) async throws {
        let transcript = try await Transcriber().transcribe(audioAt: fixture(file), onProgress: { _ in })
        let lower = transcript.words.map { $0.text.lowercased() }
        #expect(lower.contains { $0.hasPrefix("memory") })
        #expect(lower.contains { $0.hasPrefix("stronger") })
        #expect(transcript.words.allSatisfy { !$0.text.contains(" ") && $0.end >= $0.start })
        #expect(zip(transcript.words, transcript.words.dropFirst()).allSatisfy { $0.start <= $1.start })
    }

    @Test func reportsProgressThatNeverGoesBackward() async throws {
        let fractions = Mutex<[Double]>([])
        _ = try await Transcriber().transcribe(audioAt: fixture("sample.mp3"), onProgress: { phase in
            if case .transcribing(let fraction) = phase {
                fractions.withLock { $0.append(fraction) }
            }
        })
        let seen = fractions.withLock { $0 }
        #expect(!seen.isEmpty)
        #expect(zip(seen, seen.dropFirst()).allSatisfy { $0 <= $1 })
        #expect(seen.allSatisfy { (0...1).contains($0) })
        #expect((seen.last ?? 0) > 0.5)
    }

    @Test func silenceThrowsNoSpeech() async {
        await #expect(throws: TranscriberError.noSpeechFound) {
            try await Transcriber().transcribe(audioAt: fixture("silence.mp3"), onProgress: { _ in })
        }
    }

    @Test func nonAudioThrowsUnreadable() async {
        await #expect(throws: TranscriberError.unreadableFile) {
            try await Transcriber().transcribe(audioAt: fixture("notaudio.mp3"), onProgress: { _ in })
        }
    }

    @Test func cancellingThrowsCancellationError() async {
        let task = Task {
            try await Transcriber().transcribe(audioAt: fixture("sample.mp3"), onProgress: { _ in })
        }
        task.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
    }

    @Test func assemblerTrimsAndSkipsBlank() {
        var words: [Word] = []
        WordAssembler.append(run: " hello", start: 1, end: 2, to: &words)
        WordAssembler.append(run: "   ", start: 2, end: 3, to: &words)
        #expect(words == [Word(text: "hello", start: 1, end: 2)])
    }

    @Test func assemblerMergesPunctuationOnlyRunIntoPreviousWord() {
        var words = [Word(text: "hello", start: 1, end: 2)]
        WordAssembler.append(run: ",", start: 2, end: 2.1, to: &words)
        #expect(words == [Word(text: "hello,", start: 1, end: 2.1)])
    }

    @Test func assemblerMergesUntimedRunIntoPreviousWord() {
        var words = [Word(text: "well", start: 1, end: 2)]
        WordAssembler.append(run: "-known", start: nil, end: nil, to: &words)
        #expect(words == [Word(text: "well-known", start: 1, end: 2)])
    }

    @Test func assemblerDropsUntimedRunWithNoPreviousWord() {
        var words: [Word] = []
        WordAssembler.append(run: "orphan", start: nil, end: nil, to: &words)
        #expect(words.isEmpty)
    }

    @Test func assemblerSplitsMultiWordRunEvenly() {
        var words: [Word] = []
        WordAssembler.append(run: "two words", start: 0, end: 2, to: &words)
        #expect(words == [Word(text: "two", start: 0, end: 1), Word(text: "words", start: 1, end: 2)])
    }
}
