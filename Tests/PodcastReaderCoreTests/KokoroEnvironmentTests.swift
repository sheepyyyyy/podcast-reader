import CryptoKit
import Foundation
import Testing
@testable import PodcastReaderCore

/// Set by a person to run tests against a real Kokoro installation, which they create.
let kokoroTestRoot = ProcessInfo.processInfo.environment["KOKORO_TEST_ROOT"]

struct KokoroEnvironmentTests {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "KokoroEnvironmentTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    var kokoroFolder: URL { root.appending(path: "kokoro", directoryHint: .isDirectory) }
    var commandLog: URL { root.appending(path: "commands.log") }

    func script(_ name: String, _ body: String) throws -> URL {
        let url = root.appending(path: name)
        try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    /// A stand-in for uv that notes each command, and makes the Python that setup goes on to run.
    func fakeUV() throws -> URL {
        try script("fake-uv", """
        echo "$*" >> "\(commandLog.path)"
        if [ "$1" = "venv" ]; then
          for last; do :; done
          mkdir -p "$last/bin"
          printf '#!/bin/sh\\nexit 0\\n' > "$last/bin/python"
          chmod +x "$last/bin/python"
        fi
        """)
    }

    /// Packs a file the way uv's real download does, inside one folder.
    func package(_ file: URL, as name: String = "uv") throws -> (url: URL, sha256: String) {
        let manager = FileManager.default
        let work = root.appending(path: "package-\(UUID().uuidString)", directoryHint: .isDirectory)
        let folder = work.appending(path: "uv-aarch64-apple-darwin", directoryHint: .isDirectory)
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        try manager.copyItem(at: file, to: folder.appending(path: name))

        let tarball = root.appending(path: "uv-\(UUID().uuidString).tar.gz")
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-czf", tarball.path, "-C", work.path, "uv-aarch64-apple-darwin"]
        try tar.run()
        tar.waitUntilExit()
        #expect(tar.terminationStatus == 0)

        let hash = SHA256.hash(data: try Data(contentsOf: tarball))
        return (tarball, hash.map { String(format: "%02x", $0) }.joined())
    }

    @Test func theVoicesAreTheFourFromTheSamples() {
        #expect(KokoroVoice.all.map(\.id) == ["af_heart", "af_bella", "am_michael", "bf_emma"])
        #expect(KokoroVoice.heart.name == "Heart")
        #expect(KokoroVoice.heart.displayName == "Kokoro Heart")
    }

    @Test func notInstalledWithoutTheMarker() {
        #expect(!KokoroEnvironment(root: root).isInstalled)
    }

    @Test func anInterruptedSetupIsNotInstalled() throws {
        let environment = KokoroEnvironment(root: root)
        try FileManager.default.createDirectory(at: environment.pythonURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: environment.pythonURL)
        try Data().write(to: environment.helperURL)
        #expect(!environment.isInstalled)
    }

    @Test func modelsStayInsideTheFolder() {
        let values = KokoroEnvironment(root: root).processEnvironment(offline: true)
        #expect(values["HF_HOME"]?.hasPrefix(root.path) == true)
        #expect(values["HF_HUB_OFFLINE"] == "1")
        #expect(KokoroEnvironment(root: root).processEnvironment(offline: false)["HF_HUB_OFFLINE"] == nil)
    }

    @Test func pythonStaysInsideTheFolderWhateverIsOnThisMac() {
        let values = KokoroEnvironment(root: root).processEnvironment(offline: false)
        #expect(values["UV_PYTHON_INSTALL_DIR"]?.hasPrefix(root.path) == true)
        #expect(values["UV_PYTHON_PREFERENCE"] == "only-managed")
        #expect(values["UV_NO_CONFIG"] == "1")
    }

    @Test func thePronunciationDataPathIsShort() throws {
        let deep = root.appending(path: String(repeating: "long-folder-name/", count: 12), directoryHint: .isDirectory)
        let environment = KokoroEnvironment(root: deep)
        // Its real location, inside the Python environment, is about 70 characters longer.
        #expect(environment.espeakLinkURL.path.count < environment.espeakDataURL.path.count)
        #expect(environment.processEnvironment(offline: true)["ESPEAK_DATA_PATH"] == environment.espeakLinkURL.path)

        let normal = KokoroEnvironment(root: KokoroEnvironment.defaultRoot)
        #expect(normal.espeakLinkURL.path.count < 160)
    }

    // MARK: Getting uv

    @Test func setupGetsItsOwnUV() async throws {
        let download = try package(try fakeUV())
        let environment = KokoroEnvironment(root: kokoroFolder, uv: .download(download.url, sha256: download.sha256))
        try await environment.install(onProgress: { _ in })

        #expect(environment.isInstalled)
        let commands = try String(contentsOf: commandLog, encoding: .utf8)
        #expect(commands.hasPrefix("venv "))
        // It's only needed for setup.
        #expect(!FileManager.default.fileExists(atPath: kokoroFolder.appending(path: "tools").path))
    }

    @Test func aDownloadWithTheWrongFingerprintIsNeverRun() async throws {
        let download = try package(try fakeUV())
        let environment = KokoroEnvironment(
            root: kokoroFolder,
            uv: .download(download.url, sha256: String(repeating: "0", count: 64))
        )
        await #expect(throws: KokoroError.setupFailed) {
            try await environment.install(onProgress: { _ in })
        }
        #expect(!FileManager.default.fileExists(atPath: commandLog.path))
        #expect(!environment.isInstalled)
    }

