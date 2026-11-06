@preconcurrency import AVFoundation
import Foundation
import Observation
import PodcastReaderCore

/// Which voice reads a PDF.
package enum ReadingVoice: Codable, Hashable, Sendable {
    case apple
    case kokoro(KokoroVoice)
}

@MainActor
@Observable
public final class AppModel {
    enum KokoroSetupState: Equatable {
        case idle
        case confirming(KokoroVoice)
        case installing(fraction: Double, voice: KokoroVoice)
        case failed(message: String, voice: KokoroVoice)
        case confirmingRemoval
    }

    enum Screen {
        case home
        case reader(ReaderModel)
        case missingAudio(Lecture, message: String?)
    }

    enum ImportState {
        case idle
        case working(title: String, phase: TranscriptionPhase?, isDocument: Bool)
        case failed(message: String, retry: URL?)
    }

    var screen: Screen = .home
    var importState: ImportState = .idle
    private(set) var lectures: [Lecture] = []
    /// A short explanation for something that didn't happen, shown on the home screen.
    private(set) var notice: String?
    /// How long the current job has left, once there's enough to go on.
    private(set) var importRemainingText: String?
    private(set) var kokoroSetup: KokoroSetupState = .idle
    private(set) var isKokoroInstalled: Bool
    private var chosenVoice: ReadingVoice?

    let library: Library

    @ObservationIgnored private let isMuted: Bool
    @ObservationIgnored private let kokoro: KokoroEnvironment
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let engineFactory: @Sendable (ReadingVoice, String) -> any SpeechEngine
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private var importTask: Task<Void, Never>?
    @ObservationIgnored private var importStartedAt = Date()
    @ObservationIgnored private var importProgressBase: (fraction: Double, date: Date)?
    @ObservationIgnored private var setupTask: Task<Void, Never>?
    @ObservationIgnored private var refreshCount = 0
    /// A PDF whose speech is being made again, which can't be opened or removed meanwhile.
    @ObservationIgnored private var lectureBeingPrepared: String?
    @ObservationIgnored private var jobToRetry: (lecture: Lecture, voice: ReadingVoice)?
    /// Looking through the Mac's voices takes a moment, and rows ask for this as they draw.
    @ObservationIgnored private lazy var appleVoiceName = SpeechRenderer.bestVoiceName() ?? "Apple voice"

    private static let voiceKey = "readingVoice"
    /// The start of a job says little about its speed: the voice is still loading, and work
    /// picked up from before quitting arrives all at once.
    private static let settlingTime: TimeInterval = 15

    public convenience init() {
        self.init(library: Library(directory: Library.defaultDirectory), kokoro: KokoroEnvironment())
    }

    package init(
        library: Library,
        isMuted: Bool = false,
        // Only the app itself uses the real install, so tests and tools can't pick it up.
        kokoro: KokoroEnvironment = KokoroEnvironment(root: URL(fileURLWithPath: "/nonexistent/kokoro")),
        defaults: UserDefaults = .standard,
        engineFactory: (@Sendable (ReadingVoice, String) -> any SpeechEngine)? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.library = library
        self.isMuted = isMuted
        self.kokoro = kokoro
        self.defaults = defaults
        self.now = now
        self.engineFactory = engineFactory ?? { voice, lectureID in
            switch voice {
            case .apple:
                return SpeechRenderer()
            case .kokoro(let kokoroVoice):
                return KokoroSpeechEngine(
                    environment: kokoro,
                    voice: kokoroVoice,
                    workFolder: library.kokoroWorkFolder(forID: lectureID, voice: kokoroVoice)
                )
            }
        }
        isKokoroInstalled = kokoro.isInstalled
        if let data = defaults.data(forKey: Self.voiceKey) {
            chosenVoice = try? JSONDecoder().decode(ReadingVoice.self, from: data)
        }
    }

    // MARK: Voice

    /// With no choice made, this is Heart once Kokoro is set up. A Kokoro voice that's no
    /// longer installed falls back to Apple's, rather than failing on the next PDF.
    var readingVoice: ReadingVoice {
        switch chosenVoice {
        case .apple: return .apple
        case .kokoro(let voice): return isKokoroInstalled ? .kokoro(voice) : .apple
        case nil: return isKokoroInstalled ? .kokoro(.heart) : .apple
        }
    }

    /// What to call the current voice, such as "Heart" or "Ava (Premium)".
    var readingVoiceName: String {
        switch readingVoice {
        case .apple: return appleVoiceName
        case .kokoro(let voice): return voice.name
        }
    }

    var bestAppleVoiceName: String {
        appleVoiceName
    }

