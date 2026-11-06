# Kokoro Voice Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let PDFs be read by the Kokoro neural voice, with everything else working exactly as it does for Apple's voices.

**Architecture:** `DocumentImporter` gets a `SpeechEngine` abstraction. `KokoroSpeechEngine` runs a Python helper that renders chunks in parallel, then joins them into one `.m4a` with a time per word. `KokoroEnvironment` installs and removes the helper's environment.

**Tech Stack:** Swift 6, SwiftUI, `Foundation.Process`, `AVAudioFile`; Python 3.12, `kokoro` 0.9.4, `uv`.

**Spec:** `docs/superpowers/specs/2026-11-05-kokoro-voice-design.md`

## Global Constraints

- Run tests with `scripts/test.sh`, and build with `scripts/build-app.sh`. Not a git repository, so there are no commit steps.
- Pinned: `kokoro==0.9.4`, `misaki[en]==0.9.4`, `soundfile`, Python 3.12. Voices: `af_heart`, `af_bella`, `am_michael`, `bf_emma`. Device `cpu`, 3 workers, 3 threads each.
- `ESPEAK_DATA_PATH` must point at a short link. `HF_HOME` stays inside the Kokoro folder.
- Don't modify saved lectures except through existing paths. The user's library must keep working.
- A Kokoro failure never silently falls back to another voice.
- Spec copy in "When things go wrong" is exact.

## Review Focus

1. **Orphaned processes:** canceling, quitting or a crash must not leave Python workers running at full CPU. Tests in Task 4.
2. **Mapping drift on odd text:** symbols, quotes, hyphens and numbers must not shift later words in a chunk, and one chunk's error must not carry into the next. Tests in Tasks 2 and 4.
3. **A half-finished chunk counting as done** after a crash mid-write would corrupt audio on resume. Test in Task 4.
4. **An interrupted setup** must never read as installed. Test in Task 3.
5. **Saved lectures:** existing lectures, and Ava PDFs, must be unaffected by a changed voice setting. Test in Task 6.

---

### Task 1: Speech engine abstraction

**Files:** Modify `Sources/PodcastReaderCore/SpeechRenderer.swift`, `DocumentImporter.swift`. Test: `Tests/PodcastReaderCoreTests/DocumentImporterTests.swift`.

**Produces:**
```swift
public protocol SpeechEngine: Sendable {
    func render(words: [String], to url: URL, onProgress: @escaping @Sendable (Double) -> Void) async throws -> RenderedSpeech
}
extension SpeechRenderer: SpeechEngine {}
// DocumentImporter.init(library: Library, engine: any SpeechEngine = SpeechRenderer())
```

- [ ] Write a failing test, `usesTheEngineItIsGiven`: a stand-in engine that records its words and writes a known audio fixture produces a lecture with that engine's `voiceName`.
- [ ] Run `scripts/test.sh --filter DocumentImporterTests`. Expected: compile failure.
- [ ] Implement. `regenerateAudio` uses the same engine and updates `voiceName`.
- [ ] Run again. Expected: all pass, with existing behavior unchanged.

---

### Task 2: Chunking, token mapping, time remaining

**Files:** Create `Sources/PodcastReaderCore/SpeechChunker.swift`, `KokoroTimeline.swift`, `TimeRemaining.swift`. Modify `SpeechTimeline.swift` to expose its fill-in logic as internal. Tests for each.

**Produces:**
```swift
public enum SpeechChunker { public static func chunks(for words: [String], targetWords: Int = 300) -> [Range<Int>] }
public struct KokoroToken: Codable, Equatable, Sendable { public let text: String; public let start: TimeInterval?; public let end: TimeInterval? }
public enum KokoroTimeline { public static func wordTimes(words: [String], tokens: [KokoroToken], duration: TimeInterval) -> [WordTime] }
public enum TimeRemaining { public static func text(elapsed: TimeInterval, fraction: Double) -> String? }
```

- [ ] Write failing tests:
  - **Chunker:** breaks at the first sentence end at or after the target; hard cap at twice the target with no sentence end, preferring a comma; covers every word once, in order; empty input; a short input gives one chunk.
  - **Timeline:** one token per word; a word split into `well`, `-`, `known` takes its first token's time; punctuation tokens don't create words; a word with no time shares the gap; quotes changed by normalization, where text lengths differ, stay close to the true word; a token error early doesn't shift the last word by more than one word; empty tokens spread evenly; every word's start is distinct and increasing; the last word ends at `duration`.
  - **TimeRemaining:** nil before both 5% and 20 s; `About 40 minutes left`; `About 1 hour 10 minutes left`; `Less than a minute left`; rounding to the nearest minute; never negative; fraction 0 gives nil.
- [ ] Run. Expected: compile failure.
- [ ] Implement. Timeline: compare positions in the texts with whitespace removed, scaling when lengths differ.
- [ ] Run. Expected: all pass.

---

### Task 3: Kokoro environment

**Files:** Create `Sources/PodcastReaderCore/KokoroEnvironment.swift`, `KokoroHelper.swift` (the Python as a string). Test: `KokoroEnvironmentTests.swift`.

