# Podcast Reader Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a native Mac app that turns an audio file into huge, clickable, word-synced captions for studying lectures.

**Architecture:** A UI-free library, `PodcastReaderCore`, holds the data, rules, persistence, transcription and playback, all tested with Swift Testing. A thin SwiftUI app, `PodcastReader`, sits on top. A script assembles the build into an ad hoc signed `.app`.

**Tech Stack:** Swift 6, SwiftUI, Swift Package Manager, `SpeechAnalyzer` and `SpeechTranscriber`, `AVPlayer`, CryptoKit, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-11-05-podcast-reader-design.md`

## Global Constraints

- `// swift-tools-version: 6.2`, `platforms: [.macOS(.v26)]`. Tools version 6.0 fails on `.v26`.
- No third-party dependencies. No network use except the macOS-managed speech model download.
- English only: `Locale(identifier: "en_US")`.
- Supported imports: MP3, M4A, WAV.
- The project path contains a space (`Podcast reader`), so every script path must be quoted.
- This folder is not a git repository and version control wasn't requested, so tasks have no commit steps.
- `ld: warning: search path ... not found` during `swift build` is harmless and comes from the Command Line Tools.
- All interface text is sentence case with no exclamation marks.

Reader colors, from the spec:

| Use | Value |
|---|---|
| Background | `#0A1C4A` |
| Past lines | `#4F74B5` |
| Upcoming lines and unspoken words | `#9FC2FF` |
| Spoken words | white |

## Review Focus

1. **Variable-bitrate MP3s:** clicking a word must land on that word, not a second or two away. Test in Task 6.
2. **Typing in the search box:** Space, B and the arrow keys must type or move the cursor, not control playback. Tests in Task 3, check in Task 10.
3. **Speed and end of audio:** changing speed while paused must not start playback, and pressing play after the end must restart from the beginning. Tests in Task 6.
4. **Locating the wrong file:** choosing a different file for a moved lecture must be refused rather than leaving captions out of sync. Test in Task 4.
5. **Odd imports:** `.MP3` in capitals must work, and a second file dropped during transcription must not disturb the running job. Test in Task 3, check in Task 7.

---

### Task 1: Package, transcript model and line breaking

**Files:**
- Create: `Package.swift`
- Create: `Sources/PodcastReaderCore/Transcript.swift`
- Create: `Sources/PodcastReaderCore/LineBuilder.swift`
- Create: `Sources/PodcastReader/PodcastReaderApp.swift` (a minimal `@main` app with an empty window, so the package builds)
- Test: `Tests/PodcastReaderCoreTests/LineBuilderTests.swift`

**Interfaces:**
- Produces:
  - `struct Word: Codable, Hashable, Sendable { let text: String; let start: TimeInterval; let end: TimeInterval }`
  - `struct Line: Codable, Hashable, Sendable, Identifiable { let id: Int; let wordRange: Range<Int> }`
  - `struct Transcript: Codable, Hashable, Sendable { let words: [Word]; let lines: [Line]; init(words: [Word]); func lineIndex(forWord: Int) -> Int; func text(ofLine: Int) -> String }`
  - `enum LineBuilder { static func lines(for words: [Word]) -> [Line] }`
  - All public, as for every Core type in this plan.

- [ ] **Step 1: Write `Package.swift` and the failing tests**

Targets: `PodcastReaderCore`, executable `PodcastReader` depending on Core, and test target `PodcastReaderCoreTests`.

```swift
struct LineBuilderTests {
    // Words 0.3 s long, 0.1 s apart, unless a test sets its own times.
    func make(_ texts: [String]) -> [Word] { /* builds evenly spaced words */ }
    func sizes(_ w: [Word]) -> [Int] { LineBuilder.lines(for: w).map(\.wordRange.count) }

    @Test func breaksAfterSentenceEnd() { #expect(sizes(make(["Hello", "world.", "Next"])) == [2, 1]) }
    @Test func breaksAfterQuestionAndExclamation() { #expect(sizes(make(["Why?", "Stop!", "Go"])) == [1, 1, 1]) }
    @Test func breaksAfterPeriodInsideClosingQuote() { #expect(sizes(make(["He", "said", "done.\"", "Then"])) == [3, 1]) }
    @Test func decimalDoesNotBreak() { #expect(sizes(make(["About", "3.5", "percent"])) == [3]) }

    @Test func pauseOver0_7Breaks() {
        let w = [Word(text: "a", start: 0, end: 1), Word(text: "b", start: 1.71, end: 2)]
        #expect(LineBuilder.lines(for: w).count == 2)
    }
    @Test func pauseOfExactly0_7DoesNotBreak() {
        let w = [Word(text: "a", start: 0, end: 1), Word(text: "b", start: 1.7, end: 2)]
        #expect(LineBuilder.lines(for: w).count == 1)
    }

    @Test func commaBreaksAtSixWords() { #expect(sizes(make(["1","2","3","4","5","6,","7"])) == [6, 1]) }
    @Test func commaIgnoredBeforeSixWords() { #expect(sizes(make(["1","2","3","4","5,","6","7"])) == [7]) }
    @Test func colonAndSemicolonBreakAtSixWords() {
        #expect(sizes(make(["1","2","3","4","5","6:","7","8","9","10","11","12;","13"])) == [6, 6, 1])
    }

    @Test func hardCapAtTwelve() { #expect(sizes(make((1...30).map(String.init))) == [12, 12, 6]) }
    @Test func emptyInput() { #expect(LineBuilder.lines(for: []).isEmpty) }

    @Test func linesCoverEveryWordOnce() {
        let t = Transcript(words: make(["One.", "Two", "three,", "four.", "Five"]))
        #expect(t.lines.flatMap { Array($0.wordRange) } == Array(0..<5))
        #expect(t.lines.map(\.id) == Array(0..<t.lines.count))
        #expect(t.lineIndex(forWord: 2) == 1)
        #expect(t.text(ofLine: 1) == "Two three, four.")
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter LineBuilderTests`
Expected: FAIL with "cannot find 'LineBuilder' in scope".

