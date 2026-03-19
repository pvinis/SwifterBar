import Foundation

// MARK: - PluginManager

@Observable
final class PluginManager: @unchecked Sendable {
    var plugins: [String: Plugin] = [:]
    var pluginOrder: [String] = []  // persisted ordering of plugin IDs
    var isPaused: Bool = false

    let scriptRunner = ScriptRunner()
    let pluginDirectory: URL
    private var directoryWatcher: DispatchSourceFileSystemObject?
    private var refreshTasks: [String: Task<Void, Never>] = [:]
    private var debounceTask: Task<Void, Never>?

    init(directory: URL) {
        self.pluginDirectory = directory
        self.pluginOrder = UserDefaults.standard.stringArray(forKey: "SwifterBar.pluginOrder") ?? []
        ensureDirectoryExists()
    }

    func savePluginOrder() {
        UserDefaults.standard.set(pluginOrder, forKey: "SwifterBar.pluginOrder")
    }

    /// Get plugins sorted by persisted order.
    var orderedPlugins: [Plugin] {
        let all = Array(plugins.values)
        return all.sorted { a, b in
            let ai = pluginOrder.firstIndex(of: a.id) ?? Int.max
            let bi = pluginOrder.firstIndex(of: b.id) ?? Int.max
            if ai == bi { return a.name < b.name }
            return ai < bi
        }
    }

    // Note: stopAll() should be called explicitly before deallocation
    // since deinit cannot call @MainActor methods.

    // MARK: - Lifecycle

    func start() {
        scanDirectory()
        watchDirectory()
        for id in plugins.keys {
            startPlugin(id: id)
        }
    }

    func stopAll() {
        directoryWatcher?.cancel()
        directoryWatcher = nil
        debounceTask?.cancel()
        for (_, task) in refreshTasks {
            task.cancel()
        }
        refreshTasks.removeAll()
    }

    func refreshAll() {
        for id in plugins.keys {
            refreshPlugin(id: id, reason: "MenuAction")
        }
    }

    func pause() {
        isPaused = true
        for (_, task) in refreshTasks {
            task.cancel()
        }
        refreshTasks.removeAll()
    }

    func resume() {
        isPaused = false
        for id in plugins.keys {
            startPlugin(id: id)
        }
    }

    func refreshPlugin(id: String, reason: String) {
        guard !isPaused else { return }
        guard var plugin = plugins[id], !plugin.isRunning else { return }

        plugin.isRunning = true
        plugins[id] = plugin

        Task {
            let startTime = ContinuousClock.now
            do {
                let output = try await scriptRunner.execute(plugin: plugin, reason: reason)
                let duration = ContinuousClock.now - startTime
                let items = OutputParser.parse(output)

                if var p = plugins[id] {
                    p.lastOutput = items
                    p.state = .idle
                    p.error = nil
                    p.isRunning = false
                    var metrics = p.metrics ?? PluginMetrics()
                    metrics.recordRun(duration: duration.seconds)
                    p.metrics = metrics
                    plugins[id] = p
                }
            } catch {
                if var p = plugins[id] {
                    p.state = .error
                    p.error = error as? PluginError ?? .spawnFailed(error.localizedDescription)
                    p.isRunning = false
                    plugins[id] = p
                }
            }
        }
    }

    // MARK: - Plugin Scheduling

    private func startPlugin(id: String) {
        guard let plugin = plugins[id] else { return }

        switch plugin.kind {
        case .executable(let interval):
            // Initial run
            refreshPlugin(id: id, reason: "FirstLaunch")

            // Schedule recurring refresh
            let task = Task {
                let index = Array(plugins.keys.sorted()).firstIndex(of: id) ?? 0
                let stagger = Duration.seconds(Double(index) * 0.5)
                try? await Task.sleep(for: stagger)

                while !Task.isCancelled {
                    try? await Task.sleep(for: interval)
                    guard !Task.isCancelled else { break }
                    refreshPlugin(id: id, reason: "Schedule")
                }
            }
            refreshTasks[id] = task

        case .streamable:
            // Start long-running process
            let runner = scriptRunner
            let task = Task {
                guard var p = plugins[id] else { return }
                p.state = .running
                p.isRunning = true
                plugins[id] = p

                // Use AsyncStream to bridge from @Sendable callback to MainActor
                let (stream, continuation) = AsyncStream<String>.makeStream()

                let streamTask = Task.detached {
                    try await runner.executeStream(plugin: plugin) { output in
                        continuation.yield(output)
                    }
                    continuation.finish()
                }

                for await output in stream {
                    let items = OutputParser.parse(output)
                    if var p = plugins[id] {
                        p.lastOutput = items
                        p.state = .running
                        p.error = nil
                        plugins[id] = p
                    }
                }

                // Wait for the stream task to complete (or handle its error)
                do {
                    try await streamTask.value
                } catch {
                    if var p = plugins[id] {
                        p.state = .error
                        p.error = error as? PluginError ?? .spawnFailed(error.localizedDescription)
                        p.isRunning = false
                        plugins[id] = p
                    }
                }
            }
            refreshTasks[id] = task
        }
    }

