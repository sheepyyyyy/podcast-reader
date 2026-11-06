import AVFoundation
import Foundation
import Testing
@testable import PodcastReaderCore

/// Checks highlight timing against the sound itself. After a pause between sentences, the next
/// word's start time should be where the audio actually gets loud again.
struct SoundAlignmentTests {
    /// Loudness in 5 ms steps, read back from the finished file.
    func loudness(of url: URL) throws -> (values: [Float], step: TimeInterval) {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let samples = try #require(buffer.floatChannelData?[0])
        let window = max(Int(format.sampleRate * 0.005), 1)

        var values: [Float] = []
        var start = 0
        while start + window <= Int(buffer.frameLength) {
            var peak: Float = 0
            for index in start..<(start + window) {
                peak = max(peak, abs(samples[index]))
            }
            values.append(peak)
            start += window
        }
        return (values, Double(window) / format.sampleRate)
    }

    /// How far each word after a sentence end starts from where the sound rises after the pause.
    func offsets(words: [Word], audio: URL) throws -> [TimeInterval] {
        let (values, step) = try loudness(of: audio)
        let threshold = (values.max() ?? 0) * 0.04

        var results: [TimeInterval] = []
        for index in words.indices.dropFirst() where words[index - 1].text.hasSuffix(".") {
            let time = words[index].start
            // Starts inside the pause just before the word and finds the first loud moment.
            // Starting much earlier would catch a dip inside the previous word instead.
            var position = max(Int((time - 0.1) / step), 0)
            let limit = min(Int((time + 0.4) / step), values.count)
            while position < limit, values[position] < threshold { position += 1 }
            if position < limit {
                results.append(Double(position) * step - time)
            }
        }
        return results
    }

    @Test func speechTimesMatchTheSoundInTheCompressedFile() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "SoundAlignment-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        let paragraph = "Memory is rebuilt every time you recall it. Testing yourself makes that path stronger. Spacing your study works better than cramming. Close the book, and write down what you remember. Check what you missed."
        let texts = (0..<8).flatMap { _ in paragraph.split(separator: " ").map(String.init) }

        let result = try await SpeechRenderer().render(words: texts, to: url, onProgress: { _ in })
        let words = zip(texts, result.times).map { Word(text: $0, start: $1.start, end: $1.end) }

        let measured = try offsets(words: words, audio: url)
        #expect(measured.count > 20)
        let worst = try #require(measured.map(abs).max())
        let average = measured.reduce(0, +) / Double(measured.count)
        print("Speech: \(measured.count) sentence starts, average \(Int(average * 1000)) ms, worst \(Int(worst * 1000)) ms")
        #expect(worst < 0.09, "a word's highlight is \(Int(worst * 1000)) ms from its sound")
    }

    @Test func transcribedTimesMatchTheSound() async throws {
        let url = fixture("sample.wav")
        let transcript = try await Transcriber().transcribe(audioAt: url, onProgress: { _ in })

        let measured = try offsets(words: transcript.words, audio: url)
        #expect(!measured.isEmpty)
        let worst = try #require(measured.map(abs).max())
        print("Transcription: \(measured.count) sentence starts, worst offset \(Int(worst * 1000)) ms")
        #expect(worst < 0.25, "a word's highlight is \(Int(worst * 1000)) ms from its sound")
    }
}
