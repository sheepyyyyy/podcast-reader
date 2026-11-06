// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "PodcastReader",
    platforms: [.macOS(.v26)],
    targets: [
        .target(name: "PodcastReaderCore"),
        .target(name: "PodcastReaderUI", dependencies: ["PodcastReaderCore"]),
        .executableTarget(name: "PodcastReader", dependencies: ["PodcastReaderUI"]),
        // Development tool: renders screens to PNG files for checking the design.
        .executableTarget(name: "ReaderSnapshots", dependencies: ["PodcastReaderCore", "PodcastReaderUI"]),
        .testTarget(
            name: "PodcastReaderCoreTests",
            dependencies: ["PodcastReaderCore"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(name: "PodcastReaderUITests", dependencies: ["PodcastReaderCore", "PodcastReaderUI"]),
    ]
)
