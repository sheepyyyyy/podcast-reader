# PDF Read-Aloud Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a PDF be added to Podcast Reader and read aloud on the real page, with each word highlighted as it's spoken.

**Architecture:** A PDF becomes a `Lecture` with generated audio, a transcript and word locations, so playback, search, bookmarks and controls are reused. New units in `PodcastReaderCore` extract words and render speech, and a new `PDFPageView` replaces `CaptionsView` for these lectures.

**Tech Stack:** Swift 6, SwiftUI, PDFKit, `AVSpeechSynthesizer`, `AVAudioFile`, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-11-05-pdf-read-aloud-design.md`

## Global Constraints

- Run tests with `scripts/test.sh`, and build with `scripts/build-app.sh`. Bare `swift test` is unreliable with the Command Line Tools.
- No third-party dependencies, and no network use. Not a git repository, so there are no commit steps.
- `Lecture.document` must be optional, because lectures already saved must keep loading.
- Marker offsets are bytes, and reset at each chunk. The spec's "What testing already showed" section is binding.
- Audio: AAC in `.m4a`, mono, 22,050 Hz, about 40 kbps.
- Highlight color is `Palette.bookmarkTick` (`#6FF5CF`).
- All copy in the spec's "When things go wrong" table is exact.

## Review Focus

1. **The podcast already in the library:** a lecture saved before this feature must still load with its transcript and position. Test in Task 1.
2. **Drift on long documents:** the highlight must not fall behind by page 300, which is what forgetting the chunk resets would cause. Tests in Tasks 5 and 6.
3. **Symbols with no marker:** a lone `•` or `—` may get no speech marker, and must not break the times of the words around it. Test in Task 5.
4. **Canceling a long render:** nothing may be left behind, including a partial `.m4a`. Test in Task 7.
5. **Clicks on things that aren't words:** clicking a skipped header, a margin or a gap must do nothing rather than jump somewhere surprising. Test in Task 4.

---

### Task 1: Data model and import kinds

