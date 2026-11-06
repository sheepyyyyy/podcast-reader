import Foundation

/// Splits words into pieces that can be rendered separately and joined without a seam,
/// ending at sentence ends wherever possible, where the voice pauses anyway.
public enum SpeechChunker {
    private static let closingMarks = CharacterSet(charactersIn: "\"'”’)]")

    public static func chunks(for words: [String], targetWords: Int = 300) -> [Range<Int>] {
        var chunks: [Range<Int>] = []
        var start = 0

        while start < words.count {
            let end = endOfChunk(startingAt: start, in: words, target: targetWords)
            chunks.append(start..<end)
            start = end
        }
        return chunks
    }

    private static func endOfChunk(startingAt start: Int, in words: [String], target: Int) -> Int {
        let earliest = start + target
        let latest = min(start + target * 2, words.count)
        guard earliest < words.count else { return words.count }

        // The word that reaches the target can end the chunk, hence the - 1.
        let window = (earliest - 1)..<latest
        if let sentenceEnd = window.first(where: { endsWith(".?!", words[$0]) }) {
            return sentenceEnd + 1
        }
        if let comma = window.first(where: { endsWith(",;:", words[$0]) }) {
            return comma + 1
        }
        return latest
    }

    private static func endsWith(_ marks: String, _ word: String) -> Bool {
        guard let last = word.trimmingCharacters(in: closingMarks).last else { return false }
        return marks.contains(last)
    }
}
