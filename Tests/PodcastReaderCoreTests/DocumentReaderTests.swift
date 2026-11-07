import Foundation
import PDFKit
import Testing
@testable import PodcastReaderCore

struct DocumentReaderTests {
    func words(_ name: String) throws -> [ReadableWord] {
        try DocumentReader.read(pdfAt: fixture(name)).words
    }

    @Test func wordsKeepTheirPunctuationAndOrder() throws {
        let texts = try words("document.pdf").map(\.text)
        #expect(Array(texts.prefix(3)) == ["Memory", "is", "rebuilt"])
        #expect(texts.contains("it."))
        #expect(texts.last == "word")
    }

    @Test func headersAndPageNumbersAreSkipped() throws {
        let texts = try words("document.pdf").map(\.text)
        #expect(!texts.contains("Chapter"))
        #expect(!texts.contains("3"))
    }

    @Test func rangesPointAtTheRightTextOnTheRightPage() throws {
        let pdf = try #require(PDFDocument(url: fixture("document.pdf")))
        for word in try words("document.pdf") {
            let text = try #require(pdf.page(at: word.location.page)?.string) as NSString
            let range = try #require(word.location.ranges.first)
            #expect(text.substring(with: range.nsRange) == word.text)
        }
    }

    @Test func wordsSitWhereTheyAreDrawn() throws {
        let pdf = try #require(PDFDocument(url: fixture("document.pdf")))
        for word in try words("document.pdf") {
            let page = try #require(pdf.page(at: word.location.page))
            let range = try #require(word.location.ranges.first)
            let bounds = try #require(page.selection(for: range.nsRange)).bounds(for: page)
            #expect(bounds.width > 0 && bounds.height > 0)
        }
    }

    @Test func columnsReadLeftThenRight() throws {
        let text = try words("two-columns.pdf").map(\.text).joined(separator: " ")
        let left = try #require(text.range(of: "Left column begins"))
        let right = try #require(text.range(of: "Right column begins"))
        #expect(left.lowerBound < right.lowerBound)
    }

    @Test func hyphenatedWordsJoinWithTwoRanges() throws {
        let joined = try #require(try words("hyphenated.pdf").first { $0.text == "rebuilding" })
        #expect(joined.location.ranges.count == 2)
    }

    @Test func hyphenBeforeACapitalStaysSeparate() throws {
        let texts = try words("hyphenated.pdf").map(\.text)
        #expect(texts.contains("well-"))
        #expect(texts.contains("Known"))
    }

    @Test func blankPagesArePassedOver() throws {
        let document = try DocumentReader.read(pdfAt: fixture("blank-page.pdf"))
        #expect(document.pageCount == 3)
        #expect(Set(document.words.map(\.location.page)) == [0, 2])
    }

    @Test func aSuperscriptIsOnTheSameLine() {
        let word = CGRect(x: 0, y: 100, width: 40, height: 12)
        let raised = CGRect(x: 42, y: 105, width: 5, height: 7)
        #expect(DocumentReader.isSameLine(word, raised))
    }

    @Test func aSubscriptIsOnTheSameLine() {
        let word = CGRect(x: 0, y: 100, width: 40, height: 12)
        let lowered = CGRect(x: 42, y: 97, width: 5, height: 7)
        #expect(DocumentReader.isSameLine(word, lowered))
    }

    @Test func theNextLineIsNotTheSameLine() {
        let word = CGRect(x: 0, y: 100, width: 40, height: 14)
        let below = CGRect(x: 0, y: 87, width: 40, height: 14)
        #expect(!DocumentReader.isSameLine(word, below))
    }

    @Test func emptyFramesAreNotTheSameLine() {
        #expect(!DocumentReader.isSameLine(.zero, CGRect(x: 0, y: 0, width: 10, height: 10)))
    }

    // MARK: Words that a PDF's text breaks apart

    /// Made by Chrome, whose PDFs macOS reads with line breaks inside words, such as "w" then "ritten".
    @Test func wordsBrokenApartInAChromePDFAreWhole() throws {
        let text = try words("chrome.pdf").map(\.text).joined(separator: " ")
        #expect(text == "Exam Three Study Guide. Listening Version. This version is written to be read out loud. There is a limit on how much you can borrow, which is similar to a loan minus the interest. When the summer window opens, the bank might lower the minimum.")
    }

    @Test func aRejoinedWordIsHighlightedWhole() throws {
        let pdf = try #require(PDFDocument(url: fixture("chrome.pdf")))
        let written = try #require(try words("chrome.pdf").first { $0.text == "written" })
        let text = try #require(pdf.page(at: written.location.page)?.string) as NSString
        #expect(written.location.ranges.count > 1)
        #expect(written.location.ranges.map { text.substring(with: $0.nsRange) }.joined() == "written")
    }

    @Test func piecesThatTouchOnOneLineAreOneWord() {
        let first = CGRect(x: 0, y: 100, width: 10, height: 12)
        #expect(DocumentReader.join(separator: "\n", first: first, second: CGRect(x: 10, y: 100, width: 30, height: 12)) == .touching)
        // A space's width apart, it's the next word.
        #expect(DocumentReader.join(separator: "\n", first: first, second: CGRect(x: 13, y: 100, width: 30, height: 12)) == .separate)
        // A real space, or the next line, always separates.
        #expect(DocumentReader.join(separator: " ", first: first, second: CGRect(x: 10, y: 100, width: 30, height: 12)) == .separate)
        #expect(DocumentReader.join(separator: "\n", first: first, second: CGRect(x: 0, y: 86, width: 30, height: 12)) == .separate)
        // Drawn over the end of the one before.
        let wide = CGRect(x: 0, y: 100, width: 16, height: 12)
        #expect(DocumentReader.join(separator: "\n", first: wide, second: CGRect(x: 6, y: 100, width: 10, height: 12)) == .overlapping)
    }

    /// Pieces drawn over each other can be one word or two, so a dictionary decides.
    @Test func overlappingPiecesJoinOnlyIntoARealWord() {
        #expect(DocumentReader.joinsOverlap("li", "mit"))
        #expect(DocumentReader.joinsOverlap("si", "milar"))
        #expect(DocumentReader.joinsOverlap("li", "mited,"))
        #expect(DocumentReader.joinsOverlap("A", "n"))
        #expect(!DocumentReader.joinsOverlap("loan", "minus"))
        #expect(!DocumentReader.joinsOverlap("bank", "might"))
        #expect(!DocumentReader.joinsOverlap("exam.", "A"))
        #expect(!DocumentReader.joinsOverlap("×", "usual"))
    }

    @Test func ligaturesBecomePlainLetters() {
        #expect(DocumentReader.spokenForm(of: "\u{FB01}nd") == "find")
        #expect(DocumentReader.spokenForm(of: "e\u{FB00}ect") == "effect")
        #expect(DocumentReader.spokenForm(of: "o\u{FB03}ce") == "office")
        #expect(DocumentReader.spokenForm(of: "plain.") == "plain.")
    }

    @Test func errors() {
        #expect(throws: DocumentError.noReadableText) { try DocumentReader.read(pdfAt: fixture("scanned.pdf")) }
        #expect(throws: DocumentError.passwordProtected) { try DocumentReader.read(pdfAt: fixture("locked.pdf")) }
        #expect(throws: DocumentError.unreadable) { try DocumentReader.read(pdfAt: fixture("notaudio.mp3")) }
    }
}
