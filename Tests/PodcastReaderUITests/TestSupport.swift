import Foundation
import PodcastReaderCore

/// The audio fixtures live with the Core tests.
func fixture(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appending(path: "PodcastReaderCoreTests/Fixtures/\(name)")
}

func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "PodcastReaderUITests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Waits for a condition instead of guessing how long the work takes.
@MainActor
func waitUntil(upTo seconds: Double = 20, _ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(seconds)
    while !condition(), Date() < deadline {
        try await Task.sleep(for: .milliseconds(20))
    }
}
