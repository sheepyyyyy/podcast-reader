import AppKit
import PodcastReaderCore
import SwiftUI
import Testing
@testable import PodcastReaderUI

@MainActor
struct ControlBarLayoutTests {
    func makeReader() throws -> ReaderModel {
        let library = Library(directory: try makeTemporaryDirectory())
        let words = [Word(text: "Hello", start: 0, end: 1)]
        let lecture = try library.makeLecture(audioAt: fixture("sample.mp3"), transcript: Transcript(words: words), duration: 8)
        return ReaderModel(lecture: lecture, audioURL: fixture("sample.mp3"), library: library, isMuted: true)
    }

    @Test func compactBarFitsBesideThePanelInTheSmallestWindow() throws {
        let smallestWindowWidth = 800.0
        let host = NSHostingView(rootView: ControlBar(model: try makeReader(), isCompact: true))
        #expect(host.fittingSize.width <= smallestWindowWidth - SidePanel.width)
    }

    @Test func regularBarFitsTheColumnWidthWhereCompactSizingEnds() throws {
        let host = NSHostingView(rootView: ControlBar(model: try makeReader(), isCompact: false))
        #expect(host.fittingSize.width <= ControlBar.compactBelowWidth)
    }
}
