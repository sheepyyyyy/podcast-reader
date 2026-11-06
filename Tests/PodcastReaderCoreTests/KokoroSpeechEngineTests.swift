@preconcurrency import AVFoundation
import Foundation
import Synchronization
import Testing
@testable import PodcastReaderCore

/// Fake installation, for what can be checked without Kokoro itself.
struct KokoroEngineErrorTests {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "KokoroEngineErrorTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func install(python body: String) throws -> KokoroEnvironment {
        let environment = KokoroEnvironment(root: root)
        try FileManager.default.createDirectory(at: environment.pythonURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\n\(body)\n".write(to: environment.pythonURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: environment.pythonURL.path)
        FileManager.default.createFile(atPath: environment.markerURL.path, contents: Data())
        return environment
    }

    @Test func notInstalledIsSaidRightAway() async {
        let engine = KokoroSpeechEngine(
            environment: KokoroEnvironment(root: root),
            voice: .heart,
            workFolder: root.appending(path: "work")
        )
        await #expect(throws: KokoroError.notInstalled) {
            _ = try await engine.render(words: ["Hello."], to: root.appending(path: "out.m4a"), onProgress: { _ in })
        }
    }

    @Test func aFailingHelperIsARenderFailure() async throws {
        let environment = try install(python: "exit 1")
        let work = root.appending(path: "work", directoryHint: .isDirectory)
        let engine = KokoroSpeechEngine(environment: environment, voice: .heart, workFolder: work)
        await #expect(throws: KokoroError.renderFailed) {
            _ = try await engine.render(words: ["Hello."], to: root.appending(path: "out.m4a"), onProgress: { _ in })
        }
        // Kept, because a later try can pick up what was finished.
        #expect(FileManager.default.fileExists(atPath: work.path))
    }

    @Test func aChangedJobDoesntReuseOldWork() async throws {
        let environment = try install(python: "exit 1")
        let work = root.appending(path: "work", directoryHint: .isDirectory)
        let engine = KokoroSpeechEngine(environment: environment, voice: .heart, workFolder: work)
        _ = try? await engine.render(words: ["First", "text."], to: root.appending(path: "out.m4a"), onProgress: { _ in })
        let leftover = work.appending(path: "chunk-0.wav")
        try Data("old".utf8).write(to: leftover)

        _ = try? await engine.render(words: ["Different", "text."], to: root.appending(path: "out.m4a"), onProgress: { _ in })
        #expect(!FileManager.default.fileExists(atPath: leftover.path))
    }

    @Test func aDifferentChunkLayoutDoesntReuseOldWork() {
        let words = ["One", "two", "three", "four"]
        let before = KokoroSpeechEngine.signature(voice: .heart, words: words, chunks: [0..<2, 2..<4])
        #expect(before == KokoroSpeechEngine.signature(voice: .heart, words: words, chunks: [0..<2, 2..<4]))
        #expect(before != KokoroSpeechEngine.signature(voice: .heart, words: words, chunks: [0..<3, 3..<4]))
    }

    /// One second of silence, in the format the helper writes.
    func makeSilentChunk(seconds: Double = 1) throws -> URL {
        let url = root.appending(path: "silence.wav")
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24_000, channels: 1, interleaved: false))
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatInt16, interleaved: false)
        let frames = AVAudioFrameCount(24_000 * seconds)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        try file.write(from: buffer)
        return url
    }

    @Test func aDamagedChunkIsMadeAgainOnTheNextTry() async throws {
        let silence = try makeSilentChunk()
        let second = root.appending(path: "second-try")
        // As the real helper would, this skips a chunk that's already there.
        let environment = try install(python: """
        folder=$(dirname "$3")
        [ -f "$folder/chunk-0.json" ] && exit 0
        cp "\(silence.path)" "$folder/chunk-0.wav"
        if [ -f "\(second.path)" ]; then echo '[]' > "$folder/chunk-0.json"; else touch "\(second.path)"; echo 'NaN' > "$folder/chunk-0.json"; fi
        """)
        let work = root.appending(path: "work", directoryHint: .isDirectory)
        let engine = KokoroSpeechEngine(environment: environment, voice: .heart, workFolder: work)
        let input = ["Hello", "there."]

        await #expect(throws: KokoroError.renderFailed) {
            _ = try await engine.render(words: input, to: root.appending(path: "out.m4a"), onProgress: { _ in })
        }
        #expect(!FileManager.default.fileExists(atPath: work.appending(path: "chunk-0.json").path))

        let result = try await engine.render(words: input, to: root.appending(path: "out2.m4a"), onProgress: { _ in })
        #expect(result.times.count == input.count)
    }

    @Test func cancelingWhileJoiningStopsPromptly() async throws {
        let silence = try makeSilentChunk(seconds: 60)
        let input = (0..<30_000).map { $0 % 20 == 19 ? "word." : "word" }
        let count = SpeechChunker.chunks(for: input).count
        let environment = try install(python: """
        folder=$(dirname "$3")
        i=0
        while [ $i -lt \(count) ]; do
          cp "\(silence.path)" "$folder/chunk-$i.wav"
          echo '[]' > "$folder/chunk-$i.json"
          i=$((i + 1))
        done
        touch "\(root.path)/ready"
        """)
        let work = root.appending(path: "work", directoryHint: .isDirectory)
        let engine = KokoroSpeechEngine(environment: environment, voice: .heart, workFolder: work)
        let output = root.appending(path: "out.m4a")
        let task = Task { try await engine.render(words: input, to: output, onProgress: { _ in }) }

        let ready = root.appending(path: "ready")
        while !FileManager.default.fileExists(atPath: ready.path) {
            try await Task.sleep(for: .milliseconds(20))
        }
        try await Task.sleep(for: .milliseconds(200))
        let start = Date()
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(Date().timeIntervalSince(start) < 3)
        #expect(!FileManager.default.fileExists(atPath: work.path))
    }

    @Test func theSameJobKeepsItsWork() async throws {
        let environment = try install(python: "exit 1")
        let work = root.appending(path: "work", directoryHint: .isDirectory)
        let engine = KokoroSpeechEngine(environment: environment, voice: .heart, workFolder: work)
        _ = try? await engine.render(words: ["Same", "text."], to: root.appending(path: "out.m4a"), onProgress: { _ in })
        let leftover = work.appending(path: "chunk-0.wav")
        try Data("kept".utf8).write(to: leftover)

        _ = try? await engine.render(words: ["Same", "text."], to: root.appending(path: "out.m4a"), onProgress: { _ in })
        #expect(FileManager.default.fileExists(atPath: leftover.path))
    }
}

