// Development tool for checking the app without taking over the screen.
//
//   swift run ReaderSnapshots screens <output-folder> <audio-file>
//       Renders the app's screens to PNG files, offscreen.
//
//   swift run ReaderSnapshots stress <output-folder> <long-audio-file>
//       Runs real transcription on a long file and reports how long each kind of
//       work takes at that size.
//
//   swift run ReaderSnapshots landing <output-folder> <long-audio-file>
//       Checks that caption jumps land on the active line. Exits with 2 on a miss.
//
//   swift run ReaderSnapshots interact <output-folder> <audio-file>
//       Sends real mouse, keyboard and scroll events to the app's views offscreen, and
//       checks what happens. Exits with 2 on a failure.
//
//   swift run ReaderSnapshots library-check <output-folder> unused
//       Confirms saved lectures still load, without changing them.
//
//   swift run ReaderSnapshots pdf-stress <output-folder> <pdf-file>
//       Imports a long PDF, reports timings, and checks jumps keep the highlight in
//       view. Generates a 300-page PDF at that path if there's no file there.
import AppKit
import CoreText
import PDFKit
import PodcastReaderCore
import PodcastReaderUI
import SwiftUI

let sampleText = """
Today we are going to talk about how memory works, and why most of the ways people study are \
surprisingly inefficient. When you reread a chapter, the material starts to feel familiar, and that \
feeling of familiarity is easy to mistake for actual understanding. Researchers call this the illusion \
of competence. The brain does not keep a memory in one tidy place. Each time you recall something, you \
rebuild it from scattered pieces, and that act of rebuilding is what makes the pathway stronger. This \
is called the testing effect, and it has been replicated in hundreds of experiments. A related idea is \
spacing. If you study the same material over several days instead of cramming it into one evening, you \
will remember far more a month later.
"""

struct MissingValue: Error {}

/// A window that behaves like the active one, without this tool taking focus from whatever
/// the person is doing. Views only accept some clicks in the active window.
final class KeyCapableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }
}

/// A SwiftUI view living in a borderless window far off every screen.
@MainActor
final class OffscreenHost<Content: View> {
    private let window: NSWindow
    private let host: NSHostingView<AnyView>

    var nsWindow: NSWindow { window }

    /// The PDF view inside this host, if there is one.
    func findPDFView() -> PDFView? {
        func search(_ view: NSView) -> PDFView? {
            if let found = view as? PDFView { return found }
            for subview in view.subviews {
                if let found = search(subview) { return found }
            }
            return nil
        }
        return search(host)
    }

