import PodcastReaderCore
import SwiftUI

/// Shown when a lecture's audio file has moved. The transcript and bookmarks are safe.
struct MissingAudioView: View {
    let model: AppModel
    let lecture: Lecture
    let message: String?

    @State private var isChoosingFile = false

    var body: some View {
        ZStack {
            AuroraBackground()

            VStack(spacing: 16) {
                Text(lecture.title)
                    .font(.system(size: 30, weight: .heavy))
                    .tracking(-1)
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                Text(lecture.document == nil ? "This lecture's audio file has moved." : "This PDF has moved.")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Palette.upcoming)
                if let message {
                    Text(message)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                }
                HStack {
                    Button("Locate file") { isChoosingFile = true }
                        .controlSize(.large)
                    Button("Back") { model.closeReader() }
                        .controlSize(.large)
                }
            }
            .padding(40)
            .frame(maxWidth: 560)
        }
        .fileImporter(isPresented: $isChoosingFile, allowedContentTypes: lecture.document == nil ? [.mp3, .mpeg4Audio, .wav] : [.pdf]) { result in
            if case .success(let url) = result {
                model.locateAudio(for: lecture, at: url)
            }
        }
    }
}