/// Real Kokoro. These run only when pointed at an installation, with KOKORO_TEST_ROOT.
@Suite(.serialized, .enabled(if: kokoroTestRoot != nil))
struct KokoroSpeechEngineTests {
    static let paragraph = "Today we are going to talk about how memory works, and why most of the ways people study are surprisingly inefficient. When you reread a chapter, the material starts to feel familiar, and that feeling is easy to mistake for actual understanding. Researchers call this the illusion of competence. Dr. Ebbinghaus first described the forgetting curve in 1885, and he found that we lose about 70% of what we learn within a day. So the practical recommendation is simple. Close the book, write down everything you can remember, and check what you missed."

    let environment: KokoroEnvironment
    let root: URL

    init() throws {
        environment = KokoroEnvironment(root: URL(fileURLWithPath: kokoroTestRoot ?? "/nonexistent"))
        root = FileManager.default.temporaryDirectory
            .appending(path: "KokoroSpeechEngineTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func words(repeating count: Int = 1) -> [String] {
        (0..<count).flatMap { _ in Self.paragraph.split(separator: " ").map(String.init) }
    }

    func engine(voice: KokoroVoice = .heart, work: String = "work") -> KokoroSpeechEngine {
        KokoroSpeechEngine(environment: environment, voice: voice, workFolder: root.appending(path: work, directoryHint: .isDirectory))
    }

    func output(_ name: String = "out.m4a") -> URL {
        root.appending(path: name)
    }

    /// Helper processes and workers belonging to this installation.
    func runningHelperCount() throws -> Int {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-f", environment.root.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .split(separator: "\n").count
    }

    func killHelpers() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        process.arguments = ["-9", "-f", environment.root.path]
        try process.run()
        process.waitUntilExit()
    }

