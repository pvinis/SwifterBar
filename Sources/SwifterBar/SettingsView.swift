import SwiftUI

// MARK: - Settings View

struct SettingsView: View {
    let pluginManager: PluginManager

    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") {
                GeneralSettingsView(pluginManager: pluginManager)
            }
            Tab("Plugins", systemImage: "puzzlepiece") {
                PluginListSettingsView(pluginManager: pluginManager)
            }
        }
        .frame(width: 550, height: 400)
    }
}

// MARK: - General Settings

struct GeneralSettingsView: View {
    let pluginManager: PluginManager

    var body: some View {
        Form {
            LabeledContent("Plugin Folder") {
                HStack {
                    Text(pluginManager.pluginDirectory.path(percentEncoded: false))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.open(pluginManager.pluginDirectory)
                    }
                }
            }

            LabeledContent("Plugins") {
                Text("\(pluginManager.plugins.count) loaded")
                    .foregroundStyle(.secondary)
            }

            Button("Refresh All Plugins") {
                pluginManager.refreshAll()
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - Plugin List Settings

struct PluginListSettingsView: View {
    let pluginManager: PluginManager
    @State private var selectedPluginId: String?

    var body: some View {
        HSplitView {
            // Plugin list (left) — drag to reorder
            List(selection: $selectedPluginId) {
                ForEach(pluginManager.orderedPlugins, id: \.id) { plugin in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(plugin.name)
                                .font(.headline)
                            Text(plugin.id)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        stateIndicator(for: plugin)

                        kindBadge(for: plugin)
                    }
                    .padding(.vertical, 2)
                    .tag(plugin.id)
                }
            }
            .frame(minWidth: 220)

            // Plugin detail (right)
            if let id = selectedPluginId, let plugin = pluginManager.plugins[id] {
                PluginDetailView(plugin: plugin, pluginManager: pluginManager)
            } else {
                Text("Select a plugin")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    @ViewBuilder
    private func stateIndicator(for plugin: Plugin) -> some View {
        switch plugin.state {
        case .idle:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .running:
            Image(systemName: "arrow.clockwise.circle.fill")
                .foregroundStyle(.blue)
        case .error:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
    }

    @ViewBuilder
    private func kindBadge(for plugin: Plugin) -> some View {
        switch plugin.kind {
        case .executable(let interval):
            Text(formatInterval(interval))
                .font(.caption)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.quaternary)
                .clipShape(Capsule())
        case .streamable:
            Text("stream")
                .font(.caption)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.blue.opacity(0.2))
                .clipShape(Capsule())
        }
    }

    private func formatInterval(_ duration: Duration) -> String {
        let seconds = Int(duration.components.seconds)
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        return "\(seconds / 3600)h"
    }
}

// MARK: - Plugin Detail View

struct PluginDetailView: View {
    let plugin: Plugin
    let pluginManager: PluginManager

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Header
                VStack(alignment: .leading, spacing: 4) {
                    Text(plugin.name)
                        .font(.title2.bold())
                    if let author = plugin.metadata.author {
                        Text("by \(author)")
                            .foregroundStyle(.secondary)
                    }
                    if let desc = plugin.metadata.desc {
                        Text(desc)
                            .foregroundStyle(.secondary)
                            .font(.callout)
                    }
                }

                Divider()

                // Error display
                if plugin.state == .error, let error = plugin.error {
                    GroupBox("Error") {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(errorDescription(error))
                                .foregroundStyle(.red)
                                .font(.callout.monospaced())
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                // Execution metrics
                if let metrics = plugin.metrics {
                    GroupBox("Performance") {
                        HStack(spacing: 20) {
                            VStack(alignment: .leading) {
                                Text("Last run")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(String(format: "%.0fms", metrics.lastDuration * 1000))
                                    .font(.callout.monospaced())
                            }
                            VStack(alignment: .leading) {
                                Text("Average")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(String(format: "%.0fms", metrics.averageDuration * 1000))
                                    .font(.callout.monospaced())
                            }
                            VStack(alignment: .leading) {
                                Text("Runs")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text("\(metrics.runCount)")
                                    .font(.callout.monospaced())
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                // Plugin variables
                if !plugin.metadata.variables.isEmpty {
                    GroupBox("Variables") {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(plugin.metadata.variables) { variable in
                                VariableEditor(variable: variable, pluginId: plugin.id) {
                                    pluginManager.refreshPlugin(id: plugin.id, reason: "VariableChange")
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                // Actions
                HStack {
                    Button("Refresh") {
                        pluginManager.refreshPlugin(id: plugin.id, reason: "MenuAction")
                    }
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([plugin.path])
                    }
                }
            }
            .padding()
        }
        .frame(minWidth: 280)
    }

    private func errorDescription(_ error: PluginError) -> String {
        switch error {
        case .executionFailed(let code): "Exit code: \(code)"
        case .timeout: "Timed out (30s)"
        case .notExecutable: "File is not executable"
        case .invalidOwner: "Invalid file owner"
        case .outputTooLarge: "Output exceeded 256KB limit"
        case .spawnFailed(let msg): msg
        }
    }
}

// MARK: - Variable Editor

struct VariableEditor: View {
    let variable: PluginVariable
    let pluginId: String
    let onChanged: () -> Void

    @State private var value: String = ""

    var body: some View {
        HStack {
            Text(variable.name)
                .font(.callout)
                .frame(width: 100, alignment: .trailing)
            TextField(variable.defaultValue, text: $value)
                .textFieldStyle(.roundedBorder)
                .onSubmit {
                    variable.setValue(value, pluginId: pluginId)
                    onChanged()
                }
        }
        .onAppear {
            value = variable.currentValue(pluginId: pluginId)
        }
    }
}
