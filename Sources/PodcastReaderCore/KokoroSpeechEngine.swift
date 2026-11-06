@preconcurrency import AVFoundation
import CryptoKit
import Foundation
import Synchronization

/// Reads words aloud with Kokoro by running its helper, then joins the helper's finished
/// chunks into one compressed audio file with a time for every word.
public struct KokoroSpeechEngine: SpeechEngine {
    private static let outputBitRate = 48_000

    private let environment: KokoroEnvironment
    private let voice: KokoroVoice
    private let workFolder: URL

    public init(environment: KokoroEnvironment, voice: KokoroVoice, workFolder: URL) {
        self.environment = environment
        self.voice = voice
        self.workFolder = workFolder
    }

    public func render(
        words: [String],
        to url: URL,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> RenderedSpeech {
        guard environment.isInstalled else { throw KokoroError.notInstalled }
        let chunks = SpeechChunker.chunks(for: words)
        guard !chunks.isEmpty else { throw KokoroError.renderFailed }

        // A long job shouldn't be cut off by the Mac going to sleep.
        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "Preparing a PDF to read aloud"
        )
        defer { ProcessInfo.processInfo.endActivity(activity) }

        do {
            try prepareWorkFolder(words: words, chunks: chunks)
            try await runHelper(words: words, chunks: chunks, onProgress: onProgress)
            try Task.checkCancellation()
            let speech = try await join(words: words, chunks: chunks, to: url)
            try? FileManager.default.removeItem(at: workFolder)
            onProgress(1)
            return speech
        } catch is CancellationError {
            // Canceling means the person is done with it. Quitting doesn't reach here, which
            // is what leaves the finished chunks in place to pick up from.
            try? FileManager.default.removeItem(at: workFolder)
            throw CancellationError()
        }
    }

    /// What finished work must match to be used again. A chunk is trusted to hold particular
    /// words, so this includes where the chunks fall, which an app update could change.
    static func signature(voice: KokoroVoice, words: [String], chunks: [Range<Int>]) -> String {
        let layout = chunks.map { "\($0.lowerBound)-\($0.upperBound)" }.joined(separator: ",")
        let text = [String(KokoroHelper.chunkFormat), voice.id, layout, words.joined(separator: " ")]
            .joined(separator: "\u{0}")
        return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func prepareWorkFolder(words: [String], chunks: [Range<Int>]) throws {
        let manager = FileManager.default
        let signatureURL = workFolder.appending(path: "signature")
        let signature = Self.signature(voice: voice, words: words, chunks: chunks)

        if (try? String(contentsOf: signatureURL, encoding: .utf8)) != signature {
            try? manager.removeItem(at: workFolder)
        }
        do {
            try manager.createDirectory(at: workFolder, withIntermediateDirectories: true)
            try signature.write(to: signatureURL, atomically: true, encoding: .utf8)
        } catch {
            throw KokoroError.renderFailed
        }
    }

    private func runHelper(
        words: [String],
        chunks: [Range<Int>],
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let job = workFolder.appending(path: "job.json")
        do {
            // Written each time, so that app updates reach it without running setup again.
            try KokoroHelper.source.write(to: environment.helperURL, atomically: true, encoding: .utf8)
            let workload = KokoroHelper.workload(
                memoryBytes: ProcessInfo.processInfo.physicalMemory,
                cores: ProcessInfo.processInfo.activeProcessorCount
            )
            let payload: [String: Any] = [
                "chunks": chunks.enumerated().map { index, range in
                    ["id": index, "text": words[range].joined(separator: " ")] as [String: Any]
                },
                "voice": voice.id,
                "folder": workFolder.path,
                "workers": workload.workers,
                "threads": workload.threads,
            ]
            try JSONSerialization.data(withJSONObject: payload).write(to: job)
        } catch {
            throw KokoroError.renderFailed
        }

        let total = Double(words.count)
        let finishedWords = Mutex(0)
        let result = try await KokoroCommand.run(
            environment.pythonURL,
            [environment.helperURL.path, "render", job.path],
            environment: environment.processEnvironment(offline: true),
            onLine: { line in
                guard let data = line.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let done = object["done"] as? Int, chunks.indices.contains(done)
                else { return }
                let count = finishedWords.withLock { value -> Int in
                    value += chunks[done].count
                    return value
                }
                // Joining the chunks takes the last little bit.
                onProgress(Double(count) / total * 0.98)
            }
        )
        guard result.status == 0 else {
            try? result.errorOutput.write(to: environment.logURL, atomically: true, encoding: .utf8)
            throw KokoroError.renderFailed
        }
    }

    /// Off the main actor, as a long document's audio takes a while to compress.
    private func join(words: [String], chunks: [Range<Int>], to url: URL) async throws -> RenderedSpeech {
        let voiceName = voice.displayName
        let folder = workFolder
        let work = Task.detached(priority: .userInitiated) {
            do {
                return try Self.joinChunks(words: words, chunks: chunks, folder: folder, url: url, voiceName: voiceName)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw KokoroError.renderFailed
            }
        }
        // A detached task doesn't hear about cancellation by itself.
        return try await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            work.cancel()
        }
    }

    private static func joinChunks(
        words: [String],
        chunks: [Range<Int>],
        folder: URL,
        url: URL,
        voiceName: String
    ) throws -> RenderedSpeech {
        var output: AVAudioFile?
        var times: [WordTime] = []
        times.reserveCapacity(words.count)
        var elapsed = 0.0

        for (index, range) in chunks.enumerated() {
            try Task.checkCancellation()
            let audioURL = folder.appending(path: "chunk-\(index).wav")
            let tokensURL = folder.appending(path: "chunk-\(index).json")
            do {
                let input = try AVAudioFile(forReading: audioURL)
                let format = input.processingFormat
                if output == nil {
                    output = try AVAudioFile(
                        forWriting: url,
                        settings: [
                            AVFormatIDKey: kAudioFormatMPEG4AAC,
                            AVSampleRateKey: format.sampleRate,
                            AVNumberOfChannelsKey: format.channelCount,
                            AVEncoderBitRateKey: outputBitRate,
                        ],
                        commonFormat: format.commonFormat,
                        interleaved: format.isInterleaved
                    )
                }

                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(format.sampleRate)) else {
                    throw KokoroError.renderFailed
                }
                while input.framePosition < input.length {
                    try input.read(into: buffer)
                    try output?.write(from: buffer)
                }

                let duration = Double(input.length) / format.sampleRate
                let tokens = try JSONDecoder().decode([KokoroToken].self, from: Data(contentsOf: tokensURL))
                let chunkTimes = KokoroTimeline.wordTimes(words: Array(words[range]), tokens: tokens, duration: duration)
                KokoroTimeline.append(chunkTimes, startingAt: elapsed, to: &times)
                elapsed += duration
            } catch {
                // Otherwise a damaged chunk would count as finished on every later try.
                try? FileManager.default.removeItem(at: audioURL)
                try? FileManager.default.removeItem(at: tokensURL)
                throw error
            }
        }
        // Releasing the file is what finishes writing it.
        output = nil
        return RenderedSpeech(times: times, duration: elapsed, voiceName: voiceName)
    }
}
