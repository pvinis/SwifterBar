import Foundation

// MARK: - PluginManager

@Observable
final class PluginManager {
    var plugins: [String: Plugin] = [:]

    let scriptRunner = ScriptRunner()
    let pluginDirectory: URL
    private var directoryWatcher: DispatchSourceFileSystemObject?
    private var refreshTasks: [String: Task<Void, Never>] = [:]
    private var debounceTask: Task<Void, Never>?

    init(directory: URL) {
        self.pluginDirectory = directory
        ensureDirectoryExists()
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

    func refreshPlugin(id: String, reason: String) {
        guard var plugin = plugins[id], !plugin.isRunning else { return }

        plugin.isRunning = true
        plugins[id] = plugin

        Task {
            do {
                let output = try await scriptRunner.execute(plugin: plugin, reason: reason)
                let items = OutputParser.parse(output)

                if var p = plugins[id] {
                    p.lastOutput = items
                    p.state = .idle
                    p.error = nil
                    p.isRunning = false
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

        // Initial run
        refreshPlugin(id: id, reason: "FirstLaunch")

        // Schedule recurring refresh for executable plugins
        if case .executable(let interval) = plugin.kind {
            let task = Task {
                // Stagger start based on plugin index
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
                let plugin = Plugin(
                    id: id,
                    name: parsed.name,
                    path: fileURL,
                    kind: .executable(interval: parsed.interval)
                )
                plugins[id] = plugin
            }
        }

        // Remove plugins whose files no longer exist
        let staleIds = Set(plugins.keys).subtracting(discoveredIds)
        for id in staleIds {
            stopPlugin(id: id)
            plugins.removeValue(forKey: id)
        }
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
