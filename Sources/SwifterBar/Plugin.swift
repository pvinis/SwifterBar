import Foundation

// MARK: - Plugin

nonisolated struct Plugin: Identifiable, Sendable {
    let id: String
    let name: String
    let path: URL
    let kind: PluginKind
    var metadata: PluginMetadata = PluginMetadata()
    var state: PluginState = .idle
    var lastOutput: [ParsedMenuItem] = []
    var error: PluginError?
    var isRunning: Bool = false
    var metrics: PluginMetrics?
}

// MARK: - PluginMetrics

nonisolated struct PluginMetrics: Sendable {
    var lastDuration: Double = 0     // seconds
    var totalDuration: Double = 0
    var runCount: Int = 0

    var averageDuration: Double {
        runCount > 0 ? totalDuration / Double(runCount) : 0
    }

    mutating func recordRun(duration: Double) {
        lastDuration = duration
        totalDuration += duration
        runCount += 1
    }
}

// MARK: - PluginMetadata

nonisolated struct PluginMetadata: Sendable {
    var title: String?
    var author: String?
    var authorGithub: String?
    var desc: String?
    var type: String?           // "streamable"
    var schedule: String?       // cron expression (future use)
    var hideRunInTerminal: Bool = false
    var hideLastUpdated: Bool = false
    var hideDisablePlugin: Bool = false
    var alwaysVisible: Bool = false

    /// Plugin variables: name → default value
    var variables: [PluginVariable] = []

    var isStreamable: Bool { type?.lowercased() == "streamable" }

    /// Parse metadata from the first 8KB of a script file.
    static func parse(from url: URL) -> PluginMetadata {
        let maxBytes = 8192
        guard let handle = try? FileHandle(forReadingFrom: url),
              let data = try? handle.read(upToCount: maxBytes),
              let content = String(data: data, encoding: .utf8) else {
            return PluginMetadata()
        }

        var meta = PluginMetadata()
        let pattern = /<swiftbar\.(\w+(?:\.\w+)*)>(.*?)<\/swiftbar\.\1>/

        for match in content.matches(of: pattern) {
            let key = String(match.1)
            let value = String(match.2).trimmingCharacters(in: .whitespaces)

            if key.hasPrefix("var.") {
                let varName = String(key.dropFirst(4))
                meta.variables.append(PluginVariable(name: varName, defaultValue: value))
                continue
            }

            switch key {
            case "title": meta.title = value
            case "author": meta.author = value
            case "author.github": meta.authorGithub = value
            case "desc": meta.desc = value
            case "type": meta.type = value
            case "schedule": meta.schedule = value
            case "hideRunInTerminal": meta.hideRunInTerminal = value.lowercased() == "true"
            case "hideLastUpdated": meta.hideLastUpdated = value.lowercased() == "true"
            case "hideDisablePlugin": meta.hideDisablePlugin = value.lowercased() == "true"
            case "alwaysVisible": meta.alwaysVisible = value.lowercased() == "true"
            default: break
            }
        }

        return meta
    }
}

// MARK: - PluginVariable

nonisolated struct PluginVariable: Sendable, Identifiable {
    var id: String { name }
    let name: String
    let defaultValue: String

    /// UserDefaults key for storing the user's value
    func storageKey(pluginId: String) -> String {
        "SwifterBar.var.\(pluginId).\(name)"
    }

    /// Get the current value (user override or default)
    func currentValue(pluginId: String) -> String {
        UserDefaults.standard.string(forKey: storageKey(pluginId: pluginId)) ?? defaultValue
    }

    /// Set the user's value
    func setValue(_ value: String, pluginId: String) {
        if value == defaultValue {
            UserDefaults.standard.removeObject(forKey: storageKey(pluginId: pluginId))
        } else {
            UserDefaults.standard.set(value, forKey: storageKey(pluginId: pluginId))
        }
    }
}

// MARK: - Duration Extension

extension Swift.Duration {
    var seconds: Double {
        let comps = self.components
        return Double(comps.seconds) + Double(comps.attoseconds) / 1e18
    }
}

// MARK: - PluginKind

nonisolated enum PluginKind: Sendable {
    case executable(interval: Duration)
    case streamable
}

// MARK: - PluginState

nonisolated enum PluginState: Sendable {
    case idle
    case running
    case error
}

// MARK: - PluginError

nonisolated enum PluginError: Error, Sendable {
    case executionFailed(exitCode: Int32)
    case timeout
    case notExecutable
    case invalidOwner
    case outputTooLarge
    case spawnFailed(String)
}

// MARK: - ParsedMenuItem

nonisolated struct ParsedMenuItem: Equatable, Sendable {
    var text: String
    var params: MenuItemParams
    var isHeader: Bool = false
    var isSeparator: Bool = false
    var depth: Int = 0  // 0 = top level, 1 = submenu, 2 = sub-submenu, etc.
}

// MARK: - MenuItemParams

nonisolated struct MenuItemParams: Equatable, Sendable {
    var color: String?
    var colorDark: String?
    var sfimage: String?
    var href: String?
    var bash: String?
    var bashParams: [String] = []
    var refresh: Bool = false
    var terminal: Bool = false
    var font: String?
    var size: CGFloat?
    var image: String?           // base64
    var templateImage: String?   // base64 template
    var alwaysVisible: Bool = false

    static let empty = MenuItemParams()
}

// MARK: - Filename Parsing

extension Plugin {
    /// Parse a plugin filename like "weather.5s.sh" into (name, interval, extension).
    /// Returns nil if the filename doesn't match the expected pattern.
    nonisolated static func parseFilename(_ filename: String) -> (name: String, interval: Duration, ext: String)? {
        let parts = filename.split(separator: ".", maxSplits: .max, omittingEmptySubsequences: false)
        guard parts.count >= 3 else { return nil }

        let name = String(parts[0])
        let ext = String(parts.last!)
        let intervalStr = String(parts[parts.count - 2])

        guard let interval = parseInterval(intervalStr) else { return nil }

        // Clamp interval: min 5s, max 24h
        let clamped = max(.seconds(5), min(interval, .seconds(86400)))
        return (name, clamped, ext)
    }

    /// Parse interval string like "5s", "1m", "2h", "1d", "500ms"
    nonisolated private static func parseInterval(_ str: String) -> Duration? {
        if str.hasSuffix("ms") {
            guard let val = Int(str.dropLast(2)), val > 0 else { return nil }
            return .milliseconds(val)
        } else if str.hasSuffix("s") {
            guard let val = Int(str.dropLast(1)), val > 0 else { return nil }
            return .seconds(val)
        } else if str.hasSuffix("m") {
            guard let val = Int(str.dropLast(1)), val > 0 else { return nil }
            return .seconds(val * 60)
        } else if str.hasSuffix("h") {
            guard let val = Int(str.dropLast(1)), val > 0 else { return nil }
            return .seconds(val * 3600)
        } else if str.hasSuffix("d") {
            guard let val = Int(str.dropLast(1)), val > 0 else { return nil }
            return .seconds(val * 86400)
        }
        return nil
    }
}