**Files:**
- Modify: `Sources/PodcastReaderCore/Library.swift`, `Sources/PodcastReaderCore/ReaderRules.swift`
- Test: `Tests/PodcastReaderCoreTests/DocumentDataTests.swift`, `Tests/PodcastReaderCoreTests/ReaderRulesTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public struct PageTextRange: Codable, Hashable, Sendable { public let location: Int; public let length: Int }
  public struct WordLocation: Codable, Hashable, Sendable { public let page: Int; public let ranges: [PageTextRange] }
  public struct DocumentInfo: Codable, Hashable, Sendable { public var voiceName: String; public var pageCount: Int; public var locations: [WordLocation] }
  // Lecture gains: public var document: DocumentInfo?
  public enum ImportKind: Equatable, Sendable { case audio, document }
  extension AudioImport { public static func kind(of url: URL) -> ImportKind? }
  extension Library {
      public func generatedAudioURL(forID id: String) -> URL
      public func documentURL(for lecture: Lecture) -> URL?
  }
  ```
  For a PDF lecture, `audioURL(for:)` returns the generated audio if it exists, and `documentURL(for:)` uses the existing bookmark logic. `remove(id:)` also deletes the generated audio. For an audio lecture, `documentURL(for:)` is nil.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func lectureSavedBeforeThisFeatureStillLoads() throws {
    // JSON of a Lecture with no "document" key, with position 12.5 and one word.
    // Decodes with document == nil, position == 12.5, and that word intact.
}
@Test func documentInfoRoundTrips() throws { /* save and load keep voiceName, pageCount and locations */ }
@Test func removingADocumentLectureDeletesItsAudioButNotThePDF() throws
@Test func audioURLOfADocumentIsTheGeneratedAudio() throws
@Test func audioURLOfADocumentWithNoGeneratedAudioIsNil() throws
@Test func documentURLFindsAMovedPDF() throws
@Test func audioLectureHasNoDocumentURL() throws
@Test func importKinds() {
    #expect(AudioImport.kind(of: URL(fileURLWithPath: "/a.PDF")) == .document)
    #expect(AudioImport.kind(of: URL(fileURLWithPath: "/a.mp3")) == .audio)
    #expect(AudioImport.kind(of: URL(fileURLWithPath: "/a.txt")) == nil)
}
```

- [ ] **Step 2: Run to verify they fail.** `scripts/test.sh --filter "DocumentDataTests|ReaderRulesTests"`. Expected: fails with "cannot find 'DocumentInfo'".
- [ ] **Step 3: Implement.** `isSupported` becomes `kind(of:) != nil`.
- [ ] **Step 4: Run to verify they pass.** Same command. Expected: all pass, and existing `LibraryTests` still pass.

---

### Task 2: Running text filter and PDF fixtures

**Files:**
- Create: `Sources/PodcastReaderCore/RunningTextFilter.swift`
- Create: `scripts/make-pdf-fixtures.swift`, and in `Tests/PodcastReaderCoreTests/Fixtures/`: `document.pdf`, `two-columns.pdf`, `hyphenated.pdf`, `blank-page.pdf`, `scanned.pdf`, `locked.pdf`
- Test: `Tests/PodcastReaderCoreTests/RunningTextFilterTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public struct MarginLine: Hashable, Sendable {
      public let page: Int
      public let text: String
      /// 0 at the top of the page, 1 at the bottom.
      public let verticalPosition: Double
  }
  public enum RunningTextFilter {
      public static func skippedLines(in lines: [MarginLine]) -> Set<MarginLine>
  }
  ```

- [ ] **Step 1: Write `scripts/make-pdf-fixtures.swift` and run it.** It draws with Core Text:
  - `document.pdf`: 5 pages, each with the header `Chapter 4: How memory works`, a page number at the bottom, and body text beginning `Memory is rebuilt every time you recall it.` on page 1 and ending with `the last word` on page 5.
  - `two-columns.pdf`: 2 columns, left beginning `Left column begins here.`, right beginning `Right column begins here.`
  - `hyphenated.pdf`: lines ending in `re-` then `building`, and one ending in `well-` then `Known`.
  - `blank-page.pdf`: 3 pages with an empty page 2.
  - `scanned.pdf`: one image-only page.
  - `locked.pdf`: `document.pdf` saved with a user password, through `PDFDocument.write(to:withOptions:)`.

- [ ] **Step 2: Write the failing tests**

```swift
func line(_ page: Int, _ text: String, _ y: Double) -> MarginLine { MarginLine(page: page, text: text, verticalPosition: y) }

