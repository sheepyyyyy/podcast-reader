import Foundation

/// A word marker from the speech engine, as it reported it.
public struct SpeechMarker: Equatable, Sendable {
    /// Where the word starts in the spoken text.
    public let textLocation: Int
    /// Bytes into its chunk of audio, not into the whole file.
    public let byteOffset: Int
    /// Which chunk of audio it belongs to. The engine's offsets restart with each chunk.
    public let chunk: Int

    public init(textLocation: Int, byteOffset: Int, chunk: Int) {
        self.textLocation = textLocation
        self.byteOffset = byteOffset
        self.chunk = chunk
    }
}

public struct WordTime: Equatable, Sendable {
    public let start: TimeInterval
    public let end: TimeInterval
}

/// Turns the speech engine's markers into a start and end time for every word.
public enum SpeechTimeline {
    /// `chunkStartFrames[k]` is the audio frame where chunk k begins. A word with no usable
    /// marker shares the time between its neighbors. That covers lone symbols, which may
    /// get no marker, and lists, where the engine reports several words at one offset.
    public static func wordTimes(
        wordOffsets: [Int],
        markers: [SpeechMarker],
        chunkStartFrames: [Int64],
        bytesPerFrame: Int,
        sampleRate: Double,
        totalFrames: Int64
    ) -> [WordTime] {
        guard !wordOffsets.isEmpty else { return [] }
        let total = Double(totalFrames) / sampleRate

        var known = [Double?](repeating: nil, count: wordOffsets.count)
        var latest = -1.0
        for marker in markers {
            let base = chunkStartFrames.isEmpty ? 0 : chunkStartFrames[min(marker.chunk, chunkStartFrames.count - 1)]
            let frame = base + Int64(marker.byteOffset / bytesPerFrame)
            let time = Double(frame) / sampleRate
            let word = wordIndex(atLocation: marker.textLocation, offsets: wordOffsets)
            if known[word] == nil, time > latest {
                known[word] = time
                latest = time
            }
        }

        return times(fromKnownStarts: known, total: total)
    }

    /// Word times from the starts that are known, with the rest filled in.
    static func times(fromKnownStarts known: [Double?], total: TimeInterval) -> [WordTime] {
        let starts = filledIn(known, total: total)
        return starts.indices.map { index in
            let end = index + 1 < starts.count ? starts[index + 1] : max(total, starts[index])
            return WordTime(start: starts[index], end: end)
        }
    }

    /// Builds the text to speak and each word's offset in it, in UTF-16 units as the
    /// engine reports them.
    public static func spokenText(for words: [String]) -> (text: String, offsets: [Int]) {
        var offsets: [Int] = []
        offsets.reserveCapacity(words.count)
        var position = 0
        for word in words {
            offsets.append(position)
            position += word.utf16.count + 1
        }
        return (words.joined(separator: " "), offsets)
    }

    /// The last word starting at or before a location.
    private static func wordIndex(atLocation location: Int, offsets: [Int]) -> Int {
        var low = 0
        var high = offsets.count
        while low < high {
            let middle = (low + high) / 2
            if offsets[middle] <= location {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return max(low - 1, 0)
    }

    /// Spreads unknown words evenly between known ones, and gives every word its own moment,
    /// so that clicking one word can never highlight its neighbor.
    private static func filledIn(_ known: [Double?], total: TimeInterval) -> [TimeInterval] {
        var starts = [Double](repeating: 0, count: known.count)
        var anchorIndex = 0
        var anchorTime = known[0] ?? 0
        starts[0] = anchorTime

        for index in 1...known.count {
            let time = index < known.count ? known[index] : Optional(max(total, anchorTime))
            guard let time else { continue }
            let step = (time - anchorTime) / Double(index - anchorIndex)
            for filling in (anchorIndex + 1)..<max(index, anchorIndex + 1) {
                starts[filling] = anchorTime + step * Double(filling - anchorIndex)
            }
            if index < known.count {
                starts[index] = time
            }
            anchorIndex = index
            anchorTime = time
        }

        for index in starts.indices.dropFirst() where starts[index] <= starts[index - 1] {
            starts[index] = starts[index - 1] + 0.001
        }
        return starts
    }
}
