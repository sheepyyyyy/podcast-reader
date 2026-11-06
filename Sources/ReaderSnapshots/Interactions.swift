#if DEBUG
import AppKit
import PDFKit
@testable import PodcastReaderCore
@testable import PodcastReaderUI
import Synchronization
import SwiftUI

/// Sends real mouse, keyboard and scroll events through the application's event queue to the
/// app's real views, in a window off every screen. This covers what model tests can't: that a
/// click on a word actually reaches the word, that shortcuts get past focus, and so on.
@MainActor
final class EventDriver {
    let window: NSWindow
    private var eventNumber = 0

    init(window: NSWindow) {
        self.window = window
    }

    private func send(_ event: NSEvent?) async throws {
        guard let event else { throw MissingValue() }
        NSApp.postEvent(event, atStart: false)
        try await Task.sleep(for: .milliseconds(120))
    }

    /// `point` is in the window's coordinates: from the bottom left, in points.
    func mouse(_ type: NSEvent.EventType, at point: CGPoint, clickCount: Int = 1) async throws {
        // A real click's press and release share a number, and gestures pair them by it.
        if type == .leftMouseDown || type == .mouseMoved {
            eventNumber += 1
        }
        try await send(NSEvent.mouseEvent(
            with: type,
            location: point,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: eventNumber,
            clickCount: clickCount,
            pressure: type == .leftMouseUp ? 0 : 1
        ))
    }

    func click(at point: CGPoint) async throws {
        try await mouse(.mouseMoved, at: point, clickCount: 0)
        try await mouse(.leftMouseDown, at: point)
        try await mouse(.leftMouseUp, at: point)
        // Long enough for a gesture to rule out a double click.
        try await Task.sleep(for: .milliseconds(500))
    }

    /// The first click a synthetic window receives is always dropped, whatever it lands on,
    /// so this spends it on an empty corner.
    func prime() async throws {
        try await click(at: CGPoint(x: window.frame.width - 3, y: window.frame.height - 3))
    }

    func drag(from start: CGPoint, to end: CGPoint) async throws {
        try await mouse(.leftMouseDown, at: start)
        for step in 1...4 {
            let fraction = CGFloat(step) / 4
            try await mouse(.leftMouseDragged, at: CGPoint(
                x: start.x + (end.x - start.x) * fraction,
                y: start.y + (end.y - start.y) * fraction
            ))
        }
        try await mouse(.leftMouseUp, at: end)
        try await Task.sleep(for: .milliseconds(200))
    }

    func key(_ keyCode: UInt16, characters: String = "", modifiers: NSEvent.ModifierFlags = []) async throws {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            try await send(NSEvent.keyEvent(
                with: type,
                location: .zero,
                modifierFlags: modifiers,
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                characters: characters,
                charactersIgnoringModifiers: characters,
                isARepeat: false,
                keyCode: keyCode
            ))
        }
        try await Task.sleep(for: .milliseconds(100))
    }

    /// A mouse wheel notch with no gesture phase, as a plain wheel mouse sends.
    func scrollWheel(at point: CGPoint, lines: Int32 = -4) async throws {
        let global = window.convertPoint(toScreen: point)
        let screenHeight = NSScreen.screens.first?.frame.height ?? 0
        guard let cgEvent = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .line,
            wheelCount: 1,
            wheel1: lines,
            wheel2: 0,
            wheel3: 0
        ) else { throw MissingValue() }
        cgEvent.location = CGPoint(x: global.x, y: screenHeight - global.y)
        cgEvent.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(window.windowNumber))
        cgEvent.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(window.windowNumber))
        // The event's own window number, which NSEvent reads to find its window.
        if let windowField = CGEventField(rawValue: 51) {
            cgEvent.setIntegerValueField(windowField, value: Int64(window.windowNumber))
        }
        let event = NSEvent(cgEvent: cgEvent)
        try await send(event)
        try await Task.sleep(for: .milliseconds(200))
    }
}

