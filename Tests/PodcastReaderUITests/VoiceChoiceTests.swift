import Foundation
@testable import PodcastReaderCore
import Synchronization
import Testing
@testable import PodcastReaderUI

/// Remembers which voices were asked for.
final class VoiceLog: Sendable {
    private let voices = Mutex<[ReadingVoice]>([])

    func add(_ voice: ReadingVoice) {
        voices.withLock { $0.append(voice) }
    }

    func clear() {
        voices.withLock { $0 = [] }
    }

    var all: [ReadingVoice] {
        voices.withLock { $0 }
    }
}

/// A clock that only moves when told to.
final class TestClock: Sendable {
    private let date = Mutex(Date(timeIntervalSince1970: 1_000))

    var now: Date {
        date.withLock { $0 }
    }

    func advance(by seconds: TimeInterval) {
        date.withLock { $0 += seconds }
    }
}

/// Holds a job open until the test has seen what it wanted to.
final class TestGate: Sendable {
    private let opened = Mutex(false)

    var isOpen: Bool {
        opened.withLock { $0 }
    }

    func open() {
        opened.withLock { $0 = true }
    }
}

/// A voice that writes a known audio file instead of really speaking.
struct StandInEngine: SpeechEngine {
    let voiceName: String
    var failure: KokoroError?
    var delay: Duration = .zero
    var clock: TestClock?
    var reports: [(seconds: TimeInterval, fraction: Double)] = []
    var gate: TestGate?

    func render(words: [String], to url: URL, onProgress: @escaping @Sendable (Double) -> Void) async throws -> RenderedSpeech {
        for report in reports {
            clock?.advance(by: report.seconds)
            onProgress(report.fraction)
        }
        while gate?.isOpen == false {
            try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(for: delay)
        if let failure { throw failure }
        try FileManager.default.copyItem(at: fixture("sample.m4a"), to: url)
        let times = words.indices.map { WordTime(start: Double($0) * 0.01, end: Double($0 + 1) * 0.01) }
        return RenderedSpeech(times: times, duration: Double(words.count) * 0.01, voiceName: voiceName)
    }
}

/// One at a time, as each opens readers on the main thread and other suites time things there.
@MainActor
@Suite(.serialized)
struct VoiceChoiceTests {
    /// Looking through the Mac's voices is slow to repeat for every test.
    static let appleName = SpeechRenderer.bestVoiceName() ?? "Apple voice"

    let directory: URL
    let library: Library
    let defaults: UserDefaults
    let log = VoiceLog()

    init() throws {
        directory = try makeTemporaryDirectory()
        library = Library(directory: directory.appending(path: "lectures", directoryHint: .isDirectory))
        // One name, emptied each time, as each name leaves a file in Preferences for good.
        let suite = "PodcastReaderVoiceChoiceTests"
        defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
    }

