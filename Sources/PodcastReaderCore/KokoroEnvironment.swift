import CryptoKit
import Foundation

public struct KokoroVoice: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let name: String

    public var displayName: String {
        "Kokoro \(name)"
    }

    public static let heart = KokoroVoice(id: "af_heart", name: "Heart")
    public static let all = [
        heart,
        KokoroVoice(id: "af_bella", name: "Bella"),
        KokoroVoice(id: "am_michael", name: "Michael"),
        KokoroVoice(id: "bf_emma", name: "Emma"),
    ]
}

public enum KokoroError: Error, Equatable {
    case setupFailed
    case renderFailed
    case notInstalled
}

/// Where setup gets uv, the tool that installs everything else.
public enum UVSource: Sendable {
    /// A build of uv to download, checked against its published fingerprint.
    case download(URL, sha256: String)
    /// A copy that's already on this Mac.
    case existing(URL)

    public static let pinned = UVSource.download(
        URL(string: "https://github.com/astral-sh/uv/releases/download/0.13.7/uv-aarch64-apple-darwin.tar.gz")!,
        sha256: "81b811b57e4624df7ed3aac148e0359100d9962f3d9dce00aec533dc2e086731"
    )
}

/// The Python environment Kokoro runs in, kept in one folder that can be deleted outright.
public struct KokoroEnvironment: Sendable {
    /// Changing this makes setup run again, for when the helper or versions change.
    private static let installVersion = 1

    public static var defaultRoot: URL {
        URL.applicationSupportDirectory
            .appending(path: "Podcast Reader", directoryHint: .isDirectory)
            .appending(path: "kokoro", directoryHint: .isDirectory)
    }

    public let root: URL
    private let uv: UVSource

    public init(root: URL = KokoroEnvironment.defaultRoot, uv: UVSource = .pinned) {
        self.root = root
        self.uv = uv
    }

    public var pythonURL: URL { root.appending(path: "venv/bin/python") }
    public var helperURL: URL { root.appending(path: "kokoro_helper.py") }
    public var modelsURL: URL { root.appending(path: "models", directoryHint: .isDirectory) }
    var cacheURL: URL { root.appending(path: "cache", directoryHint: .isDirectory) }
    var toolsURL: URL { root.appending(path: "tools", directoryHint: .isDirectory) }
    var espeakDataURL: URL { root.appending(path: "venv/lib/python3.12/site-packages/espeakng_loader/espeak-ng-data") }
    /// The pronunciation library fails on long paths, and its real location is deep.
    var espeakLinkURL: URL { root.appending(path: "e") }
    var markerURL: URL { root.appending(path: "installed-\(Self.installVersion)") }
    var logURL: URL { root.appending(path: "last-run.log") }

    /// Only the marker means setup finished, so an interrupted setup simply runs again.
    public var isInstalled: Bool {
        FileManager.default.fileExists(atPath: markerURL.path)
            && FileManager.default.isExecutableFile(atPath: pythonURL.path)
    }

    public func processEnvironment(offline: Bool) -> [String: String] {
        var values = [
            "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HF_HOME": modelsURL.path,
            "HF_HUB_DISABLE_TELEMETRY": "1",
            "UV_CACHE_DIR": cacheURL.path,
            // Everything stays in this folder, and nothing already on the Mac changes the result.
            "UV_PYTHON_INSTALL_DIR": root.appending(path: "python", directoryHint: .isDirectory).path,
            "UV_PYTHON_PREFERENCE": "only-managed",
            "UV_NO_CONFIG": "1",
            "ESPEAK_DATA_PATH": espeakLinkURL.path,
            "PYTHONUNBUFFERED": "1",
            "TOKENIZERS_PARALLELISM": "false",
        ]
        if offline {
            values["HF_HUB_OFFLINE"] = "1"
        }
        return values
    }

    /// Installs everything. Safe to run again after an interruption.
    public func install(onProgress: @escaping @Sendable (Double) -> Void) async throws {
        let manager = FileManager.default
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        let environment = processEnvironment(offline: false)
        let uv = try await getUV(environment)
        onProgress(0.02)

        try await runSetupCommand(uv, ["venv", "--allow-existing", "--python", "3.12", root.appending(path: "venv").path], environment)
        onProgress(0.1)

        // Ready-made packages only, because building one needs developer tools most Macs don't have.
        try await runSetupCommand(
            uv,
            ["pip", "install", "--python", pythonURL.path, "--no-deps", "--no-build"] + KokoroPackages.locked,
            environment
        )
        onProgress(0.55)

        do {
            try KokoroHelper.source.write(to: helperURL, atomically: true, encoding: .utf8)
            try? manager.removeItem(at: espeakLinkURL)
            try manager.createSymbolicLink(at: espeakLinkURL, withDestinationURL: espeakDataURL)
        } catch {
            throw KokoroError.setupFailed
        }

        try await runSetupCommand(pythonURL, [helperURL.path, "prepare"], environment) { line in
            // The helper reports its way through the downloads.
            if let fraction = Double(line) {
                onProgress(0.55 + fraction * 0.44)
            }
        }

        try? manager.removeItem(at: cacheURL)
        try? manager.removeItem(at: toolsURL)
        try? manager.removeItem(at: logURL)
        guard manager.createFile(atPath: markerURL.path, contents: Data()) else { throw KokoroError.setupFailed }
        onProgress(1)
    }

