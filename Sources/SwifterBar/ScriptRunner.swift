import Foundation
import Subprocess
import System

// MARK: - ScriptRunner

final class ScriptRunner: Sendable {
    /// Cached base environment resolved once at startup.
    private let baseEnvOverrides: [Environment.Key: String?]

    init() {
        self.baseEnvOverrides = ScriptRunner.resolveEnvironment()
    }

    /// Execute a plugin script and return its stdout.
    nonisolated func execute(plugin: Plugin, reason: String) async throws -> String {
        let env = await buildPluginEnvironment(plugin: plugin, reason: reason)
        let path = FilePath(plugin.path.path())

        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                let result = try await run(
                    .path(path),
                    arguments: [],
                    environment: env,
                    platformOptions: ScriptRunner.platformOptions,
                    output: .string(limit: 256 * 1024),
                    error: .discarded
                )
                if !result.terminationStatus.isSuccess {
                    if case .exited(let code) = result.terminationStatus {
                        throw PluginError.executionFailed(exitCode: code)
                    }
                }
                return result.standardOutput ?? ""
            }
            group.addTask {
                try await Task.sleep(for: .seconds(30))
                throw PluginError.timeout
            }
            guard let result = try await group.next() else {
                throw CancellationError()
            }
            group.cancelAll()
            return result
        }
    }

    /// Execute a bash command from a menu item action.
    nonisolated func executeBashAction(executable: String, params: [String]) async throws {
        // Validate executable is an absolute path
        guard executable.hasPrefix("/") else {
            throw PluginError.spawnFailed("bash= must be an absolute path, got: \(executable)")
        }

        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw PluginError.notExecutable
        }

        // Use argv array directly — never shell string interpolation
        _ = try await run(
            .path(FilePath(executable)),
            arguments: Arguments(params),
            environment: .inherit.updating(baseEnvOverrides),
            platformOptions: ScriptRunner.platformOptions,
            output: .discarded,
            error: .discarded
        )
    }

    /// Execute a streamable plugin, calling the handler with each complete output block.
    /// Blocks are delimited by `~~~` lines. Only the latest block is kept.
    nonisolated func executeStream(
        plugin: Plugin,
        onOutput: @escaping @Sendable (String) -> Void
    ) async throws {
        let env = await buildPluginEnvironment(plugin: plugin, reason: "StreamStart")
        let path = FilePath(plugin.path.path())
        let maxBlockSize = 65536  // 64KB per block

        _ = try await run(
            .path(path),
            arguments: [],
            environment: env,
            platformOptions: ScriptRunner.platformOptions,
            error: .discarded
        ) { (execution: Execution, output: AsyncBufferSequence) in
            var currentBlock = ""

            for try await chunk in output {
                let str = chunk.withUnsafeBytes { bytes in
                    String(bytes: bytes, encoding: .utf8) ?? ""
                }

                for char in str {
                    currentBlock.append(char)

                    // Check for ~~~ separator
                    if currentBlock.hasSuffix("\n~~~\n") || currentBlock.hasSuffix("\n~~~") {
                        // Remove the separator and emit the block
                        let blockEnd = currentBlock.index(
                            currentBlock.endIndex,
                            offsetBy: currentBlock.hasSuffix("\n~~~\n") ? -5 : -4
                        )
                        let block = String(currentBlock[currentBlock.startIndex..<blockEnd])
                        if !block.isEmpty {
                            onOutput(block)
                        }
                        currentBlock = ""
                    }

                    // Enforce max block size
                    if currentBlock.count > maxBlockSize {
                        currentBlock = ""
                    }
                }
            }

            // Emit any remaining content
            if !currentBlock.isEmpty {
                onOutput(currentBlock)
            }
        }
    }

    // MARK: - Environment

    private func buildPluginEnvironment(plugin: Plugin, reason: String) -> Environment {
        var overrides = baseEnvOverrides
        overrides["SWIFTERBAR_PLUGIN_PATH"] = plugin.path.path()
        overrides["SWIFTERBAR_REFRESH_REASON"] = reason

        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appending(path: "SwifterBar/\(plugin.id)")
        overrides["SWIFTERBAR_PLUGIN_CACHE_PATH"] = cacheDir.path()

        let dataDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appending(path: "SwifterBar/\(plugin.id)")
        overrides["SWIFTERBAR_PLUGIN_DATA_PATH"] = dataDir.path()

        // Create directories if needed
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)

        // OS appearance
        let isDark = UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
        overrides["SWIFTERBAR_OS_APPEARANCE"] = isDark ? "Dark" : "Light"

        return .inherit.updating(overrides)
    }

    /// Resolve the user's shell environment once at startup.
    private static func resolveEnvironment() -> [Environment.Key: String?] {
        var env: [Environment.Key: String?] = [:]

        // Build a robust PATH that covers common locations
        let pathComponents = [
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            "/usr/local/sbin",
            "/usr/bin",
            "/usr/sbin",
            "/bin",
            "/sbin",
        ]
        if let userPath = ProcessInfo.processInfo.environment["PATH"] {
            let existing = Set(pathComponents)
            let userParts = userPath.split(separator: ":").map(String.init)
            let combined = pathComponents + userParts.filter { !existing.contains($0) }
            env["PATH"] = combined.joined(separator: ":")
        } else {
            env["PATH"] = pathComponents.joined(separator: ":")
        }

        return env
    }

    private static let platformOptions: PlatformOptions = {
        var opts = PlatformOptions()
        opts.teardownSequence = [
            .send(signal: .terminate, allowedDurationToNextStep: .seconds(2)),
            .send(signal: .kill, allowedDurationToNextStep: .seconds(1)),
        ]
        return opts
    }()
}
