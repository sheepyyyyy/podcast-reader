@preconcurrency import AVFoundation
import Foundation

public struct VoiceChoice: Equatable, Sendable {
    public let identifier: String
    public let name: String
    public let language: String
    /// Higher is better.
    public let qualityRank: Int
    /// The voice the system itself picks for this language.
    public let isLanguageDefault: Bool

    public init(identifier: String, name: String, language: String, qualityRank: Int, isLanguageDefault: Bool) {
        self.identifier = identifier
        self.name = name
        self.language = language
        self.qualityRank = qualityRank
        self.isLanguageDefault = isLanguageDefault
    }
}

public enum SpeechError: Error, Equatable {
    case renderFailed
}

public struct RenderedSpeech: Sendable {
    public let times: [WordTime]
    public let duration: TimeInterval
    public let voiceName: String
}

/// Something that can read words aloud into an audio file, with a time for each word.
public protocol SpeechEngine: Sendable {
    func render(
        words: [String],
        to url: URL,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> RenderedSpeech
}

/// Reads words aloud into a compressed audio file, recording when each word is spoken.
public struct SpeechRenderer: SpeechEngine {
    /// A voice must report at least this share of real words to be trusted for highlighting.
    private static let minimumMarkerShare = 0.9
    private static let voicesToTry = 3

    public init() {}

    /// Best first: higher quality, then US English, then the system's own pick, then name.
    public static func ranked(_ voices: [VoiceChoice]) -> [VoiceChoice] {
        voices.sorted { left, right in
            if left.qualityRank != right.qualityRank { return left.qualityRank > right.qualityRank }
            let leftUS = left.language == "en-US"
            let rightUS = right.language == "en-US"
            if leftUS != rightUS { return leftUS }
            if left.isLanguageDefault != right.isLanguageDefault { return left.isLanguageDefault }
            return left.name < right.name
        }
    }

    /// The name of the voice that would be used, such as "Ava (Premium)".
    public static func bestVoiceName() -> String? {
        ranked(installedVoices()).first?.name
    }

    /// English voices on this Mac, leaving out the novelty ones.
    private static func installedVoices() -> [VoiceChoice] {
        let systemPick = AVSpeechSynthesisVoice(language: "en-US")?.identifier
        return AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("en") && !$0.voiceTraits.contains(.isNoveltyVoice) }
            .map { voice in
                VoiceChoice(
                    identifier: voice.identifier,
                    name: voice.name,
                    language: voice.language,
                    qualityRank: voice.quality.rawValue,
                    isLanguageDefault: voice.identifier == systemPick
                )
            }
    }

    public func render(
        words: [String],
        to url: URL,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> RenderedSpeech {
        let (text, offsets) = SpeechTimeline.spokenText(for: words)
        let realWords = words.filter { $0.contains { $0.isLetter || $0.isNumber } }.count

        for voice in Self.ranked(Self.installedVoices()).prefix(Self.voicesToTry) {
            try Task.checkCancellation()
            guard AVSpeechSynthesisVoice(identifier: voice.identifier) != nil else { continue }
            try? FileManager.default.removeItem(at: url)

            let session = RenderSession(text: text, voiceIdentifier: voice.identifier, url: url, onProgress: onProgress)
            let output = await withTaskCancellationHandler {
                await session.run()
            } onCancel: {
                session.cancel()
            }
            try Task.checkCancellation()

            guard output.frames > 0, output.markers.count >= Int(Double(realWords) * Self.minimumMarkerShare) else {
                continue
            }
            let times = SpeechTimeline.wordTimes(
                wordOffsets: offsets,
                markers: output.markers,
                chunkStartFrames: output.chunkStartFrames,
                bytesPerFrame: output.bytesPerFrame,
                sampleRate: output.sampleRate,
                totalFrames: output.frames
            )
            return RenderedSpeech(times: times, duration: Double(output.frames) / output.sampleRate, voiceName: voice.name)
        }
        try? FileManager.default.removeItem(at: url)
        throw SpeechError.renderFailed
    }
}

/// One run of the speech engine. Its callbacks arrive on other threads, so a lock guards the state.
final class RenderSession: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    struct Output {
        var markers: [SpeechMarker] = []
        var chunkStartFrames: [Int64] = [0]
        var frames: Int64 = 0
        var sampleRate = 22_050.0
        var bytesPerFrame = 4
    }