- [ ] **Step 3: Implement `Transcript.swift` and `LineBuilder.swift`**

Strip trailing `"`, `'`, `”`, `’`, `)` and `]` from the previous word before checking its final punctuation. The four rules and their values are in the spec's "Line breaking rules" section.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter LineBuilderTests`
Expected: all pass.

---

### Task 2: Active word lookup and transcript search

**Files:**
- Create: `Sources/PodcastReaderCore/WordClock.swift`
- Create: `Sources/PodcastReaderCore/SearchIndex.swift`
- Test: `Tests/PodcastReaderCoreTests/WordClockTests.swift`
- Test: `Tests/PodcastReaderCoreTests/SearchIndexTests.swift`

**Interfaces:**
- Consumes: `Word`, `Transcript`.
- Produces:
  - `struct WordClock: Sendable { init(words: [Word]); func activeWordIndex(at time: TimeInterval) -> Int? }`
  - `struct SearchMatch: Hashable, Sendable, Identifiable { let wordRange: Range<Int>; let time: TimeInterval; let context: String; var id: Int { wordRange.lowerBound } }`
  - `struct SearchIndex: Sendable { init(transcript: Transcript); func search(_ query: String) -> [SearchMatch] }`

- [ ] **Step 1: Write the failing tests**

```swift
struct WordClockTests {
    let clock = WordClock(words: [
        Word(text: "a", start: 1, end: 2), Word(text: "b", start: 2, end: 3), Word(text: "c", start: 10, end: 11),
    ])
    @Test func beforeFirstWordIsNil() { #expect(clock.activeWordIndex(at: 0.5) == nil) }
    @Test func onBoundaryIsTheNewWord() { #expect(clock.activeWordIndex(at: 2) == 1) }
    @Test func inPauseKeepsLastSpokenWord() { #expect(clock.activeWordIndex(at: 6) == 1) }
    @Test func afterLastWordKeepsLastWord() { #expect(clock.activeWordIndex(at: 500) == 2) }
    @Test func emptyIsNil() { #expect(WordClock(words: []).activeWordIndex(at: 1) == nil) }
}

struct SearchIndexTests {
    // Each word 1 s long, so a word's time equals its index.
    let index = SearchIndex(transcript: Transcript(words:
        "Memory is rebuilt, and memory's strength grows when testing. Don't cram the night before an exam or a test"
            .split(separator: " ").enumerated()
            .map { Word(text: String($1), start: Double($0), end: Double($0) + 1) }))

    @Test func ignoresCase() { #expect(index.search("MEMORY").first?.time == 0) }
    @Test func ignoresPunctuationInTranscript() { #expect(index.search("rebuilt").count == 1) }
    @Test func ignoresPunctuationInQuery() { #expect(index.search("dont").count == 1); #expect(index.search("don't").count == 1) }
    @Test func matchesPhraseAcrossWords() {
        let m = index.search("the night before")
        #expect(m.count == 1); #expect(m[0].wordRange == 11..<14); #expect(m[0].time == 11)
    }
    @Test func lastQueryWordMatchesAsPrefix() { #expect(index.search("test").map(\.time) == [8, 18]) }
    @Test func earlierQueryWordsMustMatchWhole() { #expect(index.search("te cram").isEmpty) }
    @Test func contextIncludesFiveWordsEachSide() {
        #expect(index.search("cram")[0].context == "strength grows when testing. Don't cram the night before an exam")
    }
    @Test func noMatchIsEmpty() { #expect(index.search("zebra").isEmpty) }
    @Test func blankOrPunctuationQueryIsEmpty() { #expect(index.search("  ").isEmpty); #expect(index.search("?!").isEmpty) }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter "WordClockTests|SearchIndexTests"`
Expected: FAIL with "cannot find 'WordClock' in scope".

- [ ] **Step 3: Implement both**

`WordClock` uses binary search for the last word whose `start` is at or before the time. `SearchIndex` normalizes by lowercasing, folding diacritics and removing punctuation, in both the transcript and the query, and matches query tokens against consecutive normalized words, with the final token as a prefix.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter "WordClockTests|SearchIndexTests"`
Expected: all pass.

---

### Task 3: Reader rules

**Files:**
- Create: `Sources/PodcastReaderCore/ReaderRules.swift`
- Test: `Tests/PodcastReaderCoreTests/ReaderRulesTests.swift`

**Interfaces:**
- Produces:
  - `enum PlaybackRules { static let speeds: [Double]; static func nextSpeed(after: Double) -> Double; static func skipTarget(current: TimeInterval, delta: TimeInterval, duration: TimeInterval) -> TimeInterval }`
  - `enum CaptionMetrics { static func fontSize(forWidth: Double) -> Double }`
  - `enum AudioImport { static func isSupported(_ url: URL) -> Bool }`
  - `enum TimeFormat { static func string(_ seconds: TimeInterval) -> String }`
  - `enum ReaderCommand: Equatable, Sendable { case togglePlay, skip(TimeInterval), addBookmark, openSearch, openBookmarks, closePanel }`
  - `struct KeyModifiers: OptionSet, Sendable` with `.shift`, `.command`, `.control`, `.option`
  - `enum ReaderKeys { static func command(keyCode: UInt16, modifiers: KeyModifiers, isTyping: Bool) -> ReaderCommand? }`

- [ ] **Step 1: Write the failing tests**

```swift
struct ReaderRulesTests {
    @Test func speedsCycleInOrder() {
        #expect(PlaybackRules.speeds == [0.5, 0.75, 1, 1.25, 1.5, 1.75, 2])
        #expect(PlaybackRules.nextSpeed(after: 1) == 1.25)
        #expect(PlaybackRules.nextSpeed(after: 2) == 0.5)
    }
    @Test func skipsStopAtBothEnds() {
        #expect(PlaybackRules.skipTarget(current: 5, delta: -10, duration: 100) == 0)
        #expect(PlaybackRules.skipTarget(current: 95, delta: 30, duration: 100) == 100)
        #expect(PlaybackRules.skipTarget(current: 50, delta: 10, duration: 100) == 60)
    }
    @Test func fontSizeIs5_5PercentClamped() {
        #expect(abs(CaptionMetrics.fontSize(forWidth: 1000) - 55) < 0.001)
        #expect(CaptionMetrics.fontSize(forWidth: 300) == 28)
        #expect(CaptionMetrics.fontSize(forWidth: 5000) == 110)
    }
    @Test func supportedAudioIgnoresExtensionCase() {
        for name in ["a.mp3", "a.MP3", "a.m4a", "a.Wav", "my lecture.v2.mp3"] {
            #expect(AudioImport.isSupported(URL(fileURLWithPath: "/tmp/\(name)")))
        }
        for name in ["a.txt", "a.mov", "mp3"] {
            #expect(!AudioImport.isSupported(URL(fileURLWithPath: "/tmp/\(name)")))
        }
    }
    @Test func timestamps() {
        #expect(TimeFormat.string(0) == "0:00")
        #expect(TimeFormat.string(65) == "1:05")
        #expect(TimeFormat.string(3723) == "1:02:03")
        #expect(TimeFormat.string(-1) == "0:00")
        #expect(TimeFormat.string(.nan) == "0:00")
    }