    func waitForNoHelpers() async throws {
        let deadline = Date().addingTimeInterval(5)
        while try runningHelperCount() > 0, Date() < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    @Test func rendersEveryWordIntoPlayableCompressedAudio() async throws {
        let input = words(repeating: 2)
        let result = try await engine().render(words: input, to: output(), onProgress: { _ in })
        #expect(result.voiceName == "Kokoro Heart")
        #expect(result.times.count == input.count)
        #expect(zip(result.times, result.times.dropFirst()).allSatisfy { $0.start < $1.start })
        #expect(result.duration > 30)

        let size = try #require(try output().resourceValues(forKeys: [.fileSizeKey]).fileSize)
        #expect(Double(size) < result.duration * 48_000 * 0.3)

        let duration = try await MainActor.run {
            PlayerController(url: output(), isMuted: true)
        }.loadedDuration()
        #expect(abs(duration - result.duration) < 0.25)
        // Nothing left behind once it's finished.
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "work").path))
    }

    @Test func chunksJoinWithoutDrift() async throws {
        // Kokoro phrases each repeat a little differently, so what matters is that highlights
        // are as close to the sound late in the audio as early on, across chunk joins.
        let texts = words(repeating: 8)
        let result = try await engine().render(words: texts, to: output(), onProgress: { _ in })
        #expect(SpeechChunker.chunks(for: texts).count > 1)
        let timed = zip(texts, result.times).map { Word(text: $0, start: $1.start, end: $1.end) }

        let measured = try SoundAlignmentTests().offsets(words: timed, audio: output())
        let third = measured.count / 3
        let early = measured.prefix(third).reduce(0, +) / Double(third)
        let late = measured.suffix(third).reduce(0, +) / Double(third)
        #expect(abs(late - early) < 0.06, "early average \(Int(early * 1000)) ms, late \(Int(late * 1000)) ms")
        let last = try #require(result.times.last)
        #expect(last.start > result.duration * 0.95)
    }

    @Test func timesMatchTheSound() async throws {
        let texts = words(repeating: 4)
        let result = try await engine().render(words: texts, to: output(), onProgress: { _ in })
        let timed = zip(texts, result.times).map { Word(text: $0, start: $1.start, end: $1.end) }

        // "Dr." ends in a period, but no pause follows it, so it isn't a sentence start.
        let withoutTitles = timed.filter { $0.text != "Dr." }
        let measured = try SoundAlignmentTests().offsets(words: withoutTitles, audio: output())
        #expect(measured.count > 10)
        let worst = try #require(measured.map(abs).max())
        let average = measured.reduce(0, +) / Double(measured.count)
        print("Kokoro: \(measured.count) sentence starts, average \(Int(average * 1000)) ms, worst \(Int(worst * 1000)) ms")
        // Soft sounds like the "C" in "Close" rise slowly, so the worst is above the average.
        #expect(worst < 0.15, "worst is \(Int(worst * 1000)) ms")
    }

    @Test func oddTextKeepsEveryWord() async throws {
        let input = "Key results: • first • second — and \u{201C}quoted\u{201D} text, a well-known idea costing $5.50 or 3.5% (e.g. this one). Then 1 2 3 . . . x = y + 2 ; and a final word."
            .split(separator: " ").map(String.init)
        let result = try await engine().render(words: input, to: output(), onProgress: { _ in })
        #expect(result.times.count == input.count)
        #expect(zip(result.times, result.times.dropFirst()).allSatisfy { $0.start < $1.start })
        #expect(try #require(result.times.last).start < result.duration)
    }

    @Test func everyVoiceWorks() async throws {
        for voice in KokoroVoice.all {
            let result = try await engine(voice: voice).render(words: words(), to: output("\(voice.id).m4a"), onProgress: { _ in })
            #expect(result.voiceName == voice.displayName)
            #expect(result.duration > 10)
        }
    }

    @Test func cancelingLeavesNoFilesAndNoProcesses() async throws {
        let engine = engine()
        let input = words(repeating: 60)
        let url = output()
        let task = Task { try await engine.render(words: input, to: url, onProgress: { _ in }) }
        try await Task.sleep(for: .seconds(4))
        #expect(try runningHelperCount() > 0)

        let start = Date()
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(Date().timeIntervalSince(start) < 5)
        try await waitForNoHelpers()
        #expect(try runningHelperCount() == 0)
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "work").path))
    }

    @Test func afterACrashItPicksUpWhereItLeftOff() async throws {
        let engine = engine()
        let input = words(repeating: 24)
        let url = output()
        let progress = Mutex(0.0)
        let task = Task {
            try await engine.render(words: input, to: url, onProgress: { value in
                progress.withLock { $0 = max($0, value) }
            })
        }
        // Wait until some chunks are done, then crash as if the app had been force quit.
        let deadline = Date().addingTimeInterval(60)
        while progress.withLock({ $0 }) < 0.3, Date() < deadline {
            try await Task.sleep(for: .milliseconds(200))
        }
        try killHelpers()
        await #expect(throws: KokoroError.renderFailed) { _ = try await task.value }

        let work = root.appending(path: "work", directoryHint: .isDirectory)
        let finished = try FileManager.default.contentsOfDirectory(atPath: work.path).filter { $0.hasSuffix(".json") && $0.hasPrefix("chunk-") }
        #expect(finished.count >= 1)

        // Audio with no tokens beside it is what a crash mid-write leaves. It must be redone.
        let halfFinished = work.appending(path: finished[0])
        try FileManager.default.removeItem(at: halfFinished)

        let resumed = Mutex<Double?>(nil)
        let result = try await engine.render(words: input, to: url, onProgress: { value in
            resumed.withLock { if $0 == nil { $0 = value } }
        })
        #expect(result.times.count == input.count)
        #expect((resumed.withLock { $0 } ?? 0) > 0, "the first progress report should count finished chunks")
    }

    @Test func workersStopIfTheHelperIsKilled() async throws {
        let work = root.appending(path: "work", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let job = work.appending(path: "job.json")
        let chunks = (0..<40).map { ["id": $0, "text": Self.paragraph] as [String: Any] }
        let payload: [String: Any] = ["chunks": chunks, "voice": "af_heart", "folder": work.path, "workers": 3, "threads": 3]
        try JSONSerialization.data(withJSONObject: payload).write(to: job)

        let process = Process()
        process.executableURL = environment.pythonURL
        process.arguments = [environment.helperURL.path, "render", job.path]
        process.environment = environment.processEnvironment(offline: true)
        process.standardInput = Pipe()
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        // Long enough for the workers to be running.
        try await Task.sleep(for: .seconds(8))
        let running = try runningHelperCount()
        #expect(running > 1, "\(running) running")

        kill(process.processIdentifier, SIGKILL)
        try await waitForNoHelpers()
        #expect(try runningHelperCount() == 0)
    }

    @Test func theHelperStopsWhenItsInputCloses() async throws {
        let work = root.appending(path: "work", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let job = work.appending(path: "job.json")
        let chunks = (0..<40).map { ["id": $0, "text": Self.paragraph] as [String: Any] }
        let payload: [String: Any] = ["chunks": chunks, "voice": "af_heart", "folder": work.path, "workers": 3, "threads": 3]
        try JSONSerialization.data(withJSONObject: payload).write(to: job)

        let process = Process()
        process.executableURL = environment.pythonURL
        process.arguments = [environment.helperURL.path, "render", job.path]
        process.environment = environment.processEnvironment(offline: true)
        let input = Pipe()
        process.standardInput = input
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        try await Task.sleep(for: .seconds(4))
        #expect(try runningHelperCount() > 0)

        try input.fileHandleForWriting.close()
        try await waitForNoHelpers()
        #expect(try runningHelperCount() == 0)
    }
}

extension PlayerController {
    fileprivate func loadedDuration() async throws -> TimeInterval {
        try await waitUntilReady()
        defer { stop() }
        return duration
    }
}
