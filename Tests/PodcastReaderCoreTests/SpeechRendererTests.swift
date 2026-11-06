import Foundation
import Synchronization
import Testing
@testable import PodcastReaderCore

struct SpeechRendererTests {
    static let paragraph = "Memory is rebuilt every time you recall it, and that act of rebuilding is what makes the pathway stronger. Dr. Ebbinghaus measured this in 1885; he found that we lose 70% of new material within a day. Spaced review, however, changes the curve. Close the book, write down what you remember, then check what you missed."

    func words(repeating count: Int = 1) -> [String] {
        (0..<count).flatMap { _ in Self.paragraph.split(separator: " ").map(String.init) }
    }

    func temporaryAudioURL() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "SpeechRendererTests-\(UUID().uuidString).m4a")
    }

    @Test func voicesRankByQualityThenUSEnglish() {
        func voice(_ name: String, _ language: String, _ rank: Int, isDefault: Bool = false) -> VoiceChoice {
            VoiceChoice(identifier: name, name: name, language: language, qualityRank: rank, isLanguageDefault: isDefault)
        }
        let ranked = SpeechRenderer.ranked([
            voice("Default GB", "en-GB", 1),
            voice("Other US", "en-US", 1),
            voice("Enhanced US", "en-US", 2),
            voice("Premium GB", "en-GB", 3),
            voice("Main US", "en-US", 1, isDefault: true),
        ])
        #expect(ranked.map(\.name) == ["Premium GB", "Enhanced US", "Main US", "Other US", "Default GB"])
    }

    @Test func rendersEveryWordWithOrderedTimes() async throws {
        let url = temporaryAudioURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let input = words()
        let result = try await SpeechRenderer().render(words: input, to: url, onProgress: { _ in })
        #expect(result.times.count == input.count)
        #expect(zip(result.times, result.times.dropFirst()).allSatisfy { $0.start <= $1.start })
        #expect(result.duration > 5)
        #expect(!result.voiceName.isEmpty)
    }

    @Test func timesReachTheEndAcrossChunks() async throws {
        let url = temporaryAudioURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let result = try await SpeechRenderer().render(words: words(repeating: 10), to: url, onProgress: { _ in })
        let last = try #require(result.times.last)
        #expect(result.duration - last.start < 2)
        #expect(last.start > result.duration * 0.9)
    }

    @Test func wordsAreEvenlyPacedAcrossChunks() async throws {
        let url = temporaryAudioURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let result = try await SpeechRenderer().render(words: words(repeating: 10), to: url, onProgress: { _ in })
        // Each repeat of the paragraph is the same speech, so it must take about the same time.
        let perParagraph = words().count
        let durations = stride(from: 0, to: 10 * perParagraph - perParagraph, by: perParagraph).map {
            result.times[$0 + perParagraph].start - result.times[$0].start
        }
        let shortest = try #require(durations.min())
        let longest = try #require(durations.max())
        #expect(longest - shortest < 1)
    }

    @Test func listsAndSymbolsDoNotThrowOffLaterWords() async throws {
        // Lists make the engine report several words at one offset, which must not read as
        // new chunks. Each repeat is the same speech, so it must take about the same time.
        let symbols = "First • • • second — third. 1 2 3 4 5 . . . Then x = y + 2 . ; ; ; . . . Another sentence follows. • . • . • . And a last sentence here."
            .split(separator: " ").map(String.init)
        let url = temporaryAudioURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let repeats = 10
        let input = (0..<repeats).flatMap { _ in symbols }
        let result = try await SpeechRenderer().render(words: input, to: url, onProgress: { _ in })

        let durations = stride(from: 0, to: (repeats - 1) * symbols.count, by: symbols.count).map {
            result.times[$0 + symbols.count].start - result.times[$0].start
        }
        let shortest = try #require(durations.min())
        let longest = try #require(durations.max())
        #expect(longest - shortest < 1, "each repeat took between \(shortest) and \(longest) s")

        let last = try #require(result.times.last)
        #expect(last.start > result.duration * 0.9, "last word at \(last.start) of \(result.duration) s")
    }

    @Test @MainActor func outputIsCompressedAndPlayable() async throws {
        let url = temporaryAudioURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let result = try await SpeechRenderer().render(words: words(repeating: 3), to: url, onProgress: { _ in })

        let size = try #require(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        let uncompressed = result.duration * 22_050 * 4
        #expect(Double(size) < uncompressed * 0.3)

        let player = PlayerController(url: url, isMuted: true)
        try await player.waitUntilReady()
        #expect(abs(player.duration - result.duration) < 0.2)
        player.stop()
    }

    @Test func symbolsWithNoMarkerDoNotBreakTheTimes() async throws {
        let url = temporaryAudioURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let input = ["First", "•", "second", "—", "third", "and", "then", "a", "fourth", "word."]
        let result = try await SpeechRenderer().render(words: input, to: url, onProgress: { _ in })
        #expect(result.times.count == input.count)
        #expect(zip(result.times, result.times.dropFirst()).allSatisfy { $0.start <= $1.start })
    }

    @Test func progressNeverGoesBackward() async throws {
        let url = temporaryAudioURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let seen = Mutex<[Double]>([])
        _ = try await SpeechRenderer().render(words: words(repeating: 5), to: url, onProgress: { value in
            seen.withLock { $0.append(value) }
        })
        let values = seen.withLock { $0 }
        #expect(!values.isEmpty)
        #expect(zip(values, values.dropFirst()).allSatisfy { $0 <= $1 })
        #expect(values.allSatisfy { (0...1).contains($0) })
    }

    @Test func aSessionCanceledBeforeItRunsStillReturns() async {
        let session = RenderSession(text: "Hello there.", voiceIdentifier: "", url: temporaryAudioURL(), onProgress: { _ in })
        session.cancel()
        let output = await session.run()
        #expect(output.frames == 0)
    }

    @Test func cancellingAtOnceThrows() async {
        let url = temporaryAudioURL()
        let input = words(repeating: 5)
        let task = Task { try await SpeechRenderer().render(words: input, to: url, onProgress: { _ in }) }
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
    }

    @Test func cancellingMidRenderStopsPromptly() async throws {
        let url = temporaryAudioURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let input = words(repeating: 600)
        let task = Task { try await SpeechRenderer().render(words: input, to: url, onProgress: { _ in }) }
        try await Task.sleep(for: .milliseconds(300))
        let start = Date()
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(Date().timeIntervalSince(start) < 5)
    }
}
