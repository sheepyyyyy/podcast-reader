import PodcastReaderCore
import SwiftUI

public struct RootView: View {
    let model: AppModel

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        switch model.screen {
        case .home:
            HomeView(model: model)
        case .reader(let reader):
            ReaderView(model: reader) {
                model.closeReader()
            }
            .id(reader.lecture.id)
        case .missingAudio(let lecture, let message):
            MissingAudioView(model: model, lecture: lecture, message: message)
        }
    }
}