    let space: UInt16 = 49, left: UInt16 = 123, right: UInt16 = 124, esc: UInt16 = 53, b: UInt16 = 11, f: UInt16 = 3

    @Test func playbackKeys() {
        #expect(ReaderKeys.command(keyCode: space, modifiers: [], isTyping: false) == .togglePlay)
        #expect(ReaderKeys.command(keyCode: left, modifiers: [], isTyping: false) == .skip(-10))
        #expect(ReaderKeys.command(keyCode: right, modifiers: [], isTyping: false) == .skip(10))
        #expect(ReaderKeys.command(keyCode: left, modifiers: .shift, isTyping: false) == .skip(-30))
        #expect(ReaderKeys.command(keyCode: right, modifiers: .shift, isTyping: false) == .skip(30))
        #expect(ReaderKeys.command(keyCode: b, modifiers: [], isTyping: false) == .addBookmark)
    }
    @Test func panelKeys() {
        #expect(ReaderKeys.command(keyCode: f, modifiers: .command, isTyping: false) == .openSearch)
        #expect(ReaderKeys.command(keyCode: b, modifiers: .command, isTyping: false) == .openBookmarks)
        #expect(ReaderKeys.command(keyCode: esc, modifiers: [], isTyping: false) == .closePanel)
    }
    @Test func typingLeavesPlaybackKeysAlone() {
        for key in [space, left, right, b] {
            #expect(ReaderKeys.command(keyCode: key, modifiers: [], isTyping: true) == nil)
        }
        #expect(ReaderKeys.command(keyCode: left, modifiers: .shift, isTyping: true) == nil)
        #expect(ReaderKeys.command(keyCode: esc, modifiers: [], isTyping: true) == .closePanel)
        #expect(ReaderKeys.command(keyCode: f, modifiers: .command, isTyping: true) == .openSearch)
    }
    @Test func otherModifiersPassThrough() {
        #expect(ReaderKeys.command(keyCode: f, modifiers: [.command, .control], isTyping: false) == nil)
        #expect(ReaderKeys.command(keyCode: left, modifiers: .command, isTyping: false) == nil)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter ReaderRulesTests`
Expected: FAIL with "cannot find 'PlaybackRules' in scope".

- [ ] **Step 3: Implement `ReaderRules.swift`**

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter ReaderRulesTests`
Expected: all pass.

---

### Task 4: Library

**Files:**
- Create: `Sources/PodcastReaderCore/Library.swift`
- Test: `Tests/PodcastReaderCoreTests/LibraryTests.swift`

**Interfaces:**
- Consumes: `Transcript`.
- Produces:
  - `struct Bookmark: Codable, Hashable, Sendable, Identifiable { let id: UUID; let wordIndex: Int; let time: TimeInterval; let text: String }`
  - `struct Lecture: Codable, Sendable, Identifiable { let id: String; var title: String; var duration: TimeInterval; var addedAt: Date; var lastOpenedAt: Date; var fileBookmark: Data?; var filePath: String; var transcript: Transcript; var bookmarks: [Bookmark]; var position: TimeInterval }`
  - `extension Lecture { mutating func addBookmark(wordIndex: Int) -> Bool; mutating func removeBookmark(id: UUID) }`
  - `enum LibraryError: Error, Equatable { case differentAudio }`
  - `struct Library: Sendable { init(directory: URL); static var defaultDirectory: URL; func lectureID(forAudioAt: URL) throws -> String; func makeLecture(audioAt: URL, transcript: Transcript, duration: TimeInterval) throws -> Lecture; func load(id: String) throws -> Lecture?; func save(_: Lecture) throws; func remove(id: String) throws; func all() -> [Lecture]; func audioURL(for: Lecture) -> URL?; func relocate(_: Lecture, to: URL) throws -> Lecture }`

- [ ] **Step 1: Write the failing tests**

Each test uses a fresh temporary directory, with a helper `writeAudio(name:bytes:)` that writes arbitrary bytes. Transcription isn't involved, so the files needn't be real audio.

```swift
struct LibraryTests {
    @Test func saveThenLoadRoundTrips()          // Every field survives, including bookmarks and position
    @Test func allIsSortedByLastOpenedNewestFirst()
    @Test func damagedFileIsSkipped() {
        // Save two lectures, write garbage to a third .json file:
        // all().count == 2, and nothing throws
    }
    @Test func removeDeletesTheSavedLectureButNotTheAudio()
    @Test func sameBytesAtTwoPathsGiveSameID()
    @Test func differentSizeGivesDifferentID()   // Same first megabyte, longer tail
    @Test func differentStartGivesDifferentID()
    @Test func fileSmallerThanOneMegabyteWorks()
    @Test func movedAudioIsStillFound()          // Move the file: audioURL(for:) returns the new path
    @Test func deletedAudioIsNil()
    @Test func trashedAudioCountsAsMissing()     // A resolved path containing "/.Trash/" returns nil
    @Test func relocateAcceptsTheSameAudio() {
        // relocate(lecture, to: copyAtNewPath) updates filePath and fileBookmark
    }
    @Test func relocateRefusesDifferentAudio() {
        // #expect(throws: LibraryError.differentAudio) { try library.relocate(lecture, to: otherFile) }
    }
    @Test func addBookmarkAddsOnceAndKeepsTimeOrder() {
        // Add word 5, then word 2, then word 5 again: third call returns false,
        // and bookmarks are in order [word 2, word 5] with time and line text filled in
    }
    @Test func removeBookmarkRemovesOnlyThatOne()
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter LibraryTests`
Expected: FAIL with "cannot find 'Library' in scope".

- [ ] **Step 3: Implement `Library.swift`**

- `defaultDirectory` is `~/Library/Application Support/Podcast Reader/lectures/`, created in `init`.
- The ID is the lowercase hex SHA-256, via CryptoKit, of the decimal file size, then `":"`, then the first 1,048,576 bytes. Read only that much from disk.
- Files are named `<id>.json` and written with `.atomic`, so a crash can't leave half a file.
- `makeLecture` sets the title to the file name without its extension, position to 0, and both dates to now.
- `audioURL(for:)` tries the bookmark, then `filePath`, and returns nil if neither leads to an existing file outside the Trash.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter LibraryTests`
Expected: all pass.

---

### Task 5: Transcriber

**Files:**
- Create: `scripts/make-fixtures.sh`
- Create: `Tests/PodcastReaderCoreTests/Fixtures/` (`sample.mp3`, `sample_vbr.mp3`, `sample.m4a`, `sample.wav`, `silence.mp3`, `notaudio.mp3`)
- Create: `Sources/PodcastReaderCore/Transcriber.swift`
- Modify: `Package.swift` (add `resources: [.copy("Fixtures")]` to the test target)
- Create: `Tests/PodcastReaderCoreTests/TestSupport.swift`, with `func fixture(_ name: String) -> URL { Bundle.module.resourceURL!.appending(path: "Fixtures/\(name)") }`
- Test: `Tests/PodcastReaderCoreTests/TranscriberTests.swift`

**Interfaces:**
- Consumes: `Word`, `Transcript`.
- Produces:
  - `enum TranscriptionPhase: Sendable, Equatable { case downloadingModel(Double); case transcribing(Double) }` (fraction from 0 to 1)
  - `enum TranscriberError: Error, Equatable { case unreadableFile, noSpeechFound, engineUnavailable }`
  - `enum WordAssembler { static func append(run: String, start: TimeInterval?, end: TimeInterval?, to: inout [Word]) }`
  - `struct Transcriber: Sendable { init(); func transcribe(audioAt: URL, onProgress: @escaping @Sendable (TranscriptionPhase) -> Void) async throws -> Transcript }`

- [ ] **Step 1: Write and run `scripts/make-fixtures.sh`**

It speaks this sentence with `say`, then uses `ffmpeg` to write all the fixtures:

> Memory is rebuilt every time you recall it. Testing yourself makes that path stronger. Spacing your study over several days works better than cramming.

- `sample.mp3`: `-b:a 128k`
- `sample_vbr.mp3`: `-c:a libmp3lame -q:a 4`
- `sample.m4a` and `sample.wav`
- `silence.mp3`: `-f lavfi -i anullsrc=r=44100:cl=mono -t 15`
- `notaudio.mp3`: the text `this is not audio`

Expected: `ls` shows all six files, none larger than 1 MB except possibly `sample.wav`.

- [ ] **Step 2: Write the failing tests**

```swift
struct TranscriberTests {
    @Test(arguments: ["sample.mp3", "sample_vbr.mp3", "sample.m4a", "sample.wav"])
    func transcribesWithOrderedTimes(file: String) async throws {
        let t = try await Transcriber().transcribe(audioAt: fixture(file), onProgress: { _ in })
        let lower = t.words.map { $0.text.lowercased() }
        #expect(lower.contains { $0.hasPrefix("memory") })
        #expect(lower.contains { $0.hasPrefix("stronger") })
        #expect(t.words.allSatisfy { !$0.text.contains(" ") && $0.end >= $0.start })
        #expect(zip(t.words, t.words.dropFirst()).allSatisfy { $0.start <= $1.start })
    }
    @Test func reportsProgressUpToNearlyComplete() async throws {
        // Collect fractions: they never decrease, and the last .transcribing value is above 0.5
    }
    @Test func silenceThrowsNoSpeech() async {
        await #expect(throws: TranscriberError.noSpeechFound) {
            try await Transcriber().transcribe(audioAt: fixture("silence.mp3"), onProgress: { _ in })
        }
    }
    @Test func nonAudioThrowsUnreadable() async {
        await #expect(throws: TranscriberError.unreadableFile) {
            try await Transcriber().transcribe(audioAt: fixture("notaudio.mp3"), onProgress: { _ in })
        }
    }
    @Test func cancellingThrowsCancellationError() async {
        // Start in a Task, cancel at once: throws CancellationError and returns, not a hang
    }

    @Test func assemblerTrimsAndSkipsBlank() {
        var w: [Word] = []
        WordAssembler.append(run: " hello", start: 1, end: 2, to: &w)
        WordAssembler.append(run: "   ", start: 2, end: 3, to: &w)
        #expect(w == [Word(text: "hello", start: 1, end: 2)])
    }
    @Test func assemblerMergesPunctuationOnlyRunIntoPreviousWord() {
        var w = [Word(text: "hello", start: 1, end: 2)]
        WordAssembler.append(run: ",", start: 2, end: 2.1, to: &w)
        #expect(w == [Word(text: "hello,", start: 1, end: 2.1)])
    }
    @Test func assemblerMergesUntimedRunIntoPreviousWord() {
        var w = [Word(text: "well", start: 1, end: 2)]
        WordAssembler.append(run: "-known", start: nil, end: nil, to: &w)
        #expect(w == [Word(text: "well-known", start: 1, end: 2)])
    }
    @Test func assemblerSplitsMultiWordRunEvenly() {
        var w: [Word] = []
        WordAssembler.append(run: "two words", start: 0, end: 2, to: &w)
        #expect(w == [Word(text: "two", start: 0, end: 1), Word(text: "words", start: 1, end: 2)])
    }
}
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `swift test --filter TranscriberTests`
Expected: FAIL with "cannot find 'Transcriber' in scope".

- [ ] **Step 4: Implement `Transcriber.swift`**

Configure: `SpeechTranscriber(locale: Locale(identifier: "en_US"), transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange])`.

Order of work:

1. Open `AVAudioFile(forReading:)`. Any failure throws `.unreadableFile`.
2. If `SpeechTranscriber.isAvailable` is false, throw `.engineUnavailable`.
3. Call `AssetInventory.assetInstallationRequest(supporting:)`. If it returns a request, run `downloadAndInstall()` and report its `Progress` as `.downloadingModel`. Don't branch on `AssetInventory.status`, which reported `.supported` even though transcription worked during testing.
4. Run `analyzer.analyzeSequence(from: file)`, then `finalizeAndFinish(through:)`, while a child task reads `transcriber.results`.
5. For each result, feed `result.text.runs` through `WordAssembler` using `run.audioTimeRange` (an untimed run with no previous word is dropped), and report `.transcribing(result.range.end.seconds / duration)`, clamped to 0...1 and never decreasing.
6. If no words were collected, throw `.noSpeechFound`.
7. Check cancellation between results, and call `cancelAndFinishNow()` on the way out.

No `Info.plist` or permission entry is required: testing confirmed the engine runs without one.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test --filter TranscriberTests`
Expected: all pass.

---

### Task 6: Player controller

**Files:**
- Create: `Sources/PodcastReaderCore/PlayerController.swift`
- Test: `Tests/PodcastReaderCoreTests/PlayerControllerTests.swift`

This lives in Core rather than the app, as the spec's table showed, so that it can be tested. Nothing about its behavior changes.

**Interfaces:**
- Consumes: `PlaybackRules`, and the fixtures from Task 5.
- Produces:
  ```swift
  @MainActor @Observable public final class PlayerController {
      public init(url: URL, isMuted: Bool = false)
      public private(set) var currentTime: TimeInterval
      public private(set) var duration: TimeInterval
      public private(set) var isPlaying: Bool
      public private(set) var rate: Double
      public var onTick: (@MainActor (TimeInterval) -> Void)?
      public func waitUntilReady() async throws
      public func play()
      public func pause()
      public func togglePlay()
      public func seek(to: TimeInterval)
      public func skip(by: TimeInterval)
      public func setRate(_: Double)
      public func stop()
  }
  ```

- [ ] **Step 1: Write the failing tests**

```swift
@MainActor struct PlayerControllerTests {
    func ready(_ name: String = "sample.mp3") async throws -> PlayerController {
        let p = PlayerController(url: fixture(name), isMuted: true)
        try await p.waitUntilReady()
        return p
    }

    @Test func loadsDuration() async throws { #expect(try await ready().duration > 1) }

    @Test func vbrDurationMatchesDecoder() async throws {
        let url = fixture("sample_vbr.mp3")
        let file = try AVAudioFile(forReading: url)
        let decoded = Double(file.length) / file.processingFormat.sampleRate
        #expect(abs(try await ready("sample_vbr.mp3").duration - decoded) < 0.1)
    }
    @Test func vbrSeekLandsExactly() async throws {
        let p = try await ready("sample_vbr.mp3")
        p.seek(to: 3.21)
        try await Task.sleep(for: .milliseconds(300))
        #expect(abs(p.currentTime - 3.21) < 0.05)
    }

    @Test func skipStopsAtBothEnds() async throws {
        let p = try await ready()
        p.skip(by: -30); #expect(p.currentTime == 0)
        p.skip(by: 9_999); #expect(p.currentTime == p.duration)
    }
    @Test func changingSpeedWhilePausedStaysPaused() async throws {
        let p = try await ready()
        p.setRate(1.5)
        #expect(p.rate == 1.5); #expect(!p.isPlaying)
    }
    @Test func changingSpeedWhilePlayingKeepsPlaying() async throws {
        let p = try await ready()
        p.play(); p.setRate(2)
        #expect(p.isPlaying)
        p.pause(); p.play()
        #expect(p.rate == 2)   // Speed survives pause and play
    }
    @Test func playAfterEndRestartsFromBeginning() async throws {
        let p = try await ready()
        p.seek(to: p.duration)
        p.play()
        #expect(p.isPlaying); #expect(p.currentTime < 1)
    }
    @Test func tickReportsTimeWhilePlaying() async throws {
        // Set onTick, play for 0.4 s: at least one tick, with increasing times
    }
    @Test func stopHaltsPlaybackAndTicks() async throws {
        // play, stop: isPlaying false, and no ticks arrive afterward
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter PlayerControllerTests`
Expected: FAIL with "cannot find 'PlayerController' in scope".

- [ ] **Step 3: Implement `PlayerController.swift`**

- `AVURLAsset(url:options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])`.
- All seeks use `toleranceBefore: .zero, toleranceAfter: .zero`.
- Set `audioTimePitchAlgorithm = .timeDomain` on the item so pitch stays normal.
- Use `defaultRate` so `setRate` doesn't start a paused player and `play()` keeps the chosen speed.
- A periodic time observer at 1/30 s updates `currentTime` and calls `onTick`.
- `seek` updates `currentTime` immediately so the highlight doesn't lag.
- `.didPlayToEndTimeNotification` sets `isPlaying` to false.
- `play()` seeks to 0 first if within 0.05 s of the end.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter PlayerControllerTests`
Expected: all pass.

---

### Task 7: App shell, build script and home screen

**Files:**
- Create: `Resources/Info.plist`
- Create: `scripts/make-icon.swift`
- Create: `scripts/build-app.sh`
- Modify: `Sources/PodcastReader/PodcastReaderApp.swift`
- Create: `Sources/PodcastReader/AppModel.swift`
- Create: `Sources/PodcastReader/HomeView.swift`
- Create: `Sources/PodcastReader/Palette.swift`

**Interfaces:**
- Consumes: `Library`, `Lecture`, `Transcriber`, `TranscriptionPhase`, `TranscriberError`, `AudioImport`, `TimeFormat`.
- Produces:
  ```swift
  enum Palette {   // SwiftUI Colors, from a small hex initializer in this file
      static let navy, past, upcoming, glow, fieldBlue, fieldViolet, fieldTeal, bookmarkTick: Color
  }
  @MainActor @Observable final class AppModel {
      enum Screen { case home, placeholder(Lecture) }
      enum ImportState { case idle, working(title: String, phase: TranscriptionPhase?), failed(message: String, retry: URL?) }
      var screen: Screen
      var importState: ImportState
      private(set) var lectures: [Lecture]
      let library: Library
      func refresh()
      func importFile(_ url: URL)
      func cancelImport()
      func open(_ lecture: Lecture)
      func closeReader()
      func remove(_ lecture: Lecture)
  }
  ```
  Until Task 8 replaces it with `.reader(ReaderModel)`, `.placeholder` is a screen showing the lecture's title and word count.

  `Palette` values: `navy` `#0A1C4A`, `past` `#4F74B5`, `upcoming` `#9FC2FF`, `glow` `#8FB8FF`, `fieldBlue` `#1D3B9F`, `fieldViolet` `#44259A`, `fieldTeal` `#0C4A70`, `bookmarkTick` `#6FF5CF`.

- [ ] **Step 1: Write `Resources/Info.plist`, `scripts/make-icon.swift` and `scripts/build-app.sh`**

- `Info.plist`: `CFBundleIdentifier` is `local.podcastreader.app`, `CFBundleName` and `CFBundleDisplayName` are `Podcast Reader`, `CFBundleExecutable` is `PodcastReader`, `CFBundleIconFile` is `AppIcon`, `CFBundlePackageType` is `APPL`, `LSMinimumSystemVersion` is `26.0`, and `NSHighResolutionCapable` is true.
- `make-icon.swift`: draws a navy rounded square with blue and violet color fields and three short white and pale blue bars suggesting caption lines. It writes an `.iconset`, then runs `iconutil` to produce `AppIcon.icns`.
- `build-app.sh`: with `set -euo pipefail`, runs `swift build -c release` and assembles `build/Podcast Reader.app` with `Contents/MacOS/PodcastReader`, `Contents/Info.plist` and `Contents/Resources/AppIcon.icns`. Then it runs `codesign --force --sign - "build/Podcast Reader.app"` and prints the app's path.

- [ ] **Step 2: Implement `PodcastReaderApp.swift`, `AppModel.swift` and `HomeView.swift`**

- Use a single `Window`, not `WindowGroup`, so only one lecture window exists. Quit when the window closes, through an `NSApplicationDelegateAdaptor`. Minimum size 800×560.
- `importFile`:
  - Ignore the call if an import is already running.
  - Check `AudioImport.isSupported`.
  - Compute the ID. If the lecture already exists, open it instead of transcribing.
  - Otherwise transcribe in a stored `Task`, save, refresh and open the lecture.
  - Take only the first file when several are dropped.
- Failure copy, exact:
  - Unreadable or unsupported: `This file couldn't be opened. Try an MP3, M4A or WAV file.`
  - No speech: `No speech was found in this file.`
  - Any other failure: `Transcription didn't finish. Try again.`, with a `Try again` button using `retry`.
- Working copy: `Downloading the speech model…` or `Transcribing <title>…`, with a progress bar and a `Cancel` button. Cancel returns to idle and saves nothing.
- `HomeView` uses the Aurora colors, with a plain navy background until Task 8 adds `AuroraBackground`. It has a drop area with a `Choose file` button restricted to MP3, M4A and WAV, plus recents showing title, duration and a progress bar of `position / duration`. The right-click menu has `Remove from library`.
- Run `Library.all()` off the main thread.

- [ ] **Step 3: Build and verify the app launches**

Run: `scripts/build-app.sh && open "build/Podcast Reader.app"`
Expected: the app appears with a Dock icon, and the home screen shows the drop area.

- [ ] **Step 4: Verify importing by hand, using the fixtures**

Expected for each:

- `sample.mp3` shows progress, then the placeholder screen. It appears under recents after going home.
- `sample.mp3` again opens at once, with no progress bar.
- `silence.mp3` and `notaudio.mp3` show the exact messages above, and recents is unchanged.
- A renamed copy with a capitalized `.MP3` extension is recognized as the same lecture.
- A second file dropped during transcription of a long file (`lecture.mp3` from the scratchpad, or a generated long one) is ignored, and the running job finishes normally.
- `Remove from library` removes the lecture while the audio file stays on disk.

---

### Task 8: Reader with Aurora captions

**Files:**
- Create: `Sources/PodcastReader/ReaderModel.swift`
- Create: `Sources/PodcastReader/ReaderView.swift`
- Create: `Sources/PodcastReader/AuroraBackground.swift`
- Create: `Sources/PodcastReader/CaptionsView.swift`
- Modify: `Sources/PodcastReader/AppModel.swift`, `Sources/PodcastReader/HomeView.swift`

**Interfaces:**
- Consumes: `Lecture`, `Library`, `PlayerController`, `WordClock`, `CaptionMetrics`.
- Produces:
  ```swift
  @MainActor @Observable final class ReaderModel {
      init(lecture: Lecture, audioURL: URL, library: Library)
      private(set) var lecture: Lecture
      let player: PlayerController
      private(set) var activeWord: Int?
      var isFollowing: Bool
      func start() async
      func jump(toWord: Int)
      func backToNow()
      func close()
  }
  ```

- [ ] **Step 1: Implement `ReaderModel.swift`**

`player.onTick` computes the active word through `WordClock`. Assign `activeWord` only when it changed, because `@Observable` notifies on every set. `jump(toWord:)` seeks to that word's `start`, sets `isFollowing` to true and leaves play or pause as it was. `close()` calls `player.stop()`.

- [ ] **Step 2: Implement `AuroraBackground.swift`**

An animated `MeshGradient` in `TimelineView(.animation(minimumInterval: 1.0 / 30))`, with its inner points drifting slowly on a cycle of about 9 seconds. Use `navy` at the edges and `fieldBlue`, `fieldViolet` and `fieldTeal` inside. These are the mockup's colors at reduced strength, so that `#9FC2FF` text keeps at least 4.5:1 contrast everywhere.

With `accessibilityReduceMotion`, hold the points still and don't run the timeline.

- [ ] **Step 3: Implement `CaptionsView.swift`**

- `ScrollView` with `LazyVStack` of `LineRow`, using `ScrollPosition`. Add half a viewport of padding above and below so the first and last lines can reach the anchor.
- `LineRow` is `Equatable` and compares only its text and its `LineState` (`.past`, `.active(wordIndex)`, `.upcoming`), and is used with `.equatable()`, so a word change redraws only the active row. The click closure is excluded from `==`.
- Words go in a custom `FlowLayout: Layout` with a gap of 0.25 em. Each word is `Text` with `.system(size:, weight: .heavy)` and `.tracking(-0.035 * size)`, with `onTapGesture` and an underline on hover.
- The font size comes from `CaptionMetrics.fontSize(forWidth:)`, using the captions area's own width.
- Color by state, from Global Constraints. The current word gets white plus `.shadow(color: Palette.glow, radius: 12)`.
- When the active line changes and `isFollowing` is true, call `scrollTo(id:anchor: UnitPoint(x: 0, y: 0.38))`, animated over about 0.45 s, or instantly with Reduce Motion on.
- `onScrollPhaseChange`: when the phase becomes `.tracking` or `.interacting`, set `isFollowing` to false.
- When `isFollowing` is false, show a `Back to now` pill that calls `backToNow()`.

- [ ] **Step 4: Connect it to `AppModel`**

Replace `Screen.placeholder` with `Screen.reader(ReaderModel)`. `open` resolves `library.audioURL(for:)`, builds a `ReaderModel` and shows `ReaderView`. `ReaderView` has a back button returning home and a temporary play button until Task 9. Make `HomeView` use `AuroraBackground`.

- [ ] **Step 5: Build and verify against the mockup**

Run: `scripts/build-app.sh && open "build/Podcast Reader.app"`, then open a lecture and press play.
Expected:

- The look matches the mockup, with drifting color fields and past, active and upcoming lines in their colors.
- Words turn white one at a time, and the active line stays about 38% down the window.
- Clicking a word moves the highlight there immediately, and audio continues from that word.
- Clicking a word while paused stays paused.
- Scrolling by hand stops the following and shows `Back to now`. Clicking it returns to the active line.
- Going back home stops the audio.
- With Reduce Motion on in System Settings, the background holds still.

---

### Task 9: Controls, keyboard and full screen

**Files:**
- Create: `Sources/PodcastReader/ControlBar.swift`
- Create: `Sources/PodcastReader/KeyMonitor.swift`
- Modify: `Sources/PodcastReader/ReaderView.swift`, `Sources/PodcastReader/ReaderModel.swift`

**Interfaces:**
- Consumes: `PlayerController`, `PlaybackRules`, `TimeFormat`, `ReaderKeys`, `ReaderCommand`, `KeyModifiers`.
- Produces:
  - `extension ReaderModel { func perform(_ command: ReaderCommand) }`
  - `ReaderModel.controlsVisible: Bool`, and `func noteMouseMoved()`
  - The bookmark and panel controls call `addBookmark()` and `openPanel(_:)`, which Task 10 implements. Until then they do nothing.

- [ ] **Step 1: Implement `ControlBar.swift`**

The layout and order are in the spec's "Controls" section. Use SF Symbols `gobackward.30`, `gobackward.10`, `play.fill`, `pause.fill`, `goforward.10`, `goforward.30`, `magnifyingglass`, `bookmark`, `list.bullet` and `arrow.up.left.and.arrow.down.right`, each with a `.help` tooltip and an accessibility label. The speed button shows the current speed and calls `nextSpeed(after:)`.

Put the progress bar in its own subview, so that only it re-renders when `currentTime` changes. Clicking it seeks. It shows elapsed and total time through `TimeFormat`.

- [ ] **Step 2: Implement `KeyMonitor.swift` and `perform(_:)`**

Use `NSEvent.addLocalMonitorForEvents(matching: .keyDown)`, removed when the reader closes. `isTyping` is true when `NSApp.keyWindow?.firstResponder` is an `NSTextView`, which is how a text field edits. Return `nil` to swallow the event only if `ReaderKeys.command` produced a command. This avoids relying on SwiftUI focus, which clicks on words would disturb.

- [ ] **Step 3: Implement the full screen controls fade**

- The full screen button calls `window.toggleFullScreen(nil)`.
- `⌃⌘F` comes from the standard View menu, which SwiftUI provides.
- Track full screen state through `NSWindow.didEnterFullScreenNotification` and `didExitFullScreenNotification`.
- In full screen, 3 seconds without mouse movement fades the controls out and calls `NSCursor.setHiddenUntilMouseMoves(true)`. `onContinuousHover` calls `noteMouseMoved()`, which shows them again.
- Keep the controls visible in a normal window.

- [ ] **Step 4: Build and verify**

Run: `scripts/build-app.sh && open "build/Podcast Reader.app"`
Expected:

- All four skip buttons move by the right amount, and stop at both ends of the audio.
- All seven speeds work, and the voice keeps its normal pitch.
- Every shortcut in the spec's table works.
- Clicking the progress bar seeks.
- After the audio ends, the play button restarts from the beginning.
- In full screen the text grows to fill the screen, and the controls and pointer fade after 3 seconds and return when the mouse moves.

---

### Task 10: Side panel with search and bookmarks

**Files:**
- Create: `Sources/PodcastReader/SidePanel.swift`
- Modify: `Sources/PodcastReader/ReaderModel.swift`, `Sources/PodcastReader/ReaderView.swift`, `Sources/PodcastReader/ControlBar.swift`

**Interfaces:**
- Consumes: `SearchIndex`, `SearchMatch`, `Lecture.addBookmark`, `Lecture.removeBookmark`, `TimeFormat`.
- Produces, added to `ReaderModel`:
  ```swift
  enum PanelTab { case search, bookmarks }
  var panel: PanelTab?
  var query: String
  private(set) var matches: [SearchMatch]
  private(set) var toast: String?
  func openPanel(_: PanelTab)
  func addBookmark()
  func removeBookmark(id: UUID)
  ```

- [ ] **Step 1: Implement the model additions**

- Build `SearchIndex` once, on first use, away from the main thread.
- Re-run the search as `query` changes, debounced by 150 ms.
- `addBookmark` uses `activeWord`, or word 0 if nothing is active yet. It sets `toast` to `Bookmarked` for 1.5 seconds if `Lecture.addBookmark` returned true, saves the lecture, and does nothing further if it returned false.
- `removeBookmark` also saves.

- [ ] **Step 2: Implement `SidePanel.swift` and bookmark ticks**

- A panel about 340 points wide, sliding in from the right in an `HStack` beside the captions so they narrow rather than get covered. It has `Search` and `Bookmarks` tabs.
- Opening Search focuses the text field.
- Search rows show the context with the match in white, and a timestamp. The empty result text is `No matches`.
- Bookmark rows show timestamp, line text and a delete button, in time order. The empty text is `Press B to bookmark a moment`.
- Clicking a row calls `jump(toWord:)`.
- Add `Palette.bookmarkTick` ticks to the progress bar at `time / duration`, each one a click target that jumps to that bookmark.

- [ ] **Step 3: Build and verify**

Run: `scripts/build-app.sh && open "build/Podcast Reader.app"`
Expected:

- `⌘F` opens search, typing filters results, and clicking one jumps there.
- Space, B and the arrow keys typed in the search box type or move the cursor, and don't affect playback.
- Esc closes the panel, and the keys control playback again.
- `B` adds a tick and shows `Bookmarked`. Pressing it again on the same word adds nothing.
- `⌘B` lists bookmarks. Clicking one jumps there, and delete removes its tick.
- Captions narrow when the panel opens and keep following.

---

### Task 11: Resuming and recovering

**Files:**
- Modify: `Sources/PodcastReader/ReaderModel.swift`, `Sources/PodcastReader/AppModel.swift`, `Sources/PodcastReader/HomeView.swift`

**Interfaces:**
- Consumes: `Library.save`, `Library.audioURL(for:)`, `Library.relocate`, `LibraryError`.
- Produces: `ReaderModel.savePosition()`, `AppModel.locateAudio(for: Lecture, at: URL)`, and a new case `Screen.missingAudio(Lecture, message: String?)`.

- [ ] **Step 1: Implement saving and resuming**

`ReaderModel.savePosition()` writes the current position through `Library.save`. Call it every 5 seconds while playing, on pause, in `close()`, and on `NSApplication.willTerminateNotification`. `start()` seeks to `lecture.position` and stays paused. `AppModel.open` updates `lastOpenedAt`.

- [ ] **Step 2: Implement locating a moved file**

When `audioURL(for:)` returns nil, `open` shows `Screen.missingAudio` with `This lecture's audio file has moved.` and a `Locate file` button that opens a file picker. `locateAudio` calls `Library.relocate`, saves and opens the lecture on success. On `LibraryError.differentAudio`, set the `message` to `That's a different file from this lecture. Choose the original audio.` and stay on the prompt.

- [ ] **Step 3: Build and verify**

Run: `scripts/build-app.sh && open "build/Podcast Reader.app"`
Expected:

- Quit with `⌘Q` mid-lecture. On reopening, the recents progress bar is right, and opening the lecture resumes at that spot, paused, with bookmarks intact.
- Move an audio file to another folder: the lecture still opens.
- Move it to the Trash: the lecture shows the moved-file prompt.
- `Locate file` with a different file shows the refusal. With the original, it opens with bookmarks intact.
- Add a garbage `.json` file to the lectures folder: the home screen still lists the others.

---

### Task 12: Full verification

**Files:**
- Create: `README.md` (how to build and open the app, how to run tests, and the two commands below)

- [ ] **Step 1: Run the whole test suite**

Run: `swift test`
Expected: all tests pass.

- [ ] **Step 2: Do a clean rebuild**

Run: `rm -rf build .build && scripts/build-app.sh`
Expected: the build succeeds and prints the app's path.

- [ ] **Step 3: Test a very long file**

Generate a 3-hour file in the scratchpad with `ffmpeg`, by repeating `lecture.mp3`. Import it, then play it in full screen.

Expected:

- Transcription takes a few minutes at most and the progress bar keeps moving.
- Word highlighting and scrolling stay smooth, and jumping from start to end is immediate.
- Search returns results promptly.
- Activity Monitor shows the app below about 30% of one core during playback. If it's higher, reduce the Aurora timeline rate first.

- [ ] **Step 4: Run the whole end-to-end list once more**

Go through every item under "End-to-end checks" in the spec, in the real app.

- [ ] **Step 5: Hand over the checks only a person can do**

Report honestly which of these remain open:

- Hearing that a clicked word plays with no noticeable offset.
- Judging accuracy on a real lecture.
- Checking line breaks on real speech, tuning the `LineBuilder` values if needed.
- Confirming readability from across a room.