    /// Choosing Kokoro before it's set up asks first, and changes nothing until it's done.
    func chooseVoice(_ voice: ReadingVoice) {
        if case .kokoro(let kokoroVoice) = voice, !isKokoroInstalled {
            kokoroSetup = .confirming(kokoroVoice)
            return
        }
        setChosenVoice(voice)
    }

    private func setChosenVoice(_ voice: ReadingVoice) {
        chosenVoice = voice
        defaults.set(try? JSONEncoder().encode(voice), forKey: Self.voiceKey)
    }

    func dismissKokoroSetup() {
        kokoroSetup = .idle
    }

    func confirmKokoroSetup() {
        let voice: KokoroVoice
        switch kokoroSetup {
        case .confirming(let chosen), .failed(_, let chosen): voice = chosen
        default: return
        }
        kokoroSetup = .installing(fraction: 0, voice: voice)
        let kokoro = kokoro
        let onProgress: @Sendable (Double) -> Void = { [weak self] fraction in
            Task { @MainActor in
                if case .installing(_, let voice) = self?.kokoroSetup {
                    self?.kokoroSetup = .installing(fraction: fraction, voice: voice)
                }
            }
        }
        setupTask = Task {
            do {
                try await kokoro.install(onProgress: onProgress)
                isKokoroInstalled = true
                setChosenVoice(.kokoro(voice))
                kokoroSetup = .idle
            } catch is CancellationError {
                kokoroSetup = .idle
            } catch {
                kokoroSetup = .failed(message: Copy.setupFailed, voice: voice)
            }
            setupTask = nil
        }
    }

    func cancelKokoroSetup() {
        setupTask?.cancel()
    }

    func askToRemoveKokoro() {
        kokoroSetup = .confirmingRemoval
    }

    /// PDFs already prepared keep working, because their audio is separate.
    func removeKokoro() {
        kokoroSetup = .idle
        guard importTask == nil else {
            notice = Copy.busyRemovingKokoro
            return
        }
        try? kokoro.remove()
        library.removeUnfinishedKokoroWork()
        isKokoroInstalled = kokoro.isInstalled
    }

    func canReadAgain(_ lecture: Lecture) -> Bool {
        guard let document = lecture.document else { return false }
        if case .working = importState { return false }
        switch readingVoice {
        case .apple: return document.voiceName != appleVoiceName
        case .kokoro(let voice): return document.voiceName != voice.displayName
        }
    }

    /// Prepares a PDF again with the current voice, keeping its bookmarks and place.
    func readAgain(_ lecture: Lecture) {
        regenerateAudio(for: lecture, voice: readingVoice)
    }

    /// The voice a missing audio file should be made again with: the one it had, if possible.
    private func voice(of lecture: Lecture) -> ReadingVoice {
        let original = KokoroVoice.all.first { $0.displayName == lecture.document?.voiceName }
        if let original, isKokoroInstalled {
            return .kokoro(original)
        }
        return .apple
    }

    var isImporting: Bool {
        importTask != nil
    }

    func refresh() {
        isKokoroInstalled = kokoro.isInstalled
        let library = library
        refreshCount += 1
        let thisRefresh = refreshCount
        Task {
            let found = await Task.detached { library.all() }.value
            // A slow read that a later change has overtaken would bring back old data.
            if thisRefresh == refreshCount {
                lectures = found
            }
        }
    }

    /// Adds a lecture or PDF, or opens it if the same file was added before.
    /// Ignored while another import is running, so the running job isn't disturbed.
    func importFile(_ url: URL) {
        guard importTask == nil else { return }
        guard let kind = AudioImport.kind(of: url) else {
            importState = .failed(message: Copy.unreadable, retry: nil)
            return
        }

        let title = url.deletingPathExtension().lastPathComponent
        jobToRetry = nil
        beginJob()
        importState = .working(title: title, phase: nil, isDocument: kind == .document)
        importTask = Task {
            let lecture = await runImport(of: url, title: title, kind: kind)
            finishJob(with: lecture)
        }
    }

    private func beginJob() {
        importStartedAt = now()
        importProgressBase = nil
        importRemainingText = nil
        notice = nil
    }

    /// Opens the result, unless the person went on to read something else meanwhile. A long
    /// job shouldn't pull them out of it, so then it just says it's ready.
    private func finishJob(with lecture: Lecture?) {
        importTask = nil
        importRemainingText = nil
        lectureBeingPrepared = nil
        notice = nil
        guard let lecture else { return }
        if case .home = screen {
            open(lecture)
        } else {
            remember(lecture)
            notice = "\(lecture.title) is ready."
        }
    }

