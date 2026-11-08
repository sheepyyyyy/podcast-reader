import AppKit
import Foundation
import Observation
import PodcastReaderCore

/// Everything about one open lecture: playback, following along, the side panel,
/// bookmarks and saving.
@MainActor
@Observable
package final class ReaderModel {
    package enum PanelTab {
        case search
        case bookmarks
    }

    package private(set) var lecture: Lecture
    package let player: PlayerController
    /// The PDF being read aloud. Nil for an audio lecture.
    package let documentURL: URL?
    package private(set) var activeWord: Int?
    /// False while the user has scrolled away to read ahead.
    var isFollowing = true

    private(set) var controlsVisible = true
    private(set) var isFullScreen = false

    package private(set) var panel: PanelTab?
    package var query = "" {
        didSet {
            if query != oldValue { scheduleSearch() }
        }
    }
    private(set) var matches: [SearchMatch] = []
    private(set) var isSearching = false
    @ObservationIgnored var isSearchFieldFocused = false
    /// Changes each time search is opened, so the panel can focus its text field.
    private(set) var searchFocusRequest = 0
    private(set) var toast: String?

    @ObservationIgnored private let library: Library
    @ObservationIgnored private let clock: WordClock
    @ObservationIgnored private let controlsFadeDelay: TimeInterval
    @ObservationIgnored private let saveInterval: TimeInterval
    @ObservationIgnored private let toastDuration: TimeInterval
    /// Keeps saves in order, so an older background save can't overwrite a newer one.
    @ObservationIgnored private let saveQueue = DispatchQueue(label: "PodcastReader.save")

    @ObservationIgnored private var hasStarted = false
    @ObservationIgnored private var isClosed = false
    @ObservationIgnored private var fadeTask: Task<Void, Never>?
    @ObservationIgnored private var lastFadeRestart = Date.distantPast
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var saveLoop: Task<Void, Never>?
    @ObservationIgnored private var searchIndex: SearchIndex?
    @ObservationIgnored private var terminationObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var occlusionObserver: (any NSObjectProtocol)?
    /// False while no one can see the reader, such as with the window covered or minimized
    /// while listening. The highlight then waits, since moving it is most of the work
    /// playing does, and catches up as soon as the window can be seen.
    @ObservationIgnored private(set) var isOnScreen = true

    package init(
        lecture: Lecture,
        audioURL: URL,
        library: Library,
        documentURL: URL? = nil,
        isMuted: Bool = false,
        controlsFadeDelay: TimeInterval = 3,
        saveInterval: TimeInterval = 5,
        toastDuration: TimeInterval = 1.5
    ) {
        self.lecture = lecture
        self.library = library
        self.documentURL = documentURL
        self.controlsFadeDelay = controlsFadeDelay
        self.saveInterval = saveInterval
        self.toastDuration = toastDuration
        clock = WordClock(words: lecture.transcript.words)
        player = PlayerController(url: audioURL, isMuted: isMuted)
        player.onTick = { [weak self] time in
            self?.updateActiveWord(at: time)
        }
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.savePosition() }
        }
        occlusionObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeOcclusionStateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.setOnScreen(NSApp?.occlusionState.contains(.visible) ?? true)
            }
        }
    }

    func setOnScreen(_ value: Bool) {
        guard value != isOnScreen else { return }
        isOnScreen = value
        updateActiveWord(at: player.exactTime)
    }

    var activeLine: Int? {
        activeWord.map { lecture.transcript.lineIndex(forWord: $0) }
    }

    var handlesClosePanel: Bool {
        panel != nil
    }

    /// Loads the audio and returns to the saved position, paused.
    package func start() async throws {
        try await player.waitUntilReady()
        player.seek(to: lecture.position)
        hasStarted = true
        startSaveLoop()
    }

    // MARK: Playback

    /// Starts the audio at a word. A paused lecture stays paused with the highlight moved.
    package func jump(toWord index: Int) {
        guard lecture.transcript.words.indices.contains(index) else { return }
        isFollowing = true
        player.seek(to: lecture.transcript.words[index].start)
    }

    func backToNow() {
        isFollowing = true
    }

    func togglePlay() {
        player.togglePlay()
        if !player.isPlaying {
            saveReadingStateInBackground()
        }
    }

    func cycleSpeed() {
        player.setRate(PlaybackRules.nextSpeed(after: player.rate))
    }

    func perform(_ command: ReaderCommand) {
        switch command {
        case .togglePlay: togglePlay()
        case .skip(let delta): player.skip(by: delta)
        case .addBookmark: addBookmark()
        case .openSearch: openPanel(.search)
        case .openBookmarks: openPanel(.bookmarks)
        case .closePanel: panel = nil
        }
    }

    /// Returns false for a key the reader has no use for right now, so that the
    /// system still gets it.
    func handle(_ command: ReaderCommand) -> Bool {
        if command == .closePanel && !handlesClosePanel { return false }
        perform(command)
        return true
    }

    /// Handles a key press. Returns false to leave it for the system or the text field.
    /// The focus state backs up the responder check, so that keys can't be swallowed
    /// while typing if the text field turns out not to edit through an NSTextView.
    func handleKey(keyCode: UInt16, modifiers: KeyModifiers, responderIsTextView: Bool) -> Bool {
        guard !isClosed else { return false }
        let command = ReaderKeys.command(
            keyCode: keyCode,
            modifiers: modifiers,
            // The only text field is on the search tab. Its focus can outlast the tab for a
            // moment as the panel slides away, which must not swallow the next key press.
            isTyping: panel == .search && (responderIsTextView || isSearchFieldFocused)
        )
        guard let command else { return false }
        return handle(command)
    }

    /// A mouse wheel may not report a scroll phase, so this catches it directly.
    /// Scrolling the side panel's lists doesn't count as leaving the captions.
    func noteScrollWheel(x: Double, windowWidth: Double) {
        if panel != nil, x >= windowWidth - SidePanel.width { return }
        isFollowing = false
    }

    // MARK: Full screen controls

    func setFullScreen(_ value: Bool) {
        isFullScreen = value
        lastFadeRestart = .distantPast
        noteMouseMoved()
    }

    /// Shows the controls, and in full screen starts the countdown to fading them.
    func noteMouseMoved() {
        // A moving mouse reports hundreds of times a second, and restarting the countdown
        // this often makes no difference to anyone.
        let now = Date()
        if controlsVisible, now.timeIntervalSince(lastFadeRestart) < 0.1 { return }
        lastFadeRestart = now

        fadeTask?.cancel()
        if !controlsVisible {
            controlsVisible = true
        }
        guard isFullScreen else { return }
        let delay = controlsFadeDelay
        fadeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.controlsVisible = false
        }
    }

    // MARK: Side panel and search

    package func openPanel(_ tab: PanelTab) {
        panel = tab
        if tab == .search {
            searchFocusRequest += 1
        }
    }

    func closePanel() {
        panel = nil
    }

    private func scheduleSearch() {
        searchTask?.cancel()
        let text = query
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else {
            isSearching = false
            matches = []
            return
        }
        isSearching = true
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, let self else { return }
            let index = await self.loadSearchIndex()
            let found = await Task.detached { index.search(text) }.value
            guard !Task.isCancelled else { return }
            self.matches = found
            self.isSearching = false
        }
    }

    private func loadSearchIndex() async -> SearchIndex {
        if let searchIndex { return searchIndex }
        let transcript = lecture.transcript
        let index = await Task.detached { SearchIndex(transcript: transcript) }.value
        searchIndex = index
        return index
    }

    // MARK: Bookmarks

    package func addBookmark() {
        // Worked out afresh, as the highlight waits while the window can't be seen.
        let word = isOnScreen ? activeWord : clock.activeWordIndex(at: player.exactTime)
        guard lecture.addBookmark(wordIndex: word ?? 0) else { return }
        saveLectureInBackground()
        showToast("Bookmarked")
    }

    func removeBookmark(id: UUID) {
        lecture.removeBookmark(id: id)
        saveLectureInBackground()
    }

    private func showToast(_ text: String) {
        toast = text
        toastTask?.cancel()
        let duration = toastDuration
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }

    // MARK: Saving

    func savePosition() {
        saveReadingState()
    }

    /// Waits for background saves to finish.
    func finishSaving() {
        saveQueue.sync {}
    }

    /// Ends this reader for good, saving where the user stopped.
    package func close() {
        guard !isClosed else { return }
        isClosed = true
        savePosition()
        saveLoop?.cancel()
        fadeTask?.cancel()
        toastTask?.cancel()
        searchTask?.cancel()
        for observer in [terminationObserver, occlusionObserver].compactMap(\.self) {
            NotificationCenter.default.removeObserver(observer)
        }
        player.stop()
    }

    private func startSaveLoop() {
        let interval = saveInterval
        saveLoop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled, let self else { return }
                if self.player.isPlaying {
                    self.saveReadingStateInBackground()
                }
            }
        }
    }

    /// The lecture as it stands now. Until the audio has loaded, the player's time isn't
    /// meaningful, so the saved position stands.
    var currentLecture: Lecture {
        var copy = lecture
        if hasStarted {
            copy.position = player.exactTime
        }
        return copy
    }

    /// Waits until written, for when the app or the next screen needs the result right away.
    private func saveReadingState() {
        let copy = currentLecture
        let library = library
        saveQueue.sync {
            try? library.saveReadingState(of: copy)
        }
    }

    /// Where the person is up to, in a small file, which is quick enough for every few seconds.
    func saveReadingStateInBackground() {
        let copy = currentLecture
        let library = library
        saveQueue.async {
            try? library.saveReadingState(of: copy)
        }
    }

    /// The whole lecture, for changes like bookmarks. A long document's lecture can take a
    /// noticeable moment to write, so this can't hold up the highlight.
    private func saveLectureInBackground() {
        let copy = currentLecture
        let library = library
        saveQueue.async {
            try? library.save(copy)
        }
    }

    private func updateActiveWord(at time: TimeInterval) {
        guard isOnScreen else {
            player.tick(at: nil)
            return
        }
        let word = clock.activeWordIndex(at: time)
        // Assigning always notifies observers, even of the same word.
        if word != activeWord {
            activeWord = word
        }
        player.tick(at: clock.nextChange(after: time))
    }
}