    @Test func aDownloadThatCantBeReachedMeansSetupFailed() async {
        let environment = KokoroEnvironment(
            root: kokoroFolder,
            uv: .download(root.appending(path: "nothing-here.tar.gz"), sha256: "")
        )
        await #expect(throws: KokoroError.setupFailed) {
            try await environment.install(onProgress: { _ in })
        }
    }

    @Test func aDownloadWithoutUVInsideMeansSetupFailed() async throws {
        let download = try package(try fakeUV(), as: "something-else")
        let environment = KokoroEnvironment(root: kokoroFolder, uv: .download(download.url, sha256: download.sha256))
        await #expect(throws: KokoroError.setupFailed) {
            try await environment.install(onProgress: { _ in })
        }
        #expect(!FileManager.default.fileExists(atPath: commandLog.path))
    }

    @Test func aFailingCommandMeansSetupFailed() async throws {
        let uv = try script("uv", "exit 3")
        await #expect(throws: KokoroError.setupFailed) {
            try await KokoroEnvironment(root: root, uv: .existing(uv)).install(onProgress: { _ in })
        }
        #expect(!KokoroEnvironment(root: root, uv: .existing(uv)).isInstalled)
    }

    @Test func cancellingSetupStopsItsCommand() async throws {
        let uv = try script("uv", "sleep 30")
        let environment = KokoroEnvironment(root: root, uv: .existing(uv))
        let task = Task { try await environment.install(onProgress: { _ in }) }
        try await Task.sleep(for: .milliseconds(300))
        let start = Date()
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(Date().timeIntervalSince(start) < 5)
    }

    // MARK: Locked versions

    @Test func everyPackageIsInstalledAtItsLockedVersionAndNothingElse() async throws {
        let environment = KokoroEnvironment(root: kokoroFolder, uv: .existing(try fakeUV()))
        try await environment.install(onProgress: { _ in })

        let commands = try String(contentsOf: commandLog, encoding: .utf8)
        let install = try #require(commands.split(separator: "\n").first { $0.hasPrefix("pip install") })
        #expect(install.contains("--no-deps"))
        #expect(install.contains("--no-build"))
        #expect(!KokoroPackages.locked.isEmpty)
        for package in KokoroPackages.locked {
            #expect(install.contains(package))
            #expect(package.contains("==") || package.contains(" @ "), "\(package) has no fixed version")
        }
        #expect(KokoroPackages.locked.contains("kokoro==0.9.4"))
        #expect(KokoroPackages.locked.contains("misaki==0.9.4"))
    }

    @Test func theModelIsLockedToTheVersionThatWasTested() {
        #expect(KokoroHelper.source.contains(#"MODEL_VERSION = "\#(KokoroHelper.modelVersion)""#))
        #expect(KokoroHelper.source.contains("revision=MODEL_VERSION"))
        #expect(KokoroHelper.modelVersion.count == 40)
    }

    // MARK: Smaller Macs

    @Test(arguments: [
        // The M5 this was measured on.
        (gigabytes: UInt64(16), cores: 10, workers: 3, threads: 3),
        (gigabytes: UInt64(16), cores: 8, workers: 3, threads: 2),
        (gigabytes: UInt64(64), cores: 16, workers: 3, threads: 5),
        (gigabytes: UInt64(12), cores: 8, workers: 2, threads: 4),
        (gigabytes: UInt64(8), cores: 8, workers: 1, threads: 8),
        (gigabytes: UInt64(4), cores: 4, workers: 1, threads: 4),
    ])
    func smallerMacsRunFewerWorkers(mac: (gigabytes: UInt64, cores: Int, workers: Int, threads: Int)) {
        let workload = KokoroHelper.workload(memoryBytes: mac.gigabytes << 30, cores: mac.cores)
        #expect(workload.workers == mac.workers)
        #expect(workload.threads == mac.threads)
    }

    // MARK: Removing

    @Test func removingDeletesTheFolder() throws {
        let environment = KokoroEnvironment(root: root)
        try environment.remove()
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    // MARK: The real thing

    @Test(.enabled(if: kokoroTestRoot != nil)) func realSetupInstallsEverything() async throws {
        let environment = KokoroEnvironment(root: URL(fileURLWithPath: try #require(kokoroTestRoot)))
        if !environment.isInstalled {
            try await environment.install(onProgress: { _ in })
        }
        #expect(environment.isInstalled)
        let models = try FileManager.default.subpathsOfDirectory(atPath: environment.modelsURL.path)
        for voice in KokoroVoice.all {
            #expect(
                models.contains { $0.hasSuffix("snapshots/\(KokoroHelper.modelVersion)/voices/\(voice.id).pt") },
                "missing \(voice.id)"
            )
        }
    }
}