**Produces:**
```swift
public struct KokoroVoice: Codable, Hashable, Sendable, Identifiable { public let id: String; public let name: String; static let all: [KokoroVoice]; static let heart: KokoroVoice }
public enum KokoroError: Error, Equatable { case uvMissing, setupFailed, renderFailed, notInstalled }
public struct KokoroEnvironment: Sendable {
    public init(root: URL = KokoroEnvironment.defaultRoot, uvSearchPaths: [String] = KokoroEnvironment.defaultUVPaths)
    public var isInstalled: Bool
    public var uvURL: URL?
    public var processEnvironment: [String: String]
    public var pythonURL: URL
    public var helperURL: URL
    public func install(onProgress: @escaping @Sendable (Double) -> Void) async throws
    public func remove() throws
}
```

- [ ] Write failing tests: `isInstalled` is false with no marker, and after an interrupted setup with everything present but the marker; `uvURL` finds the first existing path and nil for none; `processEnvironment` sets `HF_HOME` inside the root, and `ESPEAK_DATA_PATH` is under 160 characters even when the real data path is longer; `install` throws `.uvMissing` with no `uv`; `remove` deletes the root; failing commands throw `.setupFailed`.
- [ ] Add a gated real test, `.enabled(if: KOKORO_TEST_ROOT is set)`: real `install`, then `isInstalled`, and all four voices present.
- [ ] Run. Expected: compile failure.
- [ ] Implement, including the helper: `render --job job.json` and `prepare`. Workers ignore `SIGINT`, and the parent exits on stdin EOF, killing its process group.
- [ ] Run, then the real test with `KOKORO_TEST_ROOT` in the scratchpad. Expected: all pass, and setup completes.

---

### Task 4: Kokoro engine

**Files:** Create `Sources/PodcastReaderCore/KokoroSpeechEngine.swift`. Test: `KokoroSpeechEngineTests.swift`, gated like Task 3.

**Produces:** `public struct KokoroSpeechEngine: SpeechEngine { public init(environment: KokoroEnvironment, voice: KokoroVoice, workDirectory: URL) }`, where `voiceName` is `Kokoro Heart`.

- [ ] Write failing gated tests:
  - **Render:** times for every word, increasing; duration above 5 s; the output is AAC and `PlayerController` reports the same duration within 0.2 s.
  - **Chunks:** with several chunks, each repeat of the same paragraph takes about the same time, within 1 s.
  - **Sound:** sentence-start alignment under 120 ms, reusing the check in `SoundAlignmentTests`.
  - **Odd text:** symbols, quotes, hyphens and numbers keep the word count, and increasing times.
  - **Cancel:** throws `CancellationError`, removes the work folder, and leaves no helper processes, checked with `pgrep`.
  - **Resume:** stopped partway, a second run reuses finished chunks, is faster and gives the same word count. A `.wav` with no `.json` beside it is rendered again.
  - **Input closed:** closing the helper's stdin ends it and its workers.
  - **Not installed:** throws `.notInstalled` right away.
- [ ] Add an ungated test that a helper exiting with an error gives `.renderFailed`, using a fake Python script.
- [ ] Run. Expected: compile failure.
- [ ] Implement. Join chunks with `AVAudioFile` into AAC, and hold a process activity so the Mac doesn't sleep during a job.
- [ ] Run with `KOKORO_TEST_ROOT`. Expected: all pass.

---

### Task 5: Voice choice in the app

**Files:** Modify `Sources/PodcastReaderUI/AppModel.swift`, `HomeView.swift`. Test: `Tests/PodcastReaderUITests/VoiceChoiceTests.swift`.

**Produces:** in `AppModel`: `enum ReadingVoice: Codable, Hashable { case apple; case kokoro(KokoroVoice) }`; `var readingVoice: ReadingVoice`; `chooseVoice(_:)`; `setUpKokoro()`; `cancelKokoroSetup()`; `removeKokoro()`; `readAgain(_ lecture:)`; `kokoroState` (`.notInstalled`, `.confirming(KokoroVoice)`, `.installing(Double)`, `.installed`, `.failed(String)`); `engineFactory` for tests; the choice saved in `UserDefaults`.

- [ ] Write failing tests with a stand-in engine and environment:
  - The default is Apple before setup, and Heart after.
  - Choosing Kokoro before setup asks first and doesn't change the voice until setup finishes.
  - A failed setup keeps the voice and shows the exact message; no `uv` shows its message.
  - A saved choice survives a new `AppModel`.
  - Importing uses the chosen voice's engine.
  - `readAgain` keeps bookmarks and position, and updates `voiceName`.
  - A failed render shows the message with `Try again`, and never tries another voice.
  - Audio lectures offer no **Read again**.
- [ ] Run. Expected: compile failure.
- [ ] Implement, then the UI: a `Menu` titled `Voice for PDFs: Heart` below the drop area, showing `Natural, slower` and `Fast` notes, with a `Remove Kokoro` item; a setup confirmation; setup progress with `Cancel`; time remaining under the progress bar; `Read again with Heart` in the row's context menu.
- [ ] Run. Expected: all pass, and the full suite stays green.

---

### Task 6: Verification

- [ ] Run a real Kokoro PDF through `ReaderSnapshots interact`, with a variant importing with Kokoro. Expected: all checks pass.
- [ ] Render screens, including the home screen with the menu and the setup prompt. Check by eye.
- [ ] Run a real English PDF with Heart, and a 100-page generated PDF with lists and symbols. Report speed, memory, size, seconds per page, and landing checks.
- [ ] Confirm the user's library is untouched and loads, including its Samantha PDF, with no audio regenerated.
- [ ] Update the README with setup and voices. Delete `voice-samples`, keeping nothing the app needs.
- [ ] Clean rebuild, all tests, all real tests, launch check.
- [ ] Final review by a fresh reviewer, then a fix pass. Report what only a person can check.