    private func kokoroWentMissing() {
        isKokoroInstalled = kokoro.isInstalled
        importState = .failed(message: Copy.kokoroMissing, retry: nil)
    }

    /// Reading a PDF again doesn't need the PDF itself, so it can always be tried again.
    var canRetryImport: Bool {
        guard case .failed(_, let url) = importState else { return false }
        return url != nil || jobToRetry != nil
    }

    /// For the Try again button after a job fails.
    func retryImport() {
        guard case .failed(_, let url) = importState else { return }
        if let job = jobToRetry {
            regenerateAudio(for: job.lecture, voice: job.voice)
        } else if let url {
            importFile(url)
        }
    }

    func cancelImport() {
        importTask?.cancel()
    }

    func dismissImportError() {
        importState = .idle
    }

    func open(_ lecture: Lecture) {
        guard lecture.id != lectureBeingPrepared else {
            notice = Copy.beingPrepared
            return
        }
        notice = nil
        if lecture.document != nil, library.documentURL(for: lecture) == nil {
            screen = .missingAudio(lecture, message: nil)
            return
        }
        guard let audioURL = library.audioURL(for: lecture) else {
            if lecture.document != nil {
                regenerateAudio(for: lecture, voice: voice(of: lecture))
            } else {
                screen = .missingAudio(lecture, message: nil)
            }
            return
        }
        var opened = lecture
        opened.lastOpenedAt = Date()

        let reader = ReaderModel(
            lecture: opened,
            audioURL: audioURL,
            library: library,
            documentURL: library.documentURL(for: opened),
            isMuted: isMuted
        )
        reader.saveReadingStateInBackground()
        screen = .reader(reader)
        Task {
            do {
                try await reader.start()
            } catch {
                closeReader()
                importState = .failed(message: Copy.unreadable, retry: nil)
            }
        }
    }

    /// Makes a PDF's speech again: when its audio has gone missing, or to change its voice.
    /// Its text, bookmarks and place all carry over.
    private func regenerateAudio(for lecture: Lecture, voice: ReadingVoice) {
        guard importTask == nil else {
            notice = Copy.busy
            return
        }
        screen = .home
        let library = library
        let title = lecture.title
        beginJob()
        lectureBeingPrepared = lecture.id
        jobToRetry = (lecture, voice)
        importState = .working(title: title, phase: nil, isDocument: true)
        let onProgress = documentProgress(title: title)
        let engine = engineFactory(voice, lecture.id)
        importTask = Task {
            var updated: Lecture?
            do {
                updated = try await DocumentImporter(library: library, engine: engine)
                    .regenerateAudio(for: lecture, onProgress: onProgress)
                importState = .idle
                jobToRetry = nil
            } catch is CancellationError {
                importState = .idle
                jobToRetry = nil
            } catch KokoroError.notInstalled {
                jobToRetry = nil
                kokoroWentMissing()
            } catch {
                importState = .failed(message: Copy.documentFailed, retry: library.documentURL(for: lecture))
            }
            finishJob(with: updated)
        }
    }

    /// Points a moved lecture at its audio, refusing a different recording.
    func locateAudio(for lecture: Lecture, at url: URL) {
        do {
            let updated = try library.relocate(lecture, to: url)
            try library.save(updated)
            open(updated)
        } catch LibraryError.differentAudio {
            screen = .missingAudio(lecture, message: lecture.document == nil ? Copy.differentAudio : Copy.differentDocument)
        } catch {
            screen = .missingAudio(lecture, message: Copy.unreadable)
        }
    }

    func closeReader() {
        if case .reader(let reader) = screen {
            reader.close()
            remember(reader.currentLecture)
        }
        screen = .home
        refresh()
    }

    /// Keeps the list current straight away. Reading it back from disk takes a moment, and
    /// opening a stale copy in the meantime would save its old position over the new one.
    private func remember(_ lecture: Lecture) {
        lectures.removeAll { $0.id == lecture.id }
        lectures.insert(lecture, at: 0)
    }

    func remove(_ lecture: Lecture) {
        guard lecture.id != lectureBeingPrepared else {
            notice = Copy.busyRemovingLecture
            return
        }
        try? library.remove(id: lecture.id)
        refreshCount += 1
        lectures.removeAll { $0.id == lecture.id }
    }