    func environment(installed: Bool, uv: String? = nil) throws -> KokoroEnvironment {
        let environment = KokoroEnvironment(
            root: directory.appending(path: "kokoro", directoryHint: .isDirectory),
            // Without a stand-in, setup fails right away rather than using the real download.
            uv: uv.map { .existing(URL(fileURLWithPath: $0)) }
                ?? .download(directory.appending(path: "nothing-here.tar.gz"), sha256: "")
        )
        if installed {
            try FileManager.default.createDirectory(at: environment.pythonURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "#!/bin/sh\nexit 0\n".write(to: environment.pythonURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: environment.pythonURL.path)
            FileManager.default.createFile(atPath: environment.markerURL.path, contents: Data())
        }
        return environment
    }

    /// A stand-in for uv whose setup succeeds, fails with the given status, or takes ages.
    func fakeUV(exitStatus: Int = 0, slow: Bool = false) throws -> String {
        let url = directory.appending(path: "uv")
        let body = """
        #!/bin/sh
        \(slow ? "exec sleep 30" : "")
        if [ "$1" = "venv" ]; then
          for last; do :; done
          mkdir -p "$last/bin"
          printf '#!/bin/sh\\nexit 0\\n' > "$last/bin/python"
          chmod +x "$last/bin/python"
        fi
        exit \(exitStatus)
        """
        try body.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    func makeModel(
        kokoro: KokoroEnvironment,
        fails: Bool = false,
        failure: KokoroError = .renderFailed,
        delay: Duration = .zero,
        clock: TestClock? = nil,
        reports: [(seconds: TimeInterval, fraction: Double)] = [],
        gate: TestGate? = nil
    ) -> AppModel {
        let log = log
        let appleName = Self.appleName
        return AppModel(
            library: library,
            isMuted: true,
            kokoro: kokoro,
            defaults: defaults,
            engineFactory: { voice, _ in
                log.add(voice)
                let name: String
                switch voice {
                case .apple: name = appleName
                case .kokoro(let kokoroVoice): name = kokoroVoice.displayName
                }
                return StandInEngine(voiceName: name, failure: fails ? failure : nil, delay: delay, clock: clock, reports: reports, gate: gate)
            },
            now: { clock?.now ?? Date() }
        )
    }

    func copyPDF(_ source: String = "document", as name: String = "reading") throws -> URL {
        let url = directory.appending(path: "\(name).pdf")
        try FileManager.default.copyItem(at: fixture("\(source).pdf"), to: url)
        return url
    }

    func waitForImport(_ model: AppModel) async throws {
        try await waitUntil { !model.isImporting }
        #expect(!model.isImporting)
    }

    func failureMessage(_ model: AppModel) -> String? {
        if case .failed(let message, _) = model.importState { return message }
        return nil
    }

    func openReader(_ model: AppModel) -> ReaderModel? {
        if case .reader(let reader) = model.screen { return reader }
        return nil
    }

    /// Adds a PDF read by the given voice and returns to the home screen.
    func addPDF(to model: AppModel, voice: ReadingVoice = .apple) async throws -> Lecture {
        model.chooseVoice(voice)
        model.importFile(try copyPDF())
        try await waitForImport(model)
        let lecture = try #require(openReader(model)?.lecture)
        model.closeReader()
        log.clear()
        return lecture
    }

    // MARK: Which voice

    @Test func beforeSetupTheDefaultIsApple() throws {
        let model = makeModel(kokoro: try environment(installed: false))
        #expect(model.readingVoice == .apple)
        #expect(model.readingVoiceName == model.bestAppleVoiceName)
    }

    @Test func afterSetupTheDefaultIsHeart() throws {
        let model = makeModel(kokoro: try environment(installed: true))
        #expect(model.readingVoice == .kokoro(.heart))
        #expect(model.readingVoiceName == "Heart")
    }

    @Test func aSavedChoiceSurvivesANewModel() throws {
        let kokoro = try environment(installed: true)
        let bella = try #require(KokoroVoice.all.first { $0.name == "Bella" })
        makeModel(kokoro: kokoro).chooseVoice(.kokoro(bella))
        #expect(makeModel(kokoro: kokoro).readingVoice == .kokoro(bella))
    }

    @Test func choosingAppleAfterSetupSticks() throws {
        let kokoro = try environment(installed: true)
        makeModel(kokoro: kokoro).chooseVoice(.apple)
        #expect(makeModel(kokoro: kokoro).readingVoice == .apple)
    }

    @Test func kokoroRemovedOutsideTheAppFallsBackToApple() throws {
        let kokoro = try environment(installed: true)
        makeModel(kokoro: kokoro).chooseVoice(.kokoro(.heart))
        try kokoro.remove()
        #expect(makeModel(kokoro: kokoro).readingVoice == .apple)
    }

    @Test func kokoroRemovedWhileTheAppIsOpenIsNoticed() throws {
        let kokoro = try environment(installed: true)
        let model = makeModel(kokoro: kokoro)
        try kokoro.remove()
        model.refresh()
        #expect(model.readingVoice == .apple)
    }

    // MARK: Setup

    @Test func choosingKokoroBeforeSetupAsksFirst() throws {
        let model = makeModel(kokoro: try environment(installed: false, uv: try fakeUV()))
        model.chooseVoice(.kokoro(.heart))
        #expect(model.kokoroSetup == .confirming(.heart))
        #expect(model.readingVoice == .apple)
    }

    @Test func decliningChangesNothing() throws {
        let model = makeModel(kokoro: try environment(installed: false, uv: try fakeUV()))
        model.chooseVoice(.kokoro(.heart))
        model.dismissKokoroSetup()
        #expect(model.kokoroSetup == .idle)
        #expect(model.readingVoice == .apple)
    }

    @Test func finishingSetupChangesTheVoice() async throws {
        let model = makeModel(kokoro: try environment(installed: false, uv: try fakeUV()))
        let bella = try #require(KokoroVoice.all.first { $0.name == "Bella" })
        model.chooseVoice(.kokoro(bella))
        model.confirmKokoroSetup()
        try await waitUntil { model.kokoroSetup == .idle }
        #expect(model.isKokoroInstalled)
        #expect(model.readingVoice == .kokoro(bella))
    }

    @Test func aFailedSetupKeepsTheVoiceAndExplains() async throws {
        let model = makeModel(kokoro: try environment(installed: false, uv: try fakeUV(exitStatus: 1)))
        model.chooseVoice(.kokoro(.heart))
        model.confirmKokoroSetup()
        try await waitUntil { if case .failed = model.kokoroSetup { true } else { false } }
        #expect(model.kokoroSetup == .failed(message: "Setting up Kokoro didn't finish. Check your connection and try again.", voice: .heart))
        #expect(model.readingVoice == .apple)
    }

    @Test func aFailedDownloadExplainsWhy() async throws {
        let model = makeModel(kokoro: try environment(installed: false))
        model.chooseVoice(.kokoro(.heart))
        model.confirmKokoroSetup()
        try await waitUntil { if case .failed = model.kokoroSetup { true } else { false } }
        #expect(model.kokoroSetup == .failed(message: "Setting up Kokoro didn't finish. Check your connection and try again.", voice: .heart))
    }

    @Test func tryingSetupAgainWorks() async throws {
        let kokoro = try environment(installed: false, uv: try fakeUV(exitStatus: 1))
        let model = makeModel(kokoro: kokoro)
        model.chooseVoice(.kokoro(.heart))
        model.confirmKokoroSetup()
        try await waitUntil { if case .failed = model.kokoroSetup { true } else { false } }

        try FileManager.default.removeItem(at: directory.appending(path: "uv"))
        _ = try fakeUV()
        model.confirmKokoroSetup()
        try await waitUntil { model.kokoroSetup == .idle }
        #expect(model.readingVoice == .kokoro(.heart))
    }

    @Test func cancelingSetupKeepsTheVoice() async throws {
        let model = makeModel(kokoro: try environment(installed: false, uv: try fakeUV(slow: true)))
        model.chooseVoice(.kokoro(.heart))
        model.confirmKokoroSetup()
        try await Task.sleep(for: .milliseconds(300))
        model.cancelKokoroSetup()
        try await waitUntil(upTo: 5) { model.kokoroSetup == .idle }
        #expect(model.kokoroSetup == .idle)
        #expect(model.readingVoice == .apple)
        #expect(!model.isKokoroInstalled)
    }

    @Test func removingKokoroGoesBackToAppleAndKeepsPreparedPDFs() async throws {
        let kokoro = try environment(installed: true)
        let model = makeModel(kokoro: kokoro)
        let lecture = try await addPDF(to: model, voice: .kokoro(.heart))

        model.removeKokoro()
        #expect(model.readingVoice == .apple)
        #expect(!model.isKokoroInstalled)
        #expect(!FileManager.default.fileExists(atPath: kokoro.root.path))
        #expect(library.audioURL(for: lecture) != nil)
    }

    @Test func kokoroCantBeRemovedWhileAJobIsRunning() async throws {
        let kokoro = try environment(installed: true)
        let model = makeModel(kokoro: kokoro, delay: .milliseconds(300))
        model.importFile(try copyPDF())
        model.removeKokoro()
        #expect(model.isKokoroInstalled)
        #expect(model.notice == "Finish or cancel the current job first, then remove Kokoro.")
        try await waitForImport(model)
        model.closeReader()
    }

    // MARK: Preparing

    @Test func importingUsesTheChosenVoice() async throws {
        let model = makeModel(kokoro: try environment(installed: true))
        model.importFile(try copyPDF())
        try await waitForImport(model)
        #expect(log.all == [.kokoro(.heart)])
        #expect(openReader(model)?.lecture.document?.voiceName == "Kokoro Heart")
        model.closeReader()
    }

    @Test func aFailedRenderExplainsAndNeverTriesAnotherVoice() async throws {
        let model = makeModel(kokoro: try environment(installed: true), fails: true)
        model.importFile(try copyPDF())
        try await waitForImport(model)
        #expect(failureMessage(model) == "Preparing this PDF didn't finish. Try again.")
        #expect(log.all == [.kokoro(.heart)])
        #expect(library.all().isEmpty)
    }

    @Test func kokoroBeingGoneIsExplainedAndNoticed() async throws {
        let kokoro = try environment(installed: true)
        let model = makeModel(kokoro: kokoro, fails: true, failure: .notInstalled)
        try kokoro.remove()
        model.importFile(try copyPDF())
        try await waitForImport(model)
        #expect(failureMessage(model) == "Kokoro isn't set up on this Mac any more. Choose it under Voice for PDFs to set it up again.")
        #expect(!model.canRetryImport)
        #expect(model.readingVoice == .apple)
    }

    @Test func aFailedReadAgainCanBeRetriedWithoutThePDF() async throws {
        let kokoro = try environment(installed: true)
        let url = try copyPDF()
        let working = makeModel(kokoro: kokoro)
        working.chooseVoice(.apple)
        working.importFile(url)
        try await waitForImport(working)
        let lecture = try #require(openReader(working)?.lecture)
        working.closeReader()
        try FileManager.default.removeItem(at: url)

        let failing = makeModel(kokoro: kokoro, fails: true)
        failing.chooseVoice(.kokoro(.heart))
        failing.readAgain(lecture)
        try await waitForImport(failing)
        #expect(failing.canRetryImport)
    }

    @Test func aLongJobDoesntInterruptReadingSomethingElse() async throws {
        let kokoro = try environment(installed: true)
        let other = try await addPDF(to: makeModel(kokoro: kokoro))

        let model = makeModel(kokoro: kokoro, delay: .milliseconds(400))
        model.importFile(try copyPDF("two-columns", as: "second"))
        model.open(other)
        let reader = try #require(openReader(model))
        try await waitForImport(model)

        #expect(openReader(model) === reader)
        #expect(model.notice == "second is ready.")
        model.closeReader()
        #expect(model.lectures.contains { $0.title == "second" })
    }

    @Test func timeRemainingUsesTheSpeedOfTheWorkItself() async throws {
        let clock = TestClock()
        let gate = TestGate()
        // Work picked up from before quitting arrives at once, then 10% takes 100 seconds.
        let model = makeModel(
            kokoro: try environment(installed: true),
            clock: clock,
            reports: [(1, 0.4), (1, 0.8), (100, 0.9)],
            gate: gate
        )
        model.importFile(try copyPDF())
        try await waitUntil { model.importRemainingText != nil }
        #expect(model.importRemainingText == "About 2 minutes left")
        gate.open()
        try await waitForImport(model)
        #expect(model.importRemainingText == nil)
        model.closeReader()
    }

    // MARK: Reading again

    @Test func readAgainOffersOnlyADifferentVoice() async throws {
        let model = makeModel(kokoro: try environment(installed: true))
        let lecture = try await addPDF(to: model)
        #expect(!model.canReadAgain(lecture))
        model.chooseVoice(.kokoro(.heart))
        #expect(model.canReadAgain(lecture))
    }

    @Test func audioLecturesNeverOfferReadAgain() throws {
        let model = makeModel(kokoro: try environment(installed: true))
        let lecture = try library.makeLecture(
            audioAt: fixture("sample.m4a"),
            transcript: Transcript(words: [Word(text: "Hi", start: 0, end: 1)]),
            duration: 1
        )
        #expect(!model.canReadAgain(lecture))
    }

    @Test func readingAgainKeepsBookmarksAndPlace() async throws {
        let model = makeModel(kokoro: try environment(installed: true))
        var saved = try await addPDF(to: model)
        _ = saved.addBookmark(wordIndex: 20)
        saved.position = saved.transcript.words[20].start
        try library.save(saved)

        model.chooseVoice(.kokoro(.heart))
        model.readAgain(saved)
        try await waitForImport(model)

        let reopened = try #require(openReader(model))
        #expect(log.all == [.kokoro(.heart)])
        #expect(reopened.lecture.document?.voiceName == "Kokoro Heart")
        #expect(reopened.lecture.bookmarks.map(\.wordIndex) == [20])
        #expect(reopened.lecture.position == reopened.lecture.transcript.words[20].start)
        model.closeReader()
    }

    @Test func tryingAgainUsesTheSameVoiceEvenAfterAChange() async throws {
        let kokoro = try environment(installed: true)
        let lecture = try await addPDF(to: makeModel(kokoro: kokoro))

        let failing = makeModel(kokoro: kokoro, fails: true)
        failing.chooseVoice(.kokoro(.heart))
        failing.readAgain(lecture)
        try await waitForImport(failing)
        #expect(failureMessage(failing) == "Preparing this PDF didn't finish. Try again.")

        failing.chooseVoice(.apple)
        log.clear()
        failing.retryImport()
        try await waitForImport(failing)
        #expect(log.all == [.kokoro(.heart)])
    }

    @Test func aPDFBeingPreparedCantBeOpenedOrRemoved() async throws {
        let kokoro = try environment(installed: true)
        let lecture = try await addPDF(to: makeModel(kokoro: kokoro))

        let model = makeModel(kokoro: kokoro, delay: .milliseconds(400))
        model.chooseVoice(.kokoro(.heart))
        model.readAgain(lecture)

        model.open(lecture)
        #expect(openReader(model) == nil)
        #expect(model.notice == "This PDF is being prepared. It'll open when it's ready.")

        model.remove(lecture)
        #expect(model.notice == "This PDF is being prepared. Cancel that first, then remove it.")
        #expect(try library.load(id: lecture.id) != nil)

        try await waitForImport(model)
        #expect(openReader(model) != nil)
        model.closeReader()
    }

    @Test func aMissingAudioFileIsMadeAgainWithItsOwnVoice() async throws {
        let kokoro = try environment(installed: true)
        let bella = try #require(KokoroVoice.all.first { $0.name == "Bella" })
        let model = makeModel(kokoro: kokoro)
        let lecture = try await addPDF(to: model, voice: .kokoro(bella))
        try FileManager.default.removeItem(at: library.generatedAudioURL(forID: lecture.id))

        model.chooseVoice(.kokoro(.heart))
        model.open(lecture)
        try await waitForImport(model)
        #expect(log.all == [.kokoro(bella)])
        #expect(openReader(model)?.lecture.document?.voiceName == bella.displayName)
        model.closeReader()
    }

    @Test func missingAudioGoesToAppleOnlyWhenItsVoiceIsGone() async throws {
        let kokoro = try environment(installed: true)
        let model = makeModel(kokoro: kokoro)
        let lecture = try await addPDF(to: model, voice: .kokoro(.heart))
        try FileManager.default.removeItem(at: library.generatedAudioURL(forID: lecture.id))
        model.removeKokoro()

        model.open(lecture)
        try await waitForImport(model)
        #expect(log.all == [.apple])
        model.closeReader()
    }
}