    init(_ content: Content, size: CGSize) {
        window = KeyCapableWindow(
            contentRect: CGRect(x: -20_000, y: -20_000, width: size.width, height: size.height),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        host = NSHostingView(rootView: AnyView(content.frame(width: size.width, height: size.height)))
        window.contentView = host
        window.orderFrontRegardless()
        window.makeKey()
    }

    func updateLayout() {
        host.layoutSubtreeIfNeeded()
    }

    func image() throws -> NSBitmapImageRep {
        host.layoutSubtreeIfNeeded()
        if let composited = compositedImage() {
            return composited
        }
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw MissingValue() }
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    /// Asks the window server for this window's real contents, which includes layers that
    /// `cacheDisplay` can't see, such as PDFKit's page tiles. A process may always capture
    /// its own windows. The function is looked up by name because the SDK hides it.
    private func compositedImage() -> NSBitmapImageRep? {
        typealias CaptureFunction = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else {
            print("Window capture isn't available")
            return nil
        }
        let capture = unsafeBitCast(symbol, to: CaptureFunction.self)
        let includingWindow: UInt32 = 1 << 3
        let boundsIgnoreFraming: UInt32 = 1 << 0
        guard let image = capture(.null, includingWindow, UInt32(window.windowNumber), boundsIgnoreFraming)?.takeRetainedValue() else {
            print("Window capture returned nothing")
            return nil
        }
        return NSBitmapImageRep(cgImage: image)
    }

    func capture(to url: URL) throws {
        try image().representation(using: .png, properties: [:])?.write(to: url)
        print("Wrote \(url.lastPathComponent)")
    }

    func close() {
        window.close()
    }
}

/// Lets SwiftUI and background work settle. This must be a real wait rather than a
/// nested run loop, which would stop other main-actor work from running.
func settle(_ seconds: Double = 1.2) async throws {
    try await Task.sleep(for: .seconds(seconds))
}

@MainActor
func renderOnce<Content: View>(_ content: Content, size: CGSize, to url: URL) async throws {
    let host = OffscreenHost(content, size: size)
    try await settle()
    try host.capture(to: url)
    host.close()
}

@MainActor
func screens(output: URL, audio: URL) async throws {
    let scratch = FileManager.default.temporaryDirectory
        .appending(path: "ReaderSnapshots-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: scratch) }
    let library = Library(directory: scratch)
    let standard = CGSize(width: 1180, height: 760)

    let words = sampleText.split(separator: " ").enumerated().map { index, text in
        Word(text: String(text), start: Double(index) * 0.06, end: Double(index + 1) * 0.06)
    }
    var lecture = try library.makeLecture(audioAt: audio, transcript: Transcript(words: words), duration: 8)
    lecture.title = "How memory works: lecture 4"
    let reader = ReaderModel(lecture: lecture, audioURL: audio, library: library, isMuted: true)
    try await reader.start()
    reader.player.seek(to: 3.2)
    let view = ReaderView(model: reader, onClose: {}).preferredColorScheme(.dark)

    try await renderOnce(view, size: standard, to: output.appending(path: "reader-window.png"))
    try await renderOnce(view, size: CGSize(width: 1920, height: 1080), to: output.appending(path: "reader-fullscreen.png"))
    try await renderOnce(view, size: CGSize(width: 800, height: 560), to: output.appending(path: "reader-smallest.png"))

    reader.player.seek(to: 1)
    reader.addBookmark()
    reader.player.seek(to: 5)
    reader.addBookmark()
    reader.player.seek(to: 3.2)
    try await settle(1.6)
    reader.openPanel(.bookmarks)
    try await renderOnce(view, size: standard, to: output.appending(path: "reader-bookmarks.png"))

    reader.openPanel(.search)
    reader.query = "memory"
    try await renderOnce(view, size: standard, to: output.appending(path: "reader-search.png"))
    try await renderOnce(view, size: CGSize(width: 800, height: 560), to: output.appending(path: "reader-search-smallest.png"))
    reader.close()

    // A PDF being read aloud, imported for real. It lives beside the audio fixture.
    let pdf = audio.deletingLastPathComponent().appending(path: "document.pdf")
    let imported = try await DocumentImporter(library: library).importDocument(at: pdf, onProgress: { _ in })
    let pdfReader = ReaderModel(
        lecture: imported,
        audioURL: try require(library.audioURL(for: imported)),
        library: library,
        documentURL: library.documentURL(for: imported),
        isMuted: true
    )
    try await pdfReader.start()
    pdfReader.jump(toWord: 12)
    let pdfView = ReaderView(model: pdfReader, onClose: {}).preferredColorScheme(.dark)
    try await renderOnce(pdfView, size: standard, to: output.appending(path: "reader-pdf.png"))
    try await renderOnce(pdfView, size: CGSize(width: 1920, height: 1080), to: output.appending(path: "reader-pdf-fullscreen.png"))
    pdfReader.jump(toWord: imported.transcript.words.count - 3)
    pdfReader.openPanel(.search)
    pdfReader.query = "memory"
    try await renderOnce(pdfView, size: CGSize(width: 800, height: 560), to: output.appending(path: "reader-pdf-smallest.png"))
    pdfReader.close()

    let home = AppModel(library: library)
    try await renderOnce(RootView(model: home).preferredColorScheme(.dark), size: standard, to: output.appending(path: "home.png"))
}

func require<T>(_ value: T?) throws -> T {
    guard let value else { throw MissingValue() }
    return value
}

/// The vertical range of pure white pixels, as fractions of the image height, leaving
/// out the white controls at the top and bottom. Only spoken words are white in between.
func whiteTextBand(in rep: NSBitmapImageRep) -> ClosedRange<Double>? {
    let height = rep.pixelsHigh
    let firstRow = height / 12
    let lastRow = height * 3 / 4
    var top: Int?
    var bottom: Int?
    for y in stride(from: firstRow, to: lastRow, by: 4) {
        for x in stride(from: 0, to: rep.pixelsWide, by: 6) {
            guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
            if color.redComponent > 0.97, color.greenComponent > 0.97, color.blueComponent > 0.97 {
                top = top ?? y
                bottom = y
                break
            }
        }
    }
    guard let top, let bottom else { return nil }
    return Double(top) / Double(height)...Double(bottom) / Double(height)
}

/// Checks that after each jump the active line really is where the design says: about
/// 38% of the way down the window.
@MainActor
func landing(output: URL, audio: URL) async throws {
    let scratch = FileManager.default.temporaryDirectory
        .appending(path: "ReaderLanding-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: scratch) }
    let library = Library(directory: scratch)

    let sampleWords = sampleText.split(separator: " ").map(String.init)
    let words = (0..<33_000).map { index in
        Word(text: sampleWords[index % sampleWords.count], start: Double(index) * 0.32, end: Double(index + 1) * 0.32)
    }
    let lecture = try library.makeLecture(audioAt: audio, transcript: Transcript(words: words), duration: 10_560)
    let reader = ReaderModel(lecture: lecture, audioURL: audio, library: library, isMuted: true)
    try await reader.start()
    let host = OffscreenHost(
        ReaderView(model: reader, onClose: {}).preferredColorScheme(.dark),
        size: CGSize(width: 1180, height: 760)
    )
    try await settle()

    let targets: [(String, TimeInterval)] = [
        ("far forward", 7_900), ("far back", 400), ("far forward", 9_800), ("middle", 5_000),
        ("just ahead", 5_020), ("just behind", 4_990), ("start", 0.5), ("near the end", 10_500),
    ]
    var misses = 0
    for (index, (label, time)) in targets.enumerated() {
        reader.jump(toWord: Int(time / 0.32))
        try await settle(1.5)
        let band = whiteTextBand(in: try host.image())
        let landed = band.map { $0.lowerBound - 0.1 <= 0.38 && 0.38 <= $0.upperBound + 0.12 } ?? false
        if !landed {
            misses += 1
            try host.capture(to: output.appending(path: "landing-miss-\(index).png"))
        }
        let where_ = band.map { String(format: "white text at %.0f%% to %.0f%%", $0.lowerBound * 100, $0.upperBound * 100) } ?? "no white text visible"
        print("\(landed ? "OK  " : "MISS") \(label) to \(TimeFormat.string(time)): \(where_)")
    }

    // Dragging the progress bar sends a rapid burst of seeks, then stops.
    let bursts = 25
    var generator = SystemRandomNumberGenerator()
    for burst in 0..<bursts {
        for _ in 0..<30 {
            reader.player.seek(to: Double.random(in: 0..<10_500, using: &generator))
            try await Task.sleep(for: .milliseconds(20))
        }
        try await settle(1.5)
        let band = whiteTextBand(in: try host.image())
        let landed = band.map { $0.lowerBound - 0.1 <= 0.38 && 0.38 <= $0.upperBound + 0.12 } ?? false
        if !landed {
            misses += 1
            try host.capture(to: output.appending(path: "landing-miss-burst-\(burst).png"))
        }
        let where_ = band.map { String(format: "white text at %.0f%% to %.0f%%", $0.lowerBound * 100, $0.upperBound * 100) } ?? "no white text visible"
        print("\(landed ? "OK  " : "MISS") burst \(burst + 1) ending at \(TimeFormat.string(reader.player.currentTime)): \(where_)")
    }
    print("Landing check: \(targets.count + bursts - misses) of \(targets.count + bursts) landed on the active line")
    host.close()
    reader.close()
    if misses > 0 { exit(2) }
}

/// The vertical range of highlight-colored pixels on the page, as fractions of the image height.
func highlightBand(in rep: NSBitmapImageRep) -> ClosedRange<Double>? {
    let height = rep.pixelsHigh
    var top: Int?
    var bottom: Int?
    for y in stride(from: 0, to: height, by: 3) {
        for x in stride(from: 0, to: rep.pixelsWide, by: 4) {
            guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
            if abs(color.redComponent - 0.44) < 0.1, abs(color.greenComponent - 0.96) < 0.06, abs(color.blueComponent - 0.81) < 0.1 {
                top = top ?? y
                bottom = y
                break
            }
        }
    }
    guard let top, let bottom else { return nil }
    return Double(top) / Double(height)...Double(bottom) / Double(height)
}

/// A long PDF laid out like a real one, with a running header and page numbers.
func makeLongPDF(at url: URL, pages: Int) {
    var box = CGRect(x: 0, y: 0, width: 612, height: 792)
    guard let context = CGContext(url as CFURL, mediaBox: &box, nil) else { return }
    let font = CTFontCreateWithName("Times New Roman" as CFString, 11, nil)
    func attributed(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [.font: font])
    }
    for page in 0..<pages {
        context.beginPDFPage(nil)
        context.textPosition = CGPoint(x: 54, y: 760)
        CTLineDraw(CTLineCreateWithAttributedString(attributed("Chapter 4: How memory works")), context)
        context.textPosition = CGPoint(x: 300, y: 30)
        CTLineDraw(CTLineCreateWithAttributedString(attributed("\(page + 1)")), context)
        // Lists and symbols make the speech engine report several words at one offset, which
        // is what would throw timing off, so every page has some.
        let hardBits = " Key results: • first • second • third — and 1 2 3 4 5 . . . where x = y + 2 ; ; ; then more. "
        let body = String(repeating: sampleText + hardBits, count: 3)
        let setter = CTFramesetterCreateWithAttributedString(attributed(body))
        let frame = CTFramesetterCreateFrame(
            setter,
            CFRange(location: 0, length: 0),
            CGPath(rect: CGRect(x: 54, y: 90, width: 504, height: 620), transform: nil),
            nil
        )
        CTFrameDraw(frame, context)
        context.endPDFPage()
    }
    context.closePDF()
}

/// Imports a long PDF for real, reports how long each kind of work takes, then checks
/// from rendered images that jumps land with the highlight in view.
/// Uses the real Kokoro voice when KOKORO_TEST_ROOT points at an install.
func documentImporter(library: Library, pdf: URL) throws -> DocumentImporter {
    guard let root = ProcessInfo.processInfo.environment["KOKORO_TEST_ROOT"] else {
        return DocumentImporter(library: library)
    }
    let engine = KokoroSpeechEngine(
        environment: KokoroEnvironment(root: URL(fileURLWithPath: root, isDirectory: true)),
        voice: .heart,
        workFolder: library.kokoroWorkFolder(forID: try library.lectureID(forAudioAt: pdf), voice: .heart)
    )
    return DocumentImporter(library: library, engine: engine)
}

@MainActor
func pdfStress(output: URL, pdf: URL) async throws {
    if !FileManager.default.fileExists(atPath: pdf.path) {
        makeLongPDF(at: pdf, pages: 300)
    }
    let scratch = FileManager.default.temporaryDirectory
        .appending(path: "ReaderPDFStress-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: scratch) }
    let library = Library(directory: scratch)

    var mark = Date()
    let lecture = try await documentImporter(library: library, pdf: pdf).importDocument(at: pdf, onProgress: { _ in })
    let document = try require(lecture.document)
    print(String(
        format: "Imported %d pages in %.0f s: %d words, %.1f hours of speech, voice %@",
        document.pageCount, Date().timeIntervalSince(mark), lecture.transcript.words.count, lecture.duration / 3600, document.voiceName
    ))
    // Every page has the same text, so any timing drift shows up as pages of different lengths.
    // The first and last pages are left out, as they can hold less.
    let pageStarts = Dictionary(grouping: Array(document.locations.enumerated()), by: { $0.element.page })
        .mapValues { entries in lecture.transcript.words[entries.map(\.offset).min() ?? 0].start }
    let pageLengths = (1..<(document.pageCount - 2)).compactMap { page -> TimeInterval? in
        guard let start = pageStarts[page], let next = pageStarts[page + 1] else { return nil }
        return next - start
    }
    if let shortest = pageLengths.min(), let longest = pageLengths.max() {
        print(String(format: "Seconds per page: shortest %.2f, longest %.2f, over %d pages", shortest, longest, pageLengths.count))
    }

    func megabytes(_ url: URL) -> Int {
        ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) / 1_000_000
    }
    let audioFile = library.generatedAudioURL(forID: lecture.id)
    print("Audio file: \(megabytes(audioFile)) MB, saved lecture: \(megabytes(scratch.appending(path: "\(lecture.id).json"))) MB")

    mark = Date()
    _ = try library.load(id: lecture.id)
    print("Load lecture: \(milliseconds(since: mark))")
    mark = Date()
    let found = SearchIndex(transcript: lecture.transcript).search("memory")
    print("Index and search: \(milliseconds(since: mark)), \(found.count) matches")
    mark = Date()
    let wordIndex = DocumentWordIndex(locations: document.locations)
    _ = wordIndex.wordIndex(page: 150, character: 100)
    print("Build click index: \(milliseconds(since: mark))")

    let reader = ReaderModel(lecture: lecture, audioURL: audioFile, library: library, documentURL: pdf, isMuted: true)
    try await reader.start()
    let host = OffscreenHost(
        ReaderView(model: reader, onClose: {}).preferredColorScheme(.dark),
        size: CGSize(width: 1180, height: 760)
    )
    try await settle()

    var longest = 0.0
    var total = 0.0
    let middleWord = lecture.transcript.words.count / 2
    let wordTimes = lecture.transcript.words[middleWord..<min(middleWord + 200, lecture.transcript.words.count)].map(\.start)
    for time in wordTimes {
        let start = Date()
        reader.player.seek(to: time)
        host.updateLayout()
        let elapsed = Date().timeIntervalSince(start) * 1000
        longest = max(longest, elapsed)
        total += elapsed
        try await Task.sleep(for: .milliseconds(20))
    }
    print(String(format: "Word by word highlight: average %.1f ms, longest %.1f ms", total / Double(wordTimes.count), longest))

    var misses = 0
    func check(_ label: String, index: Int) async throws {
        try await settle(1)
        let band = highlightBand(in: try host.image())
        // The page area runs from below the back button to above the control bar.
        let landed = band.map { $0.lowerBound > 0.04 && $0.upperBound < 0.82 } ?? false
        if !landed {
            misses += 1
            try host.capture(to: output.appending(path: "pdf-landing-miss-\(index).png"))
        }
        let place = band.map { String(format: "highlight at %.0f%% to %.0f%%", $0.lowerBound * 100, $0.upperBound * 100) } ?? "no highlight visible"
        print("\(landed ? "OK  " : "MISS") \(label): \(place)")
    }

    let count = lecture.transcript.words.count
    let targets = [count * 3 / 4, 50, count - 5, count / 2, count / 2 + 30, count / 2 - 30, 0, count * 9 / 10]
    for (index, word) in targets.enumerated() {
        reader.jump(toWord: word)
        try await check("jump to page \(document.locations[word].page + 1)", index: index)
    }
    try host.capture(to: output.appending(path: "pdf-far-jump.png"))

    let bursts = 15
    var generator = SystemRandomNumberGenerator()
    for burst in 0..<bursts {
        for _ in 0..<30 {
            reader.player.seek(to: Double.random(in: 0..<lecture.duration, using: &generator))
            try await Task.sleep(for: .milliseconds(20))
        }
        try await check("burst \(burst + 1)", index: 100 + burst)
    }
    print("Landing check: \(targets.count + bursts - misses) of \(targets.count + bursts) kept the highlight in view")
    host.close()

    // Resuming: a brand new view on a reader that's already far into the document.
    reader.jump(toWord: count * 3 / 4)
    let resumed = OffscreenHost(
        ReaderView(model: reader, onClose: {}).preferredColorScheme(.dark),
        size: CGSize(width: 1180, height: 760)
    )
    try await settle(1.5)
    let resumedBand = highlightBand(in: try resumed.image())
    print("\(resumedBand == nil ? "MISS" : "OK  ") resuming far into the document shows the highlight")
    if resumedBand == nil {
        misses += 1
    }
    try resumed.capture(to: output.appending(path: "pdf-resume.png"))
    resumed.close()
    reader.close()
    if misses > 0 { exit(2) }
}

/// Confirms the real library still loads, and renders its first lecture. This only ever
/// reads the real library: it opens a copy of the lecture in a temporary library, so
/// playing, saving and closing can't change anything real.
@MainActor
func libraryCheck(output: URL) async throws {
    let real = Library(directory: Library.defaultDirectory)
    let lectures = real.all()
    print("Lectures that load from the real library: \(lectures.count)")
    for lecture in lectures {
        print("  \(lecture.document == nil ? "audio" : "PDF"): \(lecture.transcript.words.count) words, \(lecture.transcript.lines.count) lines, \(TimeFormat.string(lecture.duration)), position \(TimeFormat.string(lecture.position)), audio found: \(real.audioURL(for: lecture) != nil)")
    }
    guard let first = lectures.first, let audio = real.audioURL(for: first) else { return }

    let scratch = FileManager.default.temporaryDirectory
        .appending(path: "ReaderLibraryCheck-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: scratch) }
    let copyLibrary = Library(directory: scratch)
    try copyLibrary.save(first)
    let reader = ReaderModel(lecture: first, audioURL: audio, library: copyLibrary, isMuted: true)
    try await reader.start()
    reader.player.seek(to: first.duration * 0.3)
    let host = OffscreenHost(ReaderView(model: reader, onClose: {}).preferredColorScheme(.dark), size: CGSize(width: 1180, height: 760))
    try await settle(1.5)
    try host.capture(to: output.appending(path: "real-lecture.png"))
    host.close()
    reader.close()
}

func milliseconds(since start: Date) -> String {
    String(format: "%.1f ms", Date().timeIntervalSince(start) * 1000)
}

@MainActor
func stress(output: URL, audio: URL) async throws {
    let scratch = FileManager.default.temporaryDirectory
        .appending(path: "ReaderStress-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: scratch) }
    let library = Library(directory: scratch)

    var mark = Date()
    let transcript = try await Transcriber().transcribe(audioAt: audio, onProgress: { _ in })
    let seconds = Date().timeIntervalSince(mark)
    let lastEnd = transcript.words.last?.end ?? 0
    print(String(
        format: "Transcribed %.0f min of audio in %.0f s (%.0fx): %d words, %d lines",
        lastEnd / 60, seconds, lastEnd / seconds, transcript.words.count, transcript.lines.count
    ))

    mark = Date()
    let index = SearchIndex(transcript: transcript)
    print("Build search index: \(milliseconds(since: mark))")
    mark = Date()
    let found = index.search("memory")
    print("Search for one word: \(milliseconds(since: mark)), \(found.count) matches")

    let lecture = try library.makeLecture(audioAt: audio, transcript: transcript, duration: lastEnd)
    mark = Date()
    try library.save(lecture)
    print("Save lecture: \(milliseconds(since: mark))")
    let size = try FileManager.default
        .attributesOfItem(atPath: scratch.appending(path: "\(lecture.id).json").path)[.size] as? Int ?? 0
    print("Saved file size: \(size / 1_000_000) MB")
    mark = Date()
    _ = try library.load(id: lecture.id)
    print("Load lecture: \(milliseconds(since: mark))")

    let reader = ReaderModel(lecture: lecture, audioURL: audio, library: library, isMuted: true)
    try await reader.start()
    let host = OffscreenHost(
        ReaderView(model: reader, onClose: {}).preferredColorScheme(.dark),
        size: CGSize(width: 1920, height: 1080)
    )
    try await settle()

    func measure(_ label: String, times: [TimeInterval]) async throws {
        var longest = 0.0
        var total = 0.0
        for time in times {
            let start = Date()
            reader.player.seek(to: time)
            host.updateLayout()
            let elapsed = Date().timeIntervalSince(start) * 1000
            longest = max(longest, elapsed)
            total += elapsed
            try await Task.sleep(for: .milliseconds(20))
        }
        print(String(format: "%@: average %.1f ms, longest %.1f ms, over %d updates", label, total / Double(times.count), longest, times.count))
    }

    let wordTimes = transcript.words[5_000..<5_200].map(\.start)
    try await measure("Word by word highlight", times: wordTimes)

    var generator = SystemRandomNumberGenerator()
    let farTimes = (0..<40).map { _ in Double.random(in: 0..<lastEnd, using: &generator) }
    try await measure("Far jumps", times: farTimes)

    let target = transcript.words[transcript.words.count * 3 / 4]
    reader.player.seek(to: target.start)
    try await settle(1.5)
    print("Jumped to \(TimeFormat.string(target.start)), active line text: \(transcript.text(ofLine: transcript.lineIndex(forWord: reader.activeWord ?? 0)))")
    try host.capture(to: output.appending(path: "stress-far-jump.png"))

    host.close()
    reader.close()
}

let arguments = CommandLine.arguments
guard arguments.count == 4, ["screens", "stress", "landing", "pdf-stress", "interact", "library-check"].contains(arguments[1]) else {
    print("Usage: ReaderSnapshots screens|stress|landing|pdf-stress|interact|library-check <output-folder> <audio-or-pdf-file>")
    exit(1)
}
let output = URL(fileURLWithPath: arguments[2], isDirectory: true)
let audio = URL(fileURLWithPath: arguments[3])

/// Reports itself as active, so views handle clicks as they do in an active app, without
/// really taking keyboard focus from whatever the person is doing.
final class ToolApplication: NSApplication {
    override var isActive: Bool { true }
}

let application = ToolApplication.shared
application.setActivationPolicy(.accessory)

Task { @MainActor in
    do {
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        switch arguments[1] {
        case "screens": try await screens(output: output, audio: audio)
        case "stress": try await stress(output: output, audio: audio)
        case "pdf-stress": try await pdfStress(output: output, pdf: audio)
        #if DEBUG
        case "interact": try await interact(output: output, audio: audio)
        #endif
        case "library-check": try await libraryCheck(output: output)
        default: try await landing(output: output, audio: audio)
        }
        exit(0)
    } catch {
        print("Failed: \(error)")
        exit(1)
    }
}
application.run()