@Test func bareNumbersInTheMarginAreSkipped() {
    let lines = [line(0, "12", 0.96), line(1, "Page 13", 0.96)]
    #expect(RunningTextFilter.skippedLines(in: lines) == Set(lines))
}
@Test func numbersInTheBodyAreKept() {
    #expect(RunningTextFilter.skippedLines(in: [line(0, "12", 0.5)]).isEmpty)
}
@Test func textRepeatedOnThreePagesIsSkipped() {
    let lines = (0..<3).map { line($0, "Chapter 4: How memory works", 0.03) }
    #expect(RunningTextFilter.skippedLines(in: lines).count == 3)
}
@Test func textRepeatedOnTwoPagesIsKept() {
    let lines = (0..<2).map { line($0, "Chapter 4", 0.03) }
    #expect(RunningTextFilter.skippedLines(in: lines).isEmpty)
}
@Test func repeatsIgnoreDigitsAndCase() {
    let lines = [line(0, "Lecture 1 notes", 0.03), line(1, "LECTURE 2 NOTES", 0.03), line(2, "Lecture 3 notes", 0.03)]
    #expect(RunningTextFilter.skippedLines(in: lines).count == 3)
}
@Test func repeatsInTheBodyAreKept() {
    let lines = (0..<4).map { line($0, "Key idea", 0.5) }
    #expect(RunningTextFilter.skippedLines(in: lines).isEmpty)
}
@Test func marginsAreTheOuterTenPercent() {
    #expect(RunningTextFilter.skippedLines(in: [line(0, "7", 0.11)]).isEmpty)
    #expect(RunningTextFilter.skippedLines(in: [line(0, "7", 0.09)]).count == 1)
    #expect(RunningTextFilter.skippedLines(in: [line(0, "7", 0.91)]).count == 1)
}
```

- [ ] **Step 3: Run to verify they fail.** `scripts/test.sh --filter RunningTextFilterTests`. Expected: "cannot find 'MarginLine'".
- [ ] **Step 4: Implement.** Page numbers match digits, or `page` plus digits, case-insensitively. Repeats key on lowercased text with digits removed, and count distinct pages.
- [ ] **Step 5: Run to verify they pass.**

---

### Task 3: Document reader

**Files:**
- Create: `Sources/PodcastReaderCore/DocumentReader.swift`
- Test: `Tests/PodcastReaderCoreTests/DocumentReaderTests.swift`

**Interfaces:**
- Consumes: `RunningTextFilter`, `WordLocation`.
- Produces:
  ```swift
  public struct ReadableWord: Hashable, Sendable { public let text: String; public let location: WordLocation }
  public struct ReadableDocument: Sendable { public let words: [ReadableWord]; public let pageCount: Int }
  public enum DocumentError: Error, Equatable { case unreadable, passwordProtected, noReadableText }
  public enum DocumentReader { public static func read(pdfAt url: URL) throws -> ReadableDocument }
  ```

- [ ] **Step 1: Write the failing tests**

```swift
@Test func wordsKeepTheirPunctuationAndOrder() throws {
    let words = try DocumentReader.read(pdfAt: fixture("document.pdf")).words.map(\.text)
    #expect(Array(words.prefix(3)) == ["Memory", "is", "rebuilt"])
    #expect(words.contains("it."))
    #expect(words.last == "word")
}
@Test func headersAndPageNumbersAreSkipped() throws {
    let words = try DocumentReader.read(pdfAt: fixture("document.pdf")).words.map(\.text)
    #expect(!words.contains("Chapter"))
    #expect(!words.contains("3"))
}
@Test func rangesPointAtTheRightTextOnTheRightPage() throws {
    // For every word, PDFDocument page(location.page).string substring at its range
    // equals the word's text (for one-range words).
}
@Test func wordsSitWhereTheyAreDrawn() throws {
    // page.selection(for: range) has non-empty bounds for every word.
}
@Test func columnsReadLeftThenRight() throws {
    let text = try DocumentReader.read(pdfAt: fixture("two-columns.pdf")).words.map(\.text).joined(separator: " ")
    let left = try #require(text.range(of: "Left column begins"))
    let right = try #require(text.range(of: "Right column begins"))
    #expect(left.lowerBound < right.lowerBound)
}
@Test func hyphenatedWordsJoinWithTwoRanges() throws {
    let words = try DocumentReader.read(pdfAt: fixture("hyphenated.pdf")).words
    let joined = try #require(words.first { $0.text == "rebuilding" })
    #expect(joined.location.ranges.count == 2)
}
@Test func hyphenBeforeACapitalStaysSeparate() throws {
    let words = try DocumentReader.read(pdfAt: fixture("hyphenated.pdf")).words.map(\.text)
    #expect(words.contains("well-"))
    #expect(words.contains("Known"))
}
@Test func blankPagesArePassedOver() throws {
    let document = try DocumentReader.read(pdfAt: fixture("blank-page.pdf"))
    #expect(document.pageCount == 3)
    #expect(Set(document.words.map(\.location.page)) == [0, 2])
}
@Test func errors() {
    #expect(throws: DocumentError.noReadableText) { try DocumentReader.read(pdfAt: fixture("scanned.pdf")) }
    #expect(throws: DocumentError.passwordProtected) { try DocumentReader.read(pdfAt: fixture("locked.pdf")) }
    #expect(throws: DocumentError.unreadable) { try DocumentReader.read(pdfAt: fixture("notaudio.mp3")) }
}
```

- [ ] **Step 2: Run to verify they fail.** `scripts/test.sh --filter DocumentReaderTests`. Expected: "cannot find 'DocumentReader'".
- [ ] **Step 3: Implement.** Split `page.string` on whitespace with `NSString` ranges, so offsets match `page.selection(for:)`. Group tokens into lines by `bounds(for:)` and a shared baseline within 2 points. Pass margin lines to `RunningTextFilter`, across the whole document. A line break between tokens means the original text had a newline between them, which is what hyphen joining checks.
- [ ] **Step 4: Run to verify they pass.**

---

### Task 4: Word lookup for clicks

**Files:**
- Create: `Sources/PodcastReaderCore/DocumentWordIndex.swift`
- Test: `Tests/PodcastReaderCoreTests/DocumentWordIndexTests.swift`

**Interfaces:**
- Produces: `public struct DocumentWordIndex: Sendable { public init(locations: [WordLocation]); public func wordIndex(page: Int, character: Int) -> Int? }`

- [ ] **Step 1: Write the failing tests**

```swift
let index = DocumentWordIndex(locations: [
    WordLocation(page: 0, ranges: [PageTextRange(location: 10, length: 5)]),
    WordLocation(page: 0, ranges: [PageTextRange(location: 16, length: 3), PageTextRange(location: 25, length: 8)]),
    WordLocation(page: 2, ranges: [PageTextRange(location: 0, length: 4)]),
])
@Test func findsAWord() { #expect(index.wordIndex(page: 0, character: 12) == 0) }
@Test func wordEdges() { #expect(index.wordIndex(page: 0, character: 10) == 0); #expect(index.wordIndex(page: 0, character: 15) == nil) }
@Test func gapsAndSkippedTextAreNil() { #expect(index.wordIndex(page: 0, character: 3) == nil) }
@Test func bothPartsOfAHyphenatedWordMatch() { #expect(index.wordIndex(page: 0, character: 17) == 1); #expect(index.wordIndex(page: 0, character: 30) == 1) }
@Test func unknownPageIsNil() { #expect(index.wordIndex(page: 1, character: 0) == nil) }
@Test func anUnknownCharacterIsNil() { #expect(index.wordIndex(page: 0, character: -1) == nil) }
```

- [ ] **Step 2: Run to verify they fail.** `scripts/test.sh --filter DocumentWordIndexTests`.
- [ ] **Step 3: Implement** with per-page sorted ranges and binary search.
- [ ] **Step 4: Run to verify they pass.**

---

### Task 5: Speech timeline

**Files:**
- Create: `Sources/PodcastReaderCore/SpeechTimeline.swift`
- Test: `Tests/PodcastReaderCoreTests/SpeechTimelineTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public struct SpeechMarker: Equatable, Sendable { public let textLocation: Int; public let byteOffset: Int }
  public struct WordTime: Equatable, Sendable { public let start: TimeInterval; public let end: TimeInterval }
  public enum SpeechTimeline {
      /// `chunkStartFrames[k]` is the audio frame where chunk k begins. A marker whose offset
      /// isn't greater than the previous one's begins the next chunk.
      public static func wordTimes(
          wordOffsets: [Int], markers: [SpeechMarker], chunkStartFrames: [Int64],
          bytesPerFrame: Int, sampleRate: Double, totalFrames: Int64
      ) -> [WordTime]
      /// Builds the text to speak and each word's offset in it.
      public static func spokenText(for words: [String]) -> (text: String, offsets: [Int])
  }
  ```

- [ ] **Step 1: Write the failing tests**

```swift
func times(_ markers: [(Int, Int)], offsets: [Int], chunks: [Int64] = [0], total: Int64 = 1000) -> [WordTime] {
    SpeechTimeline.wordTimes(
        wordOffsets: offsets,
        markers: markers.map { SpeechMarker(textLocation: $0.0, byteOffset: $0.1) },
        chunkStartFrames: chunks, bytesPerFrame: 4, sampleRate: 100, totalFrames: total
    )
}
@Test func offsetsAreBytesPerFrame() {
    #expect(times([(0, 0), (5, 400)], offsets: [0, 5]).map(\.start) == [0, 1])
}
@Test func timesAccumulateAcrossChunks() {
    let result = times([(0, 0), (5, 400), (9, 0), (14, 400)], offsets: [0, 5, 9, 14], chunks: [0, 300])
    #expect(result.map(\.start) == [0, 1, 3, 4])
}
@Test func aWordEndsWhereTheNextStarts() {
    #expect(times([(0, 0), (5, 400)], offsets: [0, 5]).first?.end == 1)
}
@Test func theLastWordEndsAtTheEndOfTheAudio() {
    #expect(times([(0, 0)], offsets: [0], total: 800).last?.end == 8)
}
@Test func aWordWithNoMarkerSharesTheGapEvenly() {
    let result = times([(0, 0), (10, 800)], offsets: [0, 5, 10])
    #expect(result.map(\.start) == [0, 1, 2])
}
@Test func wordsBeforeTheFirstMarkerStartAtZero() {
    #expect(times([(5, 400)], offsets: [0, 5]).first?.start == 0)
}
@Test func timesNeverGoBackward() {
    // Markers out of order for the same chunk still produce non-decreasing starts.
}
@Test func spokenTextIsWordsJoinedBySpaces() {
    let (text, offsets) = SpeechTimeline.spokenText(for: ["One", "two."])
    #expect(text == "One two.")
    #expect(offsets == [0, 4])
}
```

- [ ] **Step 2: Run to verify they fail.** `scripts/test.sh --filter SpeechTimelineTests`.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run to verify they pass.**

---

### Task 6: Speech renderer

**Files:**
- Create: `Sources/PodcastReaderCore/SpeechRenderer.swift`
- Test: `Tests/PodcastReaderCoreTests/SpeechRendererTests.swift`

**Interfaces:**
- Consumes: `SpeechTimeline`, `SpeechMarker`, `WordTime`.
- Produces:
  ```swift
  public struct VoiceChoice: Equatable, Sendable { public let identifier: String; public let name: String; public let language: String; public let qualityRank: Int }
  public enum SpeechError: Error, Equatable { case renderFailed }
  public struct RenderedSpeech: Sendable { public let times: [WordTime]; public let duration: TimeInterval; public let voiceName: String }
  public struct SpeechRenderer: Sendable {
      public init()
      /// Best first: higher quality, then en-US, then name.
      public static func ranked(_ voices: [VoiceChoice]) -> [VoiceChoice]
      public func render(words: [String], to url: URL, onProgress: @escaping @Sendable (Double) -> Void) async throws -> RenderedSpeech
  }
  ```

- [ ] **Step 1: Write the failing tests**

```swift
@Test func voicesRankByQualityThenUSEnglish() {
    // A premium en-GB ranks above an enhanced en-US, which ranks above a default en-US, then a default en-GB.
}
@Test func rendersEveryWordWithOrderedTimes() async throws {
    // 60 words of known text: times.count == 60, non-decreasing, duration > 5.
}
@Test func timesReachTheEndAcrossChunks() async throws {
    // Enough text for several chunks (the spec's paragraph repeated 10 times):
    // last word's start is within 2 s of duration and above 90% of it.
}
@Test func outputIsCompressedAndPlayable() async throws {
    // File extension m4a, and size under 30% of the uncompressed equivalent.
    // PlayerController's duration is within 0.2 s of RenderedSpeech.duration.
}
@Test func symbolsWithNoMarkerDoNotBreakTheTimes() async throws {
    // Words including "•" and "—": times.count == words.count and non-decreasing.
}
@Test func progressNeverGoesBackward() async throws
@Test func cancellingStopsAndThrows() async {
    // Cancel at once on long text: throws CancellationError without hanging.
}
```

- [ ] **Step 2: Run to verify they fail.** `scripts/test.sh --filter SpeechRendererTests`.
- [ ] **Step 3: Implement.**
  - Use `AVSpeechSynthesizer.write(_:toBufferCallback:toMarkerCallback:)`, and finish on the delegate's `didFinish`. That's confirmed to fire, whereas zero-length buffers occur between chunks. A zero-length buffer records the current frame count as the next chunk's start.
  - Write through `AVAudioFile(forWriting:settings:commonFormat:interleaved:)` with AAC settings, then release the file before returning.
  - Guard state with a lock, because the callbacks arrive off the main thread.
  - Try voices in ranked order: if a voice produces no audio, or markers for under 90% of words, delete the file and try the next, up to 3 voices, then throw `.renderFailed`.
  - On cancellation, call `stopSpeaking(at: .immediate)`, and resume on `didCancel`.
- [ ] **Step 4: Run to verify they pass.**

---

### Task 7: Document importer

**Files:**
- Create: `Sources/PodcastReaderCore/DocumentImporter.swift`
- Test: `Tests/PodcastReaderCoreTests/DocumentImporterTests.swift`

**Interfaces:**
- Consumes: `DocumentReader`, `SpeechRenderer`, `Library`.
- Produces:
  ```swift
  public struct DocumentImporter: Sendable {
      public init(library: Library)
      public func importDocument(at url: URL, onProgress: @escaping @Sendable (Double) -> Void) async throws -> Lecture
      /// Renders the audio again, keeping bookmarks and position on the same words.
      public func regenerateAudio(for lecture: Lecture, onProgress: @escaping @Sendable (Double) -> Void) async throws -> Lecture
  }
  ```

- [ ] **Step 1: Write the failing tests**

```swift
@Test func importsAPDFEndToEnd() async throws {
    // document.pdf: lecture.document?.locations.count == transcript.words.count;
    // title is the file name; the JSON and .m4a both exist; audioURL(for:) resolves.
}
@Test func transcriptWordsMatchTheReadableWords() async throws
@Test func scannedPDFThrowsAndSavesNothing() async throws
@Test func cancellingLeavesNothingBehind() async throws {
    // Cancel while rendering: no .json and no .m4a in the library directory.
}
@Test func regeneratingKeepsBookmarksAndPosition() async throws {
    // Bookmark word 5, position at word 8's start. Delete the .m4a and regenerate:
    // bookmark.wordIndex == 5 with time matching the new word 5, and position
    // equal to the new start of word 8.
}
```

- [ ] **Step 2: Run to verify they fail.** `scripts/test.sh --filter DocumentImporterTests`.
- [ ] **Step 3: Implement.** Render to a temporary file beside the final one, and move it into place only on success. Read the PDF off the main thread.
- [ ] **Step 4: Run to verify they pass.**

---

### Task 8: Importing from the app

**Files:**
- Modify: `Sources/PodcastReaderUI/AppModel.swift`, `Sources/PodcastReaderUI/HomeView.swift`, `Sources/PodcastReaderUI/ReaderModel.swift`, `Sources/PodcastReaderUI/MissingAudioView.swift`
- Test: `Tests/PodcastReaderUITests/DocumentImportTests.swift`, and update the changed message in `AppModelTests.swift`

**Interfaces:**
- Consumes: `DocumentImporter`, `AudioImport.kind(of:)`, `DocumentError`.
- Produces: `ImportState.working(title:phase:isDocument:)`, and `ReaderModel.documentURL: URL?`, passed as a new `documentURL:` init parameter defaulting to nil.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func importingAPDFOpensTheReader() async throws   // reader.lecture.document != nil; reader.documentURL is set
@Test func importingTheSamePDFAgainKeepsProgress() async throws
@Test func scannedPDFShowsItsMessage() async throws
    // "This PDF has no readable text. It may be a scan, which isn't supported yet."
@Test func lockedPDFShowsItsMessage() async throws
    // "This PDF is password protected. Remove the password and try again."
@Test func damagedPDFShowsTheUnreadableMessage() async throws
    // "This file couldn't be opened. Try an MP3, M4A, WAV or PDF file."
@Test func movedPDFShowsTheLocatePrompt() async throws
@Test func locatingADifferentPDFIsRefused() async throws
@Test func missingAudioIsPreparedAgainKeepingBookmarks() async throws
@Test func readingControlsWorkOnAPDF() async throws
    // Skip, jump to a word, bookmark, search and position saving all work on a PDF lecture.
```

- [ ] **Step 2: Run to verify they fail.** `scripts/test.sh --filter DocumentImportTests`.
- [ ] **Step 3: Implement.**
  - Route by `AudioImport.kind(of:)`, and allow only one import at a time, as now.
  - `open`: a PDF lecture with no `documentURL` goes to `Screen.missingAudio`. One with a PDF but no audio runs `regenerateAudio` through the import state, then opens.
  - `HomeView`: the prompt becomes `Drop an audio file or PDF here`, the picker adds `.pdf`, working text becomes `Preparing <title>…` for documents, and rows show `doc.text` or `waveform`.
  - `MissingAudioView`: for documents, show `This PDF has moved.` and restrict the picker to `.pdf`.
  - Add a failure message `Preparing this PDF didn't finish. Try again.` with `Try again`.
- [ ] **Step 4: Run to verify they pass.**

---

### Task 9: The page view

**Files:**
- Create: `Sources/PodcastReaderUI/PDFPageView.swift`
- Modify: `Sources/PodcastReaderUI/ReaderView.swift`, `Sources/ReaderSnapshots/main.swift`

**Interfaces:**
- Consumes: `ReaderModel` (`activeWord`, `isFollowing`, `jump(toWord:)`, `documentURL`), `DocumentWordIndex`, `WordLocation`.
- Produces: `struct PDFPageView: NSViewRepresentable { init(model: ReaderModel) }`

- [ ] **Step 1: Implement `PDFPageView`**
  - `PDFView` with `displayMode = .singlePageContinuous`, `autoScales = true`, and a clear background over `AuroraBackground`.
  - On `activeWord` change, build a `PDFSelection` from the word's ranges with `color = NSColor(Palette.bookmarkTick)`, and set `highlightedSelections`. Only assign when the word changes.
  - Following: when `isFollowing` and the word's bounds are outside the visible area, call `go(to:on:)` so that it sits about 20% from the top. Also do this when `isFollowing` turns back on, and on appearing.
  - Clicks: an `NSClickGestureRecognizer` with `delaysPrimaryMouseButtonEvents = false`. Convert the point with `page(for:nearest: false)`, `convert(_:to:)` and `characterIndex(at:)`, then look up the word in `DocumentWordIndex`. A nil result does nothing. Drag selection stays with `PDFView`.
  - Scrolling by hand already stops following, through `noteScrollWheel`.
- [ ] **Step 2: Use it in `ReaderView`.** Lectures with a `document` show `PDFPageView` instead of `CaptionsView`, with no edge fade, inset above the control bar when it's visible, and clear of the back button at the top.
- [ ] **Step 3: Add a `reader-pdf.png` render to `ReaderSnapshots screens`**, plus a window-size and a smallest-size render with the side panel open.
- [ ] **Step 4: Verify from the images.**

Run: `swift run ReaderSnapshots screens` with `DEVELOPER_DIR` set as in the README, then open the PNGs.
Expected: a white page on the Aurora background, one word highlighted in mint on the right line, controls below, nothing clipped at the smallest size.

- [ ] **Step 5: Add `ReaderSnapshots pdf-landing <output> <pdf>`.** It imports a long PDF, jumps to far words and bursts, and checks from each rendered image that mint pixels are visible in the page area. It exits with an error on a miss.

Expected: all jumps land.

---

### Task 10: Full verification

**Files:**
- Modify: `README.md`, and update `Sources/ReaderSnapshots/main.swift` if needed

- [ ] **Step 1: Try real PDFs found on this Mac.** Read-only, search `/System/Library` and `/Library/Documentation` for PDFs that aren't the user's own. Run each through `DocumentReader`, and report word counts, any with no text, and a sample of odd tokens.
- [ ] **Step 2: Stress test.** Generate a 300-page PDF and import it for real. Report render time, file size, search time, and word-by-word highlight update time.

Expected: under about 10 minutes to render, and highlight updates staying under one frame on average.

- [ ] **Step 3: Update the README** with PDF use, voices and how to download better ones.
- [ ] **Step 4: Run everything clean.** `rm -rf build .build`, then `scripts/test.sh` and `scripts/build-app.sh`. Expected: all pass, and the app launches with no crash reports.
- [ ] **Step 5: Confirm the user's library survives.** Read-only, decode the existing saved lecture with the new `Lecture` type.
- [ ] **Step 6: Final review by a fresh reviewer, then one fix pass.** Report honestly what only a person can check: real clicks, real PDFs, the voice, and audio sync.
