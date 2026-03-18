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
        .frame(width: 500, height: 350)
    }
}

// MARK: - General Settings

struct GeneralSettingsView: View {
    let pluginManager: PluginManager
    @State private var showFolderPicker = false

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

    var body: some View {
        List {
            ForEach(sortedPlugins, id: \.id) { plugin in
                HStack {
                    VStack(alignment: .leading) {
                        Text(plugin.name)
                            .font(.headline)
                        Text(plugin.id)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    // State indicator
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

                    // Kind badge
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
                .padding(.vertical, 2)
            }
        }
    }

    private var sortedPlugins: [Plugin] {
        pluginManager.plugins.values.sorted { $0.name < $1.name }
    }

    private func formatInterval(_ duration: Duration) -> String {
        let seconds = Int(duration.components.seconds)
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        return "\(seconds / 3600)h"
    }
}
