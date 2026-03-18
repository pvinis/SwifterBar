import AppKit
import Foundation
import ServiceManagement

// MARK: - MenuBarManager

final class MenuBarManager {
    private var statusItems: [String: NSStatusItem] = [:]
    private let pluginManager: PluginManager
    private let scriptRunner: ScriptRunner
    private let imageCache = NSCache<NSString, NSImage>()

    init(pluginManager: PluginManager, scriptRunner: ScriptRunner) {
        self.pluginManager = pluginManager
        self.scriptRunner = scriptRunner
        imageCache.countLimit = 100
    }

    private var isDarkMode: Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    var activePluginIds: Set<String> {
        Set(statusItems.keys)
    }

    // MARK: - Status Item Management

    func updateStatusItem(for plugin: Plugin) {
        let item = statusItem(for: plugin)

        guard let button = item.button else { return }

        // Find header items
        let headers = plugin.lastOutput.filter(\.isHeader)
        if headers.isEmpty && !plugin.lastOutput.isEmpty {
            // No headers but has body — show plugin name
            button.title = plugin.name
        } else if let first = headers.first {
            applyHeader(first, to: button)
        } else if plugin.state == .error {
            button.title = "⚠ \(plugin.name)"
        } else {
            button.title = plugin.name
        }

        // Check alwaysVisible
        let alwaysVisible = plugin.lastOutput.contains { $0.params.alwaysVisible }
        if plugin.lastOutput.isEmpty && !alwaysVisible {
            button.isHidden = true
        } else {
            button.isHidden = false
        }

        // Build the dropdown menu
        let menu = buildMenu(for: plugin)
        item.menu = menu
    }

    func removeStatusItem(for pluginId: String) {
        if let item = statusItems[pluginId] {
            NSStatusBar.system.removeStatusItem(item)
            statusItems.removeValue(forKey: pluginId)
        }
    }

    // MARK: - Status Item Creation

    private func statusItem(for plugin: Plugin) -> NSStatusItem {
        if let existing = statusItems[plugin.id] {
            return existing
        }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = "SwifterBar-\(plugin.id)"
        item.button?.title = plugin.name

        // Set up right-click handling
        item.button?.target = self
        item.button?.action = #selector(statusItemClicked(_:))
        item.button?.sendAction(on: [.leftMouseDown, .rightMouseUp])
        item.button?.identifier = NSUserInterfaceItemIdentifier(plugin.id)

        statusItems[plugin.id] = item
        return item
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }
        guard let pluginId = sender.identifier?.rawValue else { return }