/// Runs each check and keeps a score.
@MainActor
final class Checklist {
    private(set) var failures = 0
    private(set) var total = 0

    func check(_ name: String, _ passed: Bool, _ detail: @autoclosure () -> String = "") {
        total += 1
        if !passed { failures += 1 }
        print("\(passed ? "PASS" : "FAIL") \(name)\(passed ? "" : "  \(detail())")")
    }
}

private enum Key {
    static let space: UInt16 = 49, left: UInt16 = 123, right: UInt16 = 124, escape: UInt16 = 53
    static let b: UInt16 = 11, f: UInt16 = 3, a: UInt16 = 0
}

/// Window coordinates for a point measured from the top left, which is how the layout reads.
private func fromTop(_ x: CGFloat, _ y: CGFloat, height: CGFloat) -> CGPoint {
    CGPoint(x: x, y: height - y)
}

@MainActor
func interact(output: URL, audio: URL) async throws {
    let scratch = FileManager.default.temporaryDirectory
        .appending(path: "ReaderInteract-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: scratch) }
    let library = Library(directory: scratch)
    let list = Checklist()
    let size = CGSize(width: 1180, height: 760)

    // MARK: Audio captions

    let words = sampleText.split(separator: " ").enumerated().map { index, text in
        Word(text: String(text), start: Double(index) * 0.06, end: Double(index + 1) * 0.06)
    }
    let lecture = try library.makeLecture(audioAt: audio, transcript: Transcript(words: words), duration: 8)
    try library.save(lecture)
    let reader = ReaderModel(lecture: lecture, audioURL: audio, library: library, isMuted: true)
    try await reader.start()
    reader.player.seek(to: 3.2)
    var closed = false
    let host = OffscreenHost(
        ReaderView(model: reader, onClose: { closed = true }).preferredColorScheme(.dark),
        size: size
    )
    try await settle()
    let driver = EventDriver(window: host.nsWindow)
    try await driver.prime()
    let height = size.height

    print("--- Audio captions")
    let transcript = lecture.transcript
    let activeLine = try require(reader.activeLine)
    let lineStart = transcript.words[transcript.lines[activeLine].wordRange.lowerBound].start
    // The active line sits 38% down, and the first word starts at the left margin.
    try await driver.click(at: fromTop(size.width * 0.068 + 12, height * 0.38, height: height))
    check(list, "clicking a word jumps to that word", reader.player.currentTime == lineStart, "at \(reader.player.currentTime), wanted \(lineStart)")
    check(list, "clicking a word while paused stays paused", !reader.player.isPlaying)

    try await driver.key(Key.space, characters: " ")
    check(list, "Space starts playback", reader.player.isPlaying)
    try await driver.key(Key.space, characters: " ")
    check(list, "Space pauses playback", !reader.player.isPlaying)

    reader.player.seek(to: 7)
    try await driver.key(Key.left, characters: "\u{F702}", modifiers: [.function, .numericPad])
    check(list, "left arrow goes back 5 s", abs(reader.player.currentTime - 2) < 0.001, "at \(reader.player.currentTime)")
    reader.player.seek(to: 1)
    try await driver.key(Key.right, characters: "\u{F703}", modifiers: [.function, .numericPad])
    check(list, "right arrow goes forward 5 s", abs(reader.player.currentTime - 6) < 0.001, "at \(reader.player.currentTime)")
    try await driver.key(Key.left, characters: "\u{F702}", modifiers: [.shift, .function, .numericPad])
    check(list, "shift left goes back 30 s", reader.player.currentTime == 0, "at \(reader.player.currentTime)")

    reader.player.seek(to: 3)
    try await driver.key(Key.b, characters: "b")
    check(list, "B adds a bookmark", reader.lecture.bookmarks.count == 1, "\(reader.lecture.bookmarks.count) bookmarks")

    // MARK: Search box

    print("--- Search box")
    try await driver.key(Key.f, characters: "f", modifiers: .command)
    check(list, "Command F opens search", reader.panel == .search)
    try await settle(0.6)
    let beforeTyping = reader.player.currentTime
    let bookmarksBeforeTyping = reader.lecture.bookmarks.count
    try await driver.key(Key.a, characters: "a")
    try await driver.key(Key.b, characters: "b")
    try await driver.key(Key.space, characters: " ")
    try await driver.key(Key.a, characters: "a")
    check(list, "typing fills the search box", reader.query == "ab a", "query is \"\(reader.query)\"")
    check(list, "B and Space in the box don't bookmark or play", reader.lecture.bookmarks.count == bookmarksBeforeTyping && !reader.player.isPlaying)
    try await driver.key(Key.left, characters: "\u{F702}", modifiers: [.function, .numericPad])
    check(list, "arrows in the box don't skip", reader.player.currentTime == beforeTyping, "at \(reader.player.currentTime)")
    try await driver.key(Key.escape, characters: "\u{1B}")
    try await settle(0.5)
    check(list, "Esc closes the panel", reader.panel == nil)
    try await driver.key(Key.space, characters: " ")
    check(list, "Space controls playback again after closing", reader.player.isPlaying)
    try await driver.key(Key.space, characters: " ")

    // MARK: Scrolling

    print("--- Scrolling")
    reader.backToNow()
    try await settle(0.8)
    try await driver.scrollWheel(at: fromTop(size.width / 2, height * 0.4, height: height))
    check(list, "a mouse wheel stops the following", !reader.isFollowing)
    try await settle(0.4)
    try host.capture(to: output.appending(path: "interact-scrolled.png"))
    // "Back to now" is centered above the control bar.
    try await driver.click(at: CGPoint(x: size.width / 2, y: 132))
    check(list, "Back to now turns following back on", reader.isFollowing)

    // Scrolling over the side panel isn't checked here: macOS clamps the position of events
    // outside the screen, so this window can't get a true one. A unit test covers the rule.

    // MARK: Control bar

    print("--- Control bar")
    let centerX = size.width / 2
    let buttonY: CGFloat = 40
    reader.player.seek(to: 1)
    try await driver.click(at: CGPoint(x: centerX, y: buttonY))
    check(list, "play button starts playback", reader.player.isPlaying)
    try await driver.click(at: CGPoint(x: centerX, y: buttonY))
    check(list, "play button pauses", !reader.player.isPlaying)
    reader.player.seek(to: 1)
    // The buttons left of the skip group take up more room than those on the right,
    // so the play button sits 16 points right of center and each 5 s button 55 points from it.
    let playX = centerX + 16
    try await driver.click(at: CGPoint(x: playX + 55, y: buttonY))
    check(list, "forward 5 button skips", abs(reader.player.currentTime - 6) < 0.001, "at \(reader.player.currentTime)")
    try await driver.click(at: CGPoint(x: playX - 55, y: buttonY))
    check(list, "back 5 button skips", abs(reader.player.currentTime - 1) < 0.001, "at \(reader.player.currentTime)")
    let speedBefore = reader.player.rate
    try await driver.click(at: CGPoint(x: size.width - 24 - 42 - 27, y: buttonY))
    check(list, "speed button cycles", reader.player.rate != speedBefore, "still \(reader.player.rate)")
    // The progress bar runs between the side padding, above the buttons.
    try await driver.click(at: CGPoint(x: size.width / 2, y: 92))
    let middle = reader.player.duration / 2
    check(list, "clicking the progress bar seeks", abs(reader.player.currentTime - middle) < reader.player.duration * 0.1, "at \(reader.player.currentTime), wanted about \(middle)")

    try await driver.click(at: fromTop(84 + 16, 8 + 16, height: height))
    check(list, "back button closes the reader", closed)
    host.close()
    reader.close()

    // MARK: PDF page

    print("--- PDF page")
    let pdf = audio.deletingLastPathComponent().appending(path: "document.pdf")
    let imported = try await documentImporter(library: library, pdf: pdf).importDocument(at: pdf, onProgress: { _ in })
    let document = try require(imported.document)
    let pdfReader = ReaderModel(
        lecture: imported,
        audioURL: try require(library.audioURL(for: imported)),
        library: library,
        documentURL: library.documentURL(for: imported),
        isMuted: true
    )
    try await pdfReader.start()
    let pdfHost = OffscreenHost(
        ReaderView(model: pdfReader, onClose: {}).preferredColorScheme(.dark),
        size: size
    )
    try await settle()
    let pdfDriver = EventDriver(window: pdfHost.nsWindow)
    try await pdfDriver.prime()
    let pdfView = try require(pdfHost.findPDFView())
    let loaded = try require(pdfView.document)

    func windowPoint(ofWord index: Int) throws -> CGPoint {
        let location = document.locations[index]
        let page = try require(loaded.page(at: location.page))
        let selection = try require(page.selection(for: location.ranges[0].nsRange))
        let bounds = selection.bounds(for: page)
        let inView = pdfView.convert(CGPoint(x: bounds.midX, y: bounds.midY), from: page)
        return pdfView.convert(inView, to: nil)
    }

    try await pdfDriver.key(Key.space, characters: " ")
    check(list, "Space plays on the page before any click", pdfReader.player.isPlaying)
    try await pdfDriver.key(Key.space, characters: " ")
    check(list, "Space pauses on the page before any click", !pdfReader.player.isPlaying)

    let targetWord = 12
    try await pdfDriver.click(at: try windowPoint(ofWord: targetWord))
    check(list, "clicking a word on the page jumps to that word", pdfReader.activeWord == targetWord, "active word \(String(describing: pdfReader.activeWord)), wanted \(targetWord)")
    check(list, "clicking a word on the page stays paused", !pdfReader.player.isPlaying)
    try await pdfDriver.key(Key.space, characters: " ")
    check(list, "Space plays right after clicking a word", pdfReader.player.isPlaying)
    try await pdfDriver.key(Key.space, characters: " ")
    pdfReader.jump(toWord: targetWord)
    try pdfHost.capture(to: output.appending(path: "interact-pdf-click.png"))

    let page = try require(loaded.page(at: 0))
    let headerPoint = pdfView.convert(pdfView.convert(CGPoint(x: 70, y: 765), from: page), to: nil)
    try await pdfDriver.click(at: headerPoint)
    check(list, "clicking a skipped header does nothing", pdfReader.activeWord == targetWord, "active word \(String(describing: pdfReader.activeWord))")
    let marginPoint = pdfView.convert(pdfView.convert(CGPoint(x: 20, y: 400), from: page), to: nil)
    try await pdfDriver.click(at: marginPoint)
    check(list, "clicking an empty margin does nothing", pdfReader.activeWord == targetWord)

    let start = try windowPoint(ofWord: 2)
    let end = try windowPoint(ofWord: 6)
    try await pdfDriver.drag(from: start, to: end)
    let selected = pdfView.currentSelection?.string ?? ""
    check(list, "dragging selects text", selected.contains("every"), "selected \"\(selected)\"")
    check(list, "dragging doesn't jump", pdfReader.activeWord == targetWord, "active word \(String(describing: pdfReader.activeWord))")
    pdfView.clearSelection()

    try await pdfDriver.key(Key.space, characters: " ")
    check(list, "Space plays after dragging on the page", pdfReader.player.isPlaying, "playing \(pdfReader.player.isPlaying), at \(pdfReader.player.currentTime)")
    try await pdfDriver.key(Key.space, characters: " ")
    check(list, "Space pauses after dragging on the page", !pdfReader.player.isPlaying)

    try await pdfDriver.scrollWheel(at: fromTop(size.width / 2, height * 0.4, height: height))
    check(list, "a mouse wheel over the page stops the following", !pdfReader.isFollowing)
    pdfReader.backToNow()
    try await settle(0.5)

    let lastWord = imported.transcript.words.count - 2
    pdfReader.jump(toWord: lastWord)
    try await settle(1)
    let band = highlightBand(in: try pdfHost.image())
    check(list, "jumping to the last page brings the highlight into view", band != nil)
    try pdfHost.capture(to: output.appending(path: "interact-pdf-last-page.png"))
    check(list, "the view moved to the last page", pdfView.currentPage == loaded.page(at: document.locations[lastWord].page), "on page \(pdfView.currentPage.map { loaded.index(for: $0) + 1 } ?? 0)")

    // Full screen: this window can't really enter it, so this checks what happens after the
    // system's notification, using real mouse movement to bring the controls back.
    print("--- Full screen controls")
    NotificationCenter.default.post(name: NSWindow.didEnterFullScreenNotification, object: pdfHost.nsWindow)
    try await settle(0.2)
    check(list, "the controls show on entering full screen", pdfReader.controlsVisible)
    try await settle(3.3)
    check(list, "the controls fade after 3 seconds", !pdfReader.controlsVisible)
    try pdfHost.capture(to: output.appending(path: "interact-pdf-controls-faded.png"))
    try await pdfDriver.mouse(.mouseMoved, at: CGPoint(x: 400, y: 400), clickCount: 0)
    try await pdfDriver.mouse(.mouseMoved, at: CGPoint(x: 420, y: 420), clickCount: 0)
    try await settle(0.2)
    check(list, "moving the mouse brings the controls back", pdfReader.controlsVisible)
    NotificationCenter.default.post(name: NSWindow.didExitFullScreenNotification, object: pdfHost.nsWindow)
    try await settle(0.2)

    pdfHost.close()

    // Resuming: a new view on a reader that's already far into the document.
    let resumedHost = OffscreenHost(
        ReaderView(model: pdfReader, onClose: {}).preferredColorScheme(.dark),
        size: size
    )
    try await settle(1.2)
    check(list, "resuming far into a PDF shows the highlight", highlightBand(in: try resumedHost.image()) != nil)
    try resumedHost.capture(to: output.appending(path: "interact-pdf-resume.png"))
    resumedHost.close()
    pdfReader.close()

    // MARK: Links

    print("--- Links in a PDF")
    let linkedPDF = audio.deletingLastPathComponent().appending(path: "linked.pdf")
    let linkedLecture = try await DocumentImporter(library: library).importDocument(at: linkedPDF, onProgress: { _ in })
    let linkedReader = ReaderModel(
        lecture: linkedLecture,
        audioURL: try require(library.audioURL(for: linkedLecture)),
        library: library,
        documentURL: library.documentURL(for: linkedLecture),
        isMuted: true
    )
    try await linkedReader.start()
    let linkedHost = OffscreenHost(ReaderView(model: linkedReader, onClose: {}).preferredColorScheme(.dark), size: size)
    try await settle()
    let linkedDriver = EventDriver(window: linkedHost.nsWindow)
    try await linkedDriver.prime()
    let linkedView = try require(linkedHost.findPDFView())
    let linkedDocument = try require(linkedView.document)
    let citationWord = try require(linkedLecture.transcript.words.firstIndex { $0.text == "[12]" })
    let citationPage = try require(linkedDocument.page(at: 0))
    let citationBounds = try require(citationPage.selection(for: try require(linkedLecture.document).locations[citationWord].ranges[0].nsRange)).bounds(for: citationPage)
    let citationPoint = linkedView.convert(linkedView.convert(CGPoint(x: citationBounds.midX, y: citationBounds.midY), from: citationPage), to: nil)
    // Watches the link itself: following a link and then scrolling back ends on the right
    // page, so where the view ends up can't show whether the link was followed.
    var linkHits = 0
    var pageChanges = 0
    let hitObserver = NotificationCenter.default.addObserver(forName: .PDFViewAnnotationHit, object: linkedView, queue: .main) { _ in
        MainActor.assumeIsolated { linkHits += 1 }
    }
    let pageObserver = NotificationCenter.default.addObserver(forName: .PDFViewPageChanged, object: linkedView, queue: .main) { _ in
        MainActor.assumeIsolated { pageChanges += 1 }
    }
    try await linkedDriver.click(at: citationPoint)
    try await settle(0.5)
    NotificationCenter.default.removeObserver(hitObserver)
    NotificationCenter.default.removeObserver(pageObserver)
    check(list, "clicking a linked word jumps to that word", linkedReader.activeWord == citationWord, "active word \(String(describing: linkedReader.activeWord)), wanted \(citationWord)")
    check(list, "clicking a linked word doesn't trigger the link", linkHits == 0, "\(linkHits) link hits")
    check(list, "clicking a linked word doesn't move the page", pageChanges == 0 && linkedView.currentPage == citationPage, "\(pageChanges) page changes")
    linkedHost.close()
    linkedReader.close()

    try await checkVoiceArea(output: output, fixtures: audio.deletingLastPathComponent(), list: list)

    print("\(list.total - list.failures) of \(list.total) checks passed")
    if list.failures > 0 { exit(2) }
}

/// A stand-in that reports some progress and then holds the job open, to show the screen.
private struct HoldingEngine: SpeechEngine {
    let onStart: @Sendable (@escaping @Sendable (Double) -> Void) -> Void

    func render(words: [String], to url: URL, onProgress: @escaping @Sendable (Double) -> Void) async throws -> RenderedSpeech {
        onStart(onProgress)
        try await Task.sleep(for: .seconds(600))
        throw CancellationError()
    }
}

private final class ToolClock: Sendable {
    private let seconds = Mutex(0.0)
    var now: Date { Date(timeIntervalSince1970: seconds.withLock { $0 }) }
    func advance(by amount: Double) { seconds.withLock { $0 += amount } }
}

/// The inline questions and progress on the home screen, with real clicks on their buttons.
/// The menus themselves can't be opened off screen, so a person needs to try those.
@MainActor
private func checkVoiceArea(output: URL, fixtures: URL, list: Checklist) async throws {
    print("--- Voice on the home screen")
    let manager = FileManager.default
    let scratch = manager.temporaryDirectory.appending(path: "ReaderVoice-\(UUID().uuidString)", directoryHint: .isDirectory)
    try manager.createDirectory(at: scratch, withIntermediateDirectories: true)
    defer { try? manager.removeItem(at: scratch) }

    let uv = scratch.appending(path: "uv")
    func writeUV(exitStatus: Int, slow: Bool = false) throws {
        try? manager.removeItem(at: uv)
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
        try body.write(to: uv, atomically: true, encoding: .utf8)
        try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: uv.path)
    }
    try writeUV(exitStatus: 0, slow: true)

    let clock = ToolClock()
    let progress = Mutex<(@Sendable (Double) -> Void)?>(nil)
    // One name, emptied each time, as each name leaves a file in Preferences for good.
    let suite = "PodcastReaderVoiceTool"
    let defaults = try require(UserDefaults(suiteName: suite))
    defaults.removePersistentDomain(forName: suite)
    let model = AppModel(
        library: Library(directory: scratch.appending(path: "lectures", directoryHint: .isDirectory)),
        isMuted: true,
        kokoro: KokoroEnvironment(root: scratch.appending(path: "kokoro", directoryHint: .isDirectory), uv: .existing(uv)),
        defaults: defaults,
        engineFactory: { _, _ in
            HoldingEngine { report in progress.withLock { $0 = report } }
        },
        now: { clock.now }
    )
    let size = CGSize(width: 1180, height: 760)
    let host = OffscreenHost(RootView(model: model).preferredColorScheme(.dark), size: size)
    try await settle()
    let driver = EventDriver(window: host.nsWindow)
    try await driver.prime()

    // Where the buttons sit, measured from the top left of this window size.
    let firstInPrompt = (x: CGFloat(205), y: CGFloat(365))
    let secondInPrompt = (x: CGFloat(290), y: CGFloat(365))
    let cancelSetup = (x: CGFloat(870), y: CGFloat(337))
    let cancelPreparing = (x: CGFloat(590), y: CGFloat(264))
    func clickButton(_ place: (x: CGFloat, y: CGFloat)) async throws {
        try await driver.click(at: fromTop(place.x, place.y, height: size.height))
        try await settle(0.3)
    }
    func picture(_ name: String) throws {
        try host.capture(to: output.appending(path: "home-\(name).png"))
    }

    try picture("voice-before-setup")
    check(list, "before setup the voice is Apple's", model.readingVoice == .apple)

    model.chooseVoice(.kokoro(.heart))
    try await settle(0.4)
    try picture("setup-question")
    try await clickButton(secondInPrompt)
    check(list, "Not now leaves everything as it was", model.kokoroSetup == .idle && model.readingVoice == .apple)

    model.chooseVoice(.kokoro(.heart))
    try await settle(0.4)
    try await clickButton(firstInPrompt)
    check(list, "Set up starts setting up", { if case .installing = model.kokoroSetup { true } else { false } }())
    try picture("setup-progress")
    try await clickButton(cancelSetup)
    try await settle(1)
    check(list, "Cancel stops setting up", model.kokoroSetup == .idle && !model.isKokoroInstalled, "\(model.kokoroSetup)")

    try writeUV(exitStatus: 1)
    model.chooseVoice(.kokoro(.heart))
    try await settle(0.4)
    try await clickButton(firstInPrompt)
    try await settle(1)
    check(list, "a failed setup says so", { if case .failed = model.kokoroSetup { true } else { false } }(), "\(model.kokoroSetup)")
    check(list, "a failed setup keeps the voice", model.readingVoice == .apple)
    try picture("setup-failed")

    try writeUV(exitStatus: 0)
    try await clickButton(firstInPrompt)
    try await settle(1)
    check(list, "Try again finishes setup", model.isKokoroInstalled && model.kokoroSetup == .idle, "\(model.kokoroSetup)")
    check(list, "the chosen voice is now in use", model.readingVoice == .kokoro(.heart))
    try picture("voice-heart")

    model.importFile(fixtures.appending(path: "document.pdf"))
    try await waitForValue { progress.withLock { $0 != nil } }
    let report = try require(progress.withLock { $0 })
    clock.advance(by: 20)
    report(0.1)
    try await settle(0.2)
    clock.advance(by: 600)
    report(0.3)
    try await settle(0.5)
    check(list, "preparing shows the time left", model.importRemainingText == "About 35 minutes left", model.importRemainingText ?? "nothing")
    try picture("preparing")
    try await clickButton(cancelPreparing)
    try await waitForValue { !model.isImporting }
    check(list, "Cancel stops preparing", !model.isImporting)

    model.askToRemoveKokoro()
    try await settle(0.4)
    try picture("remove-question")
    try await clickButton(secondInPrompt)
    check(list, "Cancel keeps Kokoro", model.isKokoroInstalled)
    model.askToRemoveKokoro()
    try await settle(0.4)
    try await clickButton(firstInPrompt)
    check(list, "Remove takes Kokoro away", !model.isKokoroInstalled && model.readingVoice == .apple)
    host.close()
}

@MainActor
private func waitForValue(_ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(20)
    while !condition(), Date() < deadline {
        try await Task.sleep(for: .milliseconds(20))
    }
}

@MainActor
private func check(_ list: Checklist, _ name: String, _ passed: Bool, _ detail: @autoclosure () -> String = "") {
    list.check(name, passed, detail())
}
#endif
