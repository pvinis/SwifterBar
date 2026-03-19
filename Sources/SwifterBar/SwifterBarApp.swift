import AppKit
import SwiftUI

// MARK: - App Entry Point

@main
struct SwifterBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            if let pm = appDelegate.pluginManager {
                SettingsView(pluginManager: pm)
            }
        }
    }
}

// MARK: - AppDelegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    var pluginManager: PluginManager!
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

    /// Called when Settings window closes — hide dock icon again
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        NSApp.setActivationPolicy(.accessory)
        return false
    }

    private func startObserving() {
        let pm = pluginManager!
        let mbm = menuBarManager!
        observationTask = Task { @MainActor in
            while !Task.isCancelled {
                let snapshot = withObservationTracking {
                    pm.plugins
                } onChange: {
                    // Will be called when plugins dictionary changes
                }

                for (_, plugin) in snapshot {
                    mbm.updateStatusItem(for: plugin)
                }

                let activeIds = Set(snapshot.keys)
                for id in mbm.activePluginIds {
                    if !activeIds.contains(id) {
                        mbm.removeStatusItem(for: id)
                    }
                }

                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }
}

// MARK: - Open Settings Helper

/// Opens the Settings window from AppKit context (menu bar actions).
func openSettings() {
    // Show dock icon temporarily so the window is accessible
    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)

    // Open settings via the standard action
    if #available(macOS 14, *) {
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    } else {
        NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
    }
}