    private func getUV(_ environment: [String: String]) async throws -> URL {
        switch uv {
        case .existing(let url): url
        case .download(let source, let sha256): try await downloadUV(from: source, sha256: sha256, environment)
        }
    }

    /// Nothing from the download runs until its fingerprint has been checked.
    private func downloadUV(from source: URL, sha256: String, _ environment: [String: String]) async throws -> URL {
        let manager = FileManager.default
        try? manager.removeItem(at: toolsURL)

        let download: URL
        do {
            (download, _) = try await URLSession.shared.download(from: source)
        } catch {
            try Task.checkCancellation()
            throw KokoroError.setupFailed
        }
        defer { try? manager.removeItem(at: download) }

        guard let data = try? Data(contentsOf: download, options: .mappedIfSafe),
              SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == sha256,
              (try? manager.createDirectory(at: toolsURL, withIntermediateDirectories: true)) != nil
        else {
            throw KokoroError.setupFailed
        }
        try await runSetupCommand(
            URL(fileURLWithPath: "/usr/bin/tar"),
            ["-xzf", download.path, "-C", toolsURL.path, "--strip-components", "1"],
            environment
        )
        let uv = toolsURL.appending(path: "uv")
        guard manager.isExecutableFile(atPath: uv.path) else { throw KokoroError.setupFailed }
        return uv
    }

    public func remove() throws {
        if FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.removeItem(at: root)
        }
    }

    private func runSetupCommand(
        _ executable: URL,
        _ arguments: [String],
        _ environment: [String: String],
        onLine: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws {
        let result = try await KokoroCommand.run(executable, arguments, environment: environment, onLine: onLine)
        try Task.checkCancellation()
        guard result.status == 0 else {
            try? result.errorOutput.write(to: logURL, atomically: true, encoding: .utf8)
            throw KokoroError.setupFailed
        }
    }
}

/// Runs a command, and stops it if the task is canceled. Its input stays open while it
/// runs, so that the helper can tell if this app goes away, by seeing its input close.
enum KokoroCommand {
    struct Result: Sendable {
        let status: Int32
        let errorOutput: String
    }

    /// Output is delivered a line at a time, and only the last of the errors is kept.
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var outputBuffer = Data()
        var errorOutput = Data()
        var continuation: CheckedContinuation<Int32, Never>?
        var exitStatus: Int32?
    }

    static func run(
        _ executable: URL,
        _ arguments: [String],
        environment: [String: String],
        onLine: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> Result {
        try Task.checkCancellation()

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors

        let state = State()
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            // This keeps firing at the end of a pipe until it's removed.
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            let lines = state.lock.withLock { () -> [String] in
                state.outputBuffer.append(data)
                var finished: [String] = []
                while let newline = state.outputBuffer.firstIndex(of: 0x0A) {
                    let line = state.outputBuffer[state.outputBuffer.startIndex..<newline]
                    finished.append(String(decoding: line, as: UTF8.self))
                    state.outputBuffer.removeSubrange(state.outputBuffer.startIndex...newline)
                }
                return finished
            }
            lines.forEach(onLine)
        }
        errors.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            state.lock.withLock {
                state.errorOutput.append(data)
                if state.errorOutput.count > 20_000 {
                    state.errorOutput.removeFirst(state.errorOutput.count - 20_000)
                }
            }
        }
        process.terminationHandler = { process in
            let status = process.terminationStatus
            state.lock.withLock {
                state.exitStatus = status
                state.continuation?.resume(returning: status)
                state.continuation = nil
            }
        }

        do {
            try process.run()
        } catch {
            throw KokoroError.setupFailed
        }

        let status = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Int32, Never>) in
                state.lock.withLock {
                    if let status = state.exitStatus {
                        continuation.resume(returning: status)
                    } else {
                        state.continuation = continuation
                    }
                }
            }
        } onCancel: {
            // Closing the input is what makes the helper stop itself and all its workers.
            try? input.fileHandleForWriting.close()
            process.terminate()
        }

        output.fileHandleForReading.readabilityHandler = nil
        errors.fileHandleForReading.readabilityHandler = nil
        try? input.fileHandleForWriting.close()
        try Task.checkCancellation()
        return Result(status: status, errorOutput: state.lock.withLock { String(decoding: state.errorOutput, as: UTF8.self) })
    }
}