    private func stopPlugin(id: String) {
        refreshTasks[id]?.cancel()
        refreshTasks.removeValue(forKey: id)
    }

    // MARK: - Directory Scanning

    func scanDirectory() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: pluginDirectory,
            includingPropertiesForKeys: [.isExecutableKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else { return }

        var discoveredIds = Set<String>()

        for fileURL in files {
            let filename = fileURL.lastPathComponent

            // Skip non-parseable filenames
            guard let parsed = Plugin.parseFilename(filename) else { continue }

            // Validate file permissions
            guard validatePlugin(at: fileURL) else { continue }

            let id = filename
            discoveredIds.insert(id)

            // Only add new plugins, don't reset existing ones
            if plugins[id] == nil {
                let metadata = PluginMetadata.parse(from: fileURL)
                let kind: PluginKind = metadata.isStreamable
                    ? .streamable
                    : .executable(interval: parsed.interval)

                var plugin = Plugin(
                    id: id,
                    name: metadata.title ?? parsed.name,
                    path: fileURL,
                    kind: kind
                )
                plugin.metadata = metadata
                plugins[id] = plugin

                // Add to order if not already present
                if !pluginOrder.contains(id) {
                    pluginOrder.append(id)
                }
            }
        }

        // Remove plugins whose files no longer exist
        let staleIds = Set(plugins.keys).subtracting(discoveredIds)
        for id in staleIds {
            stopPlugin(id: id)
            plugins.removeValue(forKey: id)
            pluginOrder.removeAll { $0 == id }
        }
        savePluginOrder()
    }

    // MARK: - Directory Watching

    private func watchDirectory() {
        let fd = open(pluginDirectory.path(), O_EVTONLY)
        guard fd >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename],
            queue: .global()
        )

        source.setEventHandler { [weak self] in
            // Debounce: wait 500ms before rescanning
            self?.debounceRescan()
        }

        source.setCancelHandler {
            close(fd)
        }

        source.resume()
        self.directoryWatcher = source
    }

    private nonisolated func debounceRescan() {
        Task { @MainActor [weak self] in
            self?.debounceTask?.cancel()
            self?.debounceTask = Task {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }
                self?.handleDirectoryChange()
            }
        }
    }

    private func handleDirectoryChange() {
        let previousIds = Set(plugins.keys)
        scanDirectory()
        let currentIds = Set(plugins.keys)

        // Start newly discovered plugins
        let newIds = currentIds.subtracting(previousIds)
        for id in newIds {
            startPlugin(id: id)
        }
    }

    // MARK: - Validation

    private func validatePlugin(at url: URL) -> Bool {
        let fm = FileManager.default

        // Must be executable
        guard fm.isExecutableFile(atPath: url.path()) else { return false }

        // Check ownership (must be current user)
        guard let attrs = try? fm.attributesOfItem(atPath: url.path()),
              let ownerID = attrs[.ownerAccountID] as? NSNumber else {
            return false
        }
        guard ownerID.uint32Value == getuid() else { return false }

        // Resolve symlinks — reject if target is outside plugin directory
        let resolved = url.resolvingSymlinksInPath()
        guard resolved.path().hasPrefix(pluginDirectory.resolvingSymlinksInPath().path()) else {
            return false
        }

        return true
    }

    private func ensureDirectoryExists() {
        try? FileManager.default.createDirectory(
            at: pluginDirectory,
            withIntermediateDirectories: true
        )
    }
}
