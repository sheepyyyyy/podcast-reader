@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import Speech

public enum TranscriptionPhase: Sendable, Equatable {
    /// The fraction is between 0 and 1.
    case downloadingModel(Double)
    /// The fraction is between 0 and 1.
    case transcribing(Double)
}

public enum TranscriberError: Error, Equatable {
    case unreadableFile
    case noSpeechFound
    case engineUnavailable
}

/// Turns the speech engine's text runs into clean words with one timing each.
public enum WordAssembler {
    public static func append(run: String, start: TimeInterval?, end: TimeInterval?, to words: inout [Word]) {
        let text = run.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        guard let start, let end else {
            mergeIntoPreviousWord(text, end: nil, words: &words)
            return
        }
        guard text.contains(where: { $0.isLetter || $0.isNumber }) else {
            mergeIntoPreviousWord(text, end: end, words: &words)
            return
        }

        let pieces = text.split(whereSeparator: \.isWhitespace).map(String.init)
        let share = (end - start) / Double(pieces.count)
        for (index, piece) in pieces.enumerated() {
            words.append(Word(
                text: piece,
                start: start + share * Double(index),
                end: start + share * Double(index + 1)
            ))
        }
    }

    private static func mergeIntoPreviousWord(_ text: String, end: TimeInterval?, words: inout [Word]) {
        guard let last = words.popLast() else { return }
        words.append(Word(text: last.text + text, start: last.start, end: end.map { max($0, last.end) } ?? last.end))
    }
}

/// Transcribes an audio file on this Mac using Apple's on-device speech engine.
public struct Transcriber: Sendable {
    private static let locale = Locale(identifier: "en_US")

    public init() {}

    public func transcribe(
        audioAt url: URL,
        onProgress: @escaping @Sendable (TranscriptionPhase) -> Void
    ) async throws -> Transcript {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw TranscriberError.unreadableFile
        }
        let duration = Double(file.length) / file.processingFormat.sampleRate
        guard duration > 0 else { throw TranscriberError.unreadableFile }
        guard SpeechTranscriber.isAvailable else { throw TranscriberError.engineUnavailable }

        let module = SpeechTranscriber(
            locale: Self.locale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: [.audioTimeRange]
        )
        try await installModelIfNeeded(for: module, onProgress: onProgress)
        try Task.checkCancellation()

        let collector = Task {
            try await Self.collectWords(from: module, duration: duration, onProgress: onProgress)
        }
        let analyzer = SpeechAnalyzer(modules: [module])
        do {
            try await withTaskCancellationHandler {
                if let lastSample = try await analyzer.analyzeSequence(from: file) {
                    try await analyzer.finalizeAndFinish(through: lastSample)
                } else {
                    await analyzer.cancelAndFinishNow()
                }
            } onCancel: {
                Task { await analyzer.cancelAndFinishNow() }
            }
        } catch {
            collector.cancel()
            try Task.checkCancellation()
            throw error
        }

        let words = try await collector.value
        try Task.checkCancellation()
        guard !words.isEmpty else { throw TranscriberError.noSpeechFound }
        return Transcript(words: words)
    }

    private func installModelIfNeeded(
        for module: SpeechTranscriber,
        onProgress: @escaping @Sendable (TranscriptionPhase) -> Void
    ) async throws {
        do {
            guard let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) else { return }
            let observation = request.progress.observe(\.fractionCompleted) { progress, _ in
                onProgress(.downloadingModel(progress.fractionCompleted))
            }
            defer { observation.invalidate() }
            try await request.downloadAndInstall()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw TranscriberError.engineUnavailable
        }
    }

    private static func collectWords(
        from module: SpeechTranscriber,
        duration: TimeInterval,
        onProgress: @Sendable (TranscriptionPhase) -> Void
    ) async throws -> [Word] {
        var words: [Word] = []
        var furthest = 0.0

        for try await result in module.results {
            for run in result.text.runs {
                let range = run.audioTimeRange.flatMap { $0.isValid ? $0 : nil }
                WordAssembler.append(
                    run: String(result.text[run.range].characters),
                    start: range?.start.seconds,
                    end: range?.end.seconds,
                    to: &words
                )
            }
            let reached = result.range.end.seconds / duration
            if reached.isFinite {
                furthest = max(furthest, min(reached, 1))
            }
            onProgress(.transcribing(furthest))
        }
        return words.sorted { $0.start < $1.start }
    }
}
