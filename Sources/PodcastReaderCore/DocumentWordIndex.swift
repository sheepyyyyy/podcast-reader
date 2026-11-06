import Foundation

/// Finds which spoken word sits at a character on a PDF page, for clicks.
/// Returns nil for anything that isn't a spoken word, such as a skipped header or a gap.
public struct DocumentWordIndex: Sendable {
    private struct Entry: Sendable {
        let start: Int
        let end: Int
        let word: Int
    }

    private let pages: [Int: [Entry]]

    public init(locations: [WordLocation]) {
        var pages: [Int: [Entry]] = [:]
        for (word, location) in locations.enumerated() {
            for range in location.ranges {
                pages[location.page, default: []].append(
                    Entry(start: range.location, end: range.location + range.length, word: word)
                )
            }
        }
        self.pages = pages.mapValues { $0.sorted { $0.start < $1.start } }
    }

    public func wordIndex(page: Int, character: Int) -> Int? {
        guard let entries = pages[page] else { return nil }
        var low = 0
        var high = entries.count
        while low < high {
            let middle = (low + high) / 2
            if entries[middle].start <= character {
                low = middle + 1
            } else {
                high = middle
            }
        }
        guard low > 0, character < entries[low - 1].end else { return nil }
        return entries[low - 1].word
    }
}