        if event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            // Show context menu
            let menu = buildContextMenu()
            if let item = statusItems[pluginId] {
                item.menu = menu
                sender.performClick(nil)
                // Restore the plugin menu after context menu closes
                if let plugin = pluginManager.plugins[pluginId] {
                    item.menu = buildMenu(for: plugin)
                }
            }
        }
        // Left-click is handled by the regular menu
    }

    // MARK: - Menu Building

    private func buildMenu(for plugin: Plugin) -> NSMenu {
        let menu = NSMenu()

        let bodyItems = plugin.lastOutput.filter { !$0.isHeader }

        // Track menu stack for nested submenus
        // menuStack[0] = root menu, menuStack[1] = first submenu, etc.
        var menuStack: [NSMenu] = [menu]

        for item in bodyItems {
            if item.isSeparator {
                menuStack.last?.addItem(.separator())
                continue
            }

            let menuItem = NSMenuItem(title: item.text, action: nil, keyEquivalent: "")
            applyParams(item.params, to: menuItem)

            if item.depth == 0 {
                // Top-level item — reset stack to root
                menuStack = [menu]
                menu.addItem(menuItem)
            } else {
                // Ensure we have a parent at depth-1
                // If depth > current stack size, attach submenu to last item at each level
                while menuStack.count <= item.depth {
                    // Get the last item in the current deepest menu to attach a submenu to
                    guard let parentMenu = menuStack.last,
                          let lastItem = parentMenu.items.last(where: { !$0.isSeparatorItem }) else {
                        // Can't nest deeper without a parent item — just add to current menu
                        menuStack.last?.addItem(menuItem)
                        break
                    }
                    if lastItem.submenu == nil {
                        lastItem.submenu = NSMenu()
                    }
                    menuStack.append(lastItem.submenu!)
                }

                // Trim stack if we went back up levels
                while menuStack.count > item.depth + 1 {
                    menuStack.removeLast()
                }

                menuStack.last?.addItem(menuItem)
            }
        }

        // Always add a separator and context items at the bottom
        if !bodyItems.isEmpty {
            menu.addItem(.separator())
        }

        // Refresh item
        let refreshItem = NSMenuItem(title: "Refresh", action: #selector(refreshClicked(_:)), keyEquivalent: "r")
        refreshItem.target = self
        refreshItem.representedObject = plugin.id
        menu.addItem(refreshItem)

        menu.addItem(.separator())

        // Open plugin folder
        let openFolder = NSMenuItem(title: "Open Plugin Folder", action: #selector(openPluginFolder), keyEquivalent: "")
        openFolder.target = self
        menu.addItem(openFolder)

        // Refresh all
        let refreshAll = NSMenuItem(title: "Refresh All", action: #selector(refreshAllClicked), keyEquivalent: "")
        refreshAll.target = self
        menu.addItem(refreshAll)

        menu.addItem(.separator())

        appendSharedMenuItems(to: menu)

        return menu
    }

    private func buildContextMenu() -> NSMenu {
        let menu = NSMenu()

        let openFolder = NSMenuItem(title: "Open Plugin Folder", action: #selector(openPluginFolder), keyEquivalent: "")
        openFolder.target = self
        menu.addItem(openFolder)

        let refreshAll = NSMenuItem(title: "Refresh All", action: #selector(refreshAllClicked), keyEquivalent: "")
        refreshAll.target = self
        menu.addItem(refreshAll)

        menu.addItem(.separator())

        appendSharedMenuItems(to: menu)

        return menu
    }

    /// Append launch-at-login toggle and quit to a menu.
    private func appendSharedMenuItems(to menu: NSMenu) {
        let launchAtLogin = NSMenuItem(
            title: "Launch at Login",
            action: #selector(toggleLaunchAtLogin(_:)),
            keyEquivalent: ""
        )
        launchAtLogin.target = self
        launchAtLogin.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(launchAtLogin)

        let settings = NSMenuItem(title: "Settings...", action: #selector(openSettingsClicked), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit SwifterBar", action: #selector(quitClicked), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    // MARK: - Apply Styling

    private func applyHeader(_ item: ParsedMenuItem, to button: NSStatusBarButton) {
        button.title = item.text

        if let sfimage = item.params.sfimage {
            let image = NSImage(systemSymbolName: sfimage, accessibilityDescription: item.text)
            image?.isTemplate = true
            button.image = image
            if !item.text.isEmpty {
                button.imagePosition = .imageLeading
            } else {
                button.imagePosition = .imageOnly
                button.title = ""
            }
        } else {
            button.image = nil
        }
    }

    private func applyParams(_ params: MenuItemParams, to menuItem: NSMenuItem) {
        // Color — pick dark variant if available and in dark mode
        let colorStr: String? = {
            if let dark = params.colorDark, isDarkMode {
                return dark
            }
            return params.color
        }()

        if let colorStr {
            if let color = NSColor(cssHex: colorStr) {
                let attrStr = NSAttributedString(
                    string: menuItem.title,
                    attributes: [.foregroundColor: color]
                )
                menuItem.attributedTitle = attrStr
            }
        }

        // Font and size
        if params.font != nil || params.size != nil {
            let fontName = params.font ?? NSFont.menuFont(ofSize: 0).fontName
            let fontSize = params.size ?? NSFont.menuFont(ofSize: 0).pointSize
            if let font = NSFont(name: fontName, size: fontSize) {
                let attrs: [NSAttributedString.Key: Any] = [.font: font]
                if let existing = menuItem.attributedTitle {
                    let mutable = NSMutableAttributedString(attributedString: existing)
                    mutable.addAttributes(attrs, range: NSRange(location: 0, length: mutable.length))
                    menuItem.attributedTitle = mutable
                } else {
                    menuItem.attributedTitle = NSAttributedString(string: menuItem.title, attributes: attrs)
                }
            }
        }

        // SF Symbol image
        if let sfimage = params.sfimage {
            let image = NSImage(systemSymbolName: sfimage, accessibilityDescription: menuItem.title)
            image?.isTemplate = true
            menuItem.image = image
        }

        // Base64 image
        if let imageStr = params.image {
            if let image = decodeImage(imageStr, template: false) {
                menuItem.image = image
            }
        }

        // Template image
        if let imageStr = params.templateImage {
            if let image = decodeImage(imageStr, template: true) {
                menuItem.image = image
            }
        }

        // Actions — set target and action if there's any interactivity
        let hasAction = params.href != nil || params.bash != nil || params.refresh
        if hasAction {
            menuItem.target = self
            menuItem.action = #selector(menuItemClicked(_:))
            menuItem.representedObject = ParamsBox(params)
        } else {
            // Set a no-op action so the item appears enabled (respects color)
            menuItem.target = self
            menuItem.action = #selector(noOpAction(_:))
        }
    }

    // MARK: - Image Decoding

    private func decodeImage(_ base64: String, template: Bool) -> NSImage? {
        let cacheKey = NSString(string: "\(base64.hashValue)-\(template)")
        if let cached = imageCache.object(forKey: cacheKey) {
            return cached
        }

        guard let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters) else {
            return nil
        }

        // Size limit: 1MB decoded
        guard data.count <= OutputParser.maxImageDataSize else { return nil }

        guard let image = NSImage(data: data) else { return nil }

        // Dimension limit
        let size = image.size
        guard size.width <= CGFloat(OutputParser.maxImageDimension),
              size.height <= CGFloat(OutputParser.maxImageDimension) else {
            return nil
        }

        image.isTemplate = template
        imageCache.setObject(image, forKey: cacheKey)
        return image
    }

    // MARK: - Actions

    @objc private func menuItemClicked(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? ParamsBox else { return }
        let params = box.params

        // Open URL
        if let href = params.href, let url = URL(string: href) {
            // Only allow http/https
            if url.scheme == "http" || url.scheme == "https" {
                NSWorkspace.shared.open(url)
            }
        }

        // Execute bash command
        if let bash = params.bash {
            Task {
                try? await scriptRunner.executeBashAction(
                    executable: bash,
                    params: params.bashParams
                )
            }
        }

        // Refresh — find which plugin this belongs to and refresh it
        if params.refresh {
            // Find the plugin by walking up the menu hierarchy
            if let menu = sender.menu {
                for (id, item) in statusItems where item.menu === menu {
                    pluginManager.refreshPlugin(id: id, reason: "MenuAction")
                    break
                }
            }
        }
    }

    @objc private func refreshClicked(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String {
            pluginManager.refreshPlugin(id: id, reason: "MenuAction")
        }
    }

    @objc private func openPluginFolder() {
        NSWorkspace.shared.open(pluginManager.pluginDirectory)
    }

    @objc private func refreshAllClicked() {
        pluginManager.refreshAll()
    }

    @objc private func openSettingsClicked() {
        openSettings()
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            // Silently fail — user can toggle in System Settings
        }
    }

    @objc private func quitClicked() {
        NSApp.terminate(nil)
    }

    @objc private func noOpAction(_ sender: NSMenuItem) {
        // Intentionally empty — makes items appear enabled
    }
}

// MARK: - ParamsBox

/// Wraps MenuItemParams for use as NSMenuItem.representedObject.
private final class ParamsBox: @unchecked Sendable {
    let params: MenuItemParams
    init(_ params: MenuItemParams) { self.params = params }
}

// MARK: - NSColor Hex Extension

extension NSColor {
    convenience init?(cssHex: String) {
        var hex = cssHex.trimmingCharacters(in: .whitespacesAndNewlines)
        if hex.hasPrefix("#") { hex.removeFirst() }

        var rgb: UInt64 = 0
        guard Scanner(string: hex).scanHexInt64(&rgb) else { return nil }

        switch hex.count {
        case 6:
            self.init(
                red: CGFloat((rgb >> 16) & 0xFF) / 255,
                green: CGFloat((rgb >> 8) & 0xFF) / 255,
                blue: CGFloat(rgb & 0xFF) / 255,
                alpha: 1
            )
        case 8:
            self.init(
                red: CGFloat((rgb >> 24) & 0xFF) / 255,
                green: CGFloat((rgb >> 16) & 0xFF) / 255,
                blue: CGFloat((rgb >> 8) & 0xFF) / 255,
                alpha: CGFloat(rgb & 0xFF) / 255
            )
        default:
            return nil
        }
    }
}