    /// Returns the lecture to open, or nil if there's nothing to open.
    private func runImport(of url: URL, title: String, kind: ImportKind) async -> Lecture? {
        let library = library
        let id: String
        do {
            id = try await Task.detached { try library.lectureID(forAudioAt: url) }.value
        } catch {
            importState = .failed(message: Copy.unreadable, retry: nil)
            return nil
        }

        do {
            if let existing = try? library.load(id: id) {
                importState = .idle
                return isSourceMissing(existing) ? try library.relocate(existing, to: url) : existing
            }

            let lecture: Lecture
            switch kind {
            case .audio: lecture = try await importAudio(at: url, title: title)
            case .document: lecture = try await importDocument(at: url, id: id, title: title)
            }
            importState = .idle
            return lecture
        } catch is CancellationError {
            importState = .idle
        } catch KokoroError.notInstalled {
            kokoroWentMissing()
        } catch TranscriberError.unreadableFile, DocumentError.unreadable {
            importState = .failed(message: Copy.unreadable, retry: nil)
        } catch TranscriberError.noSpeechFound {
            importState = .failed(message: Copy.noSpeech, retry: nil)
        } catch DocumentError.noReadableText {
            importState = .failed(message: Copy.noReadableText, retry: nil)
        } catch DocumentError.passwordProtected {
            importState = .failed(message: Copy.passwordProtected, retry: nil)
        } catch {
            let message = kind == .document ? Copy.documentFailed : Copy.transcriptionFailed
            importState = .failed(message: message, retry: url)
        }
        return nil
    }

    private func importAudio(at url: URL, title: String) async throws -> Lecture {
        let transcript = try await Transcriber().transcribe(audioAt: url) { [weak self] phase in
            Task { @MainActor in
                self?.update(phase: phase, title: title, isDocument: false)
            }
        }
        let file = try AVAudioFile(forReading: url)
        let duration = Double(file.length) / file.processingFormat.sampleRate
        let lecture = try library.makeLecture(audioAt: url, transcript: transcript, duration: duration)
        try library.save(lecture)
        return lecture
    }

    private func importDocument(at url: URL, id: String, title: String) async throws -> Lecture {
        let engine = engineFactory(readingVoice, id)
        return try await DocumentImporter(library: library, engine: engine)
            .importDocument(at: url, onProgress: documentProgress(title: title))
    }

    /// Notes the time as the progress happens, as a busy interface can take a while to hear.
    private func documentProgress(title: String) -> @Sendable (Double) -> Void {
        let now = now
        return { [weak self] fraction in
            let date = now()
            Task { @MainActor in
                self?.update(phase: .transcribing(fraction), title: title, isDocument: true)
                self?.updateRemainingText(fraction: fraction, at: date)
            }
        }
    }

    private func isSourceMissing(_ lecture: Lecture) -> Bool {
        lecture.document == nil ? library.audioURL(for: lecture) == nil : library.documentURL(for: lecture) == nil
    }

    /// Progress updates can arrive just after a job ends, so only apply them mid-job.
    private func update(phase: TranscriptionPhase, title: String, isDocument: Bool) {
        if case .working = importState {
            importState = .working(title: title, phase: phase, isDocument: isDocument)
        }
    }

    private func updateRemainingText(fraction: Double, at date: Date) {
        guard case .working = importState else { return }
        guard let base = importProgressBase, date.timeIntervalSince(importStartedAt) >= Self.settlingTime else {
            importProgressBase = (fraction, date)
            return
        }
        importRemainingText = TimeRemaining.text(
            elapsed: date.timeIntervalSince(base.date),
            fraction: (fraction - base.fraction) / (1 - base.fraction)
        )
    }

    private enum Copy {
        static let unreadable = "This file couldn't be opened. Try an MP3, M4A, WAV or PDF file."
        static let noSpeech = "No speech was found in this file."
        static let transcriptionFailed = "Transcription didn't finish. Try again."
        static let differentAudio = "That's a different file from this lecture. Choose the original audio."
        static let differentDocument = "That's a different PDF. Choose the original file."
        static let noReadableText = "This PDF has no readable text. It may be a scan, which isn't supported yet."
        static let passwordProtected = "This PDF is password protected. Remove the password and try again."
        static let documentFailed = "Preparing this PDF didn't finish. Try again."
        static let busy = "Finish or cancel the current import first, then open this PDF."
        static let beingPrepared = "This PDF is being prepared. It'll open when it's ready."
        static let busyRemovingLecture = "This PDF is being prepared. Cancel that first, then remove it."
        static let busyRemovingKokoro = "Finish or cancel the current job first, then remove Kokoro."
        static let kokoroMissing = "Kokoro isn't set up on this Mac any more. Choose it under Voice for PDFs to set it up again."
        static let setupFailed = "Setting up Kokoro didn't finish. Check your connection and try again."
    }
}
