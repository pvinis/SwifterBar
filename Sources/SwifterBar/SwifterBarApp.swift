import AppKit
import SwiftUI

// MARK: - App Entry Point

@main
struct SwifterBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // Menu-bar-only app — no windows, no dock icon.
        // Settings scene deferred to Phase 2.
        Settings {
            EmptyView()
        }
    }
}

// MARK: - AppDelegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var pluginManager: PluginManager!
    private var menuBarManager: MenuBarManager!
    private var observationTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide from dock
        NSApp.setActivationPolicy(.accessory)

        let pluginDir = URL.homeDirectory.appending(path: "SwifterBar")
        pluginManager = PluginManager(directory: pluginDir)
        menuBarManager = MenuBarManager(
            pluginManager: pluginManager,
            scriptRunner: pluginManager.scriptRunner
        )

        // Observe plugin changes and update the menu bar
        startObserving()

        // Start loading and running plugins
        pluginManager.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        observationTask?.cancel()
        pluginManager.stopAll()
    }

    private func startObserving() {
        observationTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { break }

                // Use withObservationTracking to watch for plugin state changes
                let snapshot = withObservationTracking {
                    self.pluginManager.plugins
                } onChange: {
                    // Will be called when plugins dictionary changes
                }

                // Update menu bar items for all plugins
                for (id, plugin) in snapshot {
                    self.menuBarManager.updateStatusItem(for: plugin)
                }

                // Remove status items for plugins that no longer exist
                let activeIds = Set(snapshot.keys)
                for id in self.menuBarManager.activePluginIds {
                    if !activeIds.contains(id) {
                        self.menuBarManager.removeStatusItem(for: id)
                    }
                }

                // Wait for the next change
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }
}