    private let lock = NSLock()
    private let synthesizer = AVSpeechSynthesizer()
    private let utterance: AVSpeechUtterance
    private let url: URL
    private let textLength: Double
    private let onProgress: @Sendable (Double) -> Void

    private var output = Output()
    private var file: AVAudioFile?
    private var furthest = 0.0
    private var continuation: CheckedContinuation<Output, Never>?
    private var isFinished = false

    init(text: String, voiceIdentifier: String, url: URL, onProgress: @escaping @Sendable (Double) -> Void) {
        utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(identifier: voiceIdentifier)
        self.url = url
        textLength = max(Double(text.utf16.count), 1)
        self.onProgress = onProgress
        super.init()
        synthesizer.delegate = self
    }

    func run() async -> Output {
        await withCheckedContinuation { continuation in
            // Canceling can get here first, and then nothing would ever resume this.
            let alreadyFinished = lock.withLock { () -> Output? in
                if isFinished { return output }
                self.continuation = continuation
                return nil
            }
            if let alreadyFinished {
                continuation.resume(returning: alreadyFinished)
                return
            }
            synthesizer.write(utterance, toBufferCallback: { [weak self] buffer in
                self?.handle(buffer)
            }, toMarkerCallback: { [weak self] markers in
                self?.handle(markers)
            })
        }
    }

    func cancel() {
        synthesizer.stopSpeaking(at: .immediate)
        finish()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        finish()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        finish()
    }

    private func handle(_ buffer: AVAudioBuffer) {
        guard let pcm = buffer as? AVAudioPCMBuffer else { return }
        lock.withLock {
            guard !isFinished else { return }
            // An empty buffer separates chunks, and the engine's offsets restart after it.
            guard pcm.frameLength > 0 else {
                output.chunkStartFrames.append(output.frames)
                return
            }
            if file == nil {
                let format = pcm.format
                output.sampleRate = format.sampleRate
                output.bytesPerFrame = Int(format.streamDescription.pointee.mBytesPerFrame)
                file = try? AVAudioFile(
                    forWriting: url,
                    settings: [
                        AVFormatIDKey: kAudioFormatMPEG4AAC,
                        AVSampleRateKey: format.sampleRate,
                        AVNumberOfChannelsKey: format.channelCount,
                        AVEncoderBitRateKey: 40_000,
                    ],
                    commonFormat: format.commonFormat,
                    interleaved: format.isInterleaved
                )
            }
            do {
                try file?.write(from: pcm)
                output.frames += Int64(pcm.frameLength)
            } catch {
                output.frames = 0
                isFinished = true
                resume()
            }
        }
    }

    private func handle(_ markers: [AVSpeechSynthesisMarker]) {
        let progress: Double? = lock.withLock {
            guard !isFinished else { return nil }
            for marker in markers where marker.mark == .word {
                // The empty buffer that ends a chunk always arrives before the next chunk's
                // markers, so this is the chunk a marker belongs to. Offsets alone can't say:
                // several words can share one.
                output.markers.append(SpeechMarker(
                    textLocation: marker.textRange.location,
                    byteOffset: marker.byteSampleOffset,
                    chunk: output.chunkStartFrames.count - 1
                ))
                furthest = max(furthest, Double(marker.textRange.location) / textLength)
            }
            return min(furthest, 1)
        }
        if let progress {
            onProgress(progress)
        }
    }

    private func finish() {
        lock.withLock {
            guard !isFinished else { return }
            isFinished = true
            resume()
        }
    }

    /// Closes the file, which finishes writing it, and hands back the results.
    /// The lock must be held.
    private func resume() {
        file = nil
        continuation?.resume(returning: output)
        continuation = nil
    }
}
