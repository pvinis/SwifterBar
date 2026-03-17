---
title: "SwifterBar: A Modern Plugin-Based Menu Bar App"
type: feat
status: active
date: 2026-03-17
---

# SwifterBar: A Modern Plugin-Based Menu Bar App

## Overview

Build a new, simpler, modern replacement for SwiftBar — a macOS menu bar app that runs scripts/plugins and displays their output in the menu bar. Target macOS 26 (Tahoe), use Swift 6.2 with modern concurrency, and keep the codebase minimal and maintainable.

SwiftBar has accumulated complexity, security issues, and bugs over 5+ years. Rather than forking, we start fresh — carrying forward the good ideas, dropping the cruft, and using 2026-era Swift/macOS APIs.

## Problem Statement / Motivation

SwiftBar works but has significant issues:

- **Critical bugs**: Menu bar items disappearing (#442, 9+ reactions), app hanging (#440), position instability (#458)
- **Security holes**: Shell injection in string escaping, arbitrary code execution via URL scheme, no plugin verification
- **Outdated code**: `Foundation.Process` (replaced by `swift-subprocess`), Combine (replaced by Observation/async), mixed AppKit/SwiftUI
- **Complexity**: 30+ source files, god classes (500+ lines), <10% test coverage, plugin metadata parsed 3 different ways
- **No modern macOS support**: No Liquid Glass, no Control Centre, no modern concurrency

Users love the concept but are frustrated by reliability. A clean rewrite targeting a single macOS version eliminates backwards-compatibility weight.

## Proposed Solution

### What to Keep (Recreate)

| Feature | Why |
|---------|-----|
| Script-based plugin system | Core value prop — any language, any tool |
| Filename-based config (`name.interval.ext`) | Simple, proven convention |
| Plugin output format (header/body/`---` separators) | Compatible with existing xbar/SwiftBar plugins |
| Executable plugins (run on interval) | Primary use case |
| Streamable plugins (long-running) | Important for real-time data |
| SF Symbol support | Modern icon rendering |
| Dark/light theme awareness | Essential UX |
| Plugin environment variables | Plugins need context |
| Refresh reasons | Useful for plugin authors |
| Plugin cache/data directories | Per-plugin storage |
| Menu item actions (bash commands, href, refresh) | Core interactivity |

### What to Drop

| Feature | Why |
|---------|-----|
| Shortcut plugins | Adds complexity, low usage — users can call Shortcuts from scripts |
| Ephemeral plugins (URL scheme creation) | Security nightmare, arbitrary code execution |
| Plugin Repository browser | Scope creep — link to a website instead |
| WebView in menus | Complex, fragile, niche use case |
| ANSI color parsing | Complexity for minimal value — use native color params |
| BitBar metadata format | Only support SwiftBar-style metadata |
| Localization (7 languages) | Start English-only, add i18n later if needed |
| Sparkle auto-updater | Use macOS built-in update mechanism or manual updates initially |
| HotKey support | Niche, adds dependency — can add later |
| Title cycling | Minor feature, adds complexity |
| Diff-based menu updates | Premature optimization — rebuilding 10-30 NSMenuItems is trivially fast |
| Tab stops | Single PR requested it, not worth parsing complexity for v1 |
| Plugin reordering (drag) | Nice-to-have, not essential — alphabetical/filesystem order for v1 |

### What to Add (From Issues/PRs)

| Feature | Source | Phase |
|---------|--------|-------|
| `alwaysVisible` metadata | #475 — prevent auto-hiding on empty output | Phase 1 (trivial boolean) |
| Proper disabled-state handling | #465 — respect `color=` on non-actionable items | Phase 2 |
| Plugin variables (`xbar.var` support) | #469, #472 — most requested feature | Phase 3 (defer — see if users ask) |
| GUI for plugin settings | #468 — natural companion to plugin variables | Phase 3 |

## Technical Approach

### Architecture (Simplified)

3 SPM targets for a <2000-line app is premature abstraction. Single target, 7 source files.

```
SwifterBar/
├── Package.swift
├── Sources/
│   └── SwifterBar/
│       ├── SwifterBarApp.swift       # Entry point, @Observable AppState, app lifecycle
│       ├── Plugin.swift              # Plugin struct, PluginKind enum, PluginState
│       ├── PluginManager.swift       # Discovery, lifecycle, directory watching (DispatchSource)
│       ├── ScriptRunner.swift        # swift-subprocess wrapper, shell env detection
│       ├── OutputParser.swift        # Parse script stdout → [ParsedMenuItem]
│       ├── MenuBarManager.swift      # NSStatusItem management, NSMenu building
│       └── SettingsView.swift        # SwiftUI Settings scene (Phase 2)
└── Tests/
    └── SwifterBarTests/
        ├── OutputParserTests.swift
        ├── PluginManagerTests.swift
        └── ScriptRunnerTests.swift
```

### Technology Stack

| Component | Choice | Rationale |
|-----------|--------|-----------|
| Swift | 6.2 | Default MainActor isolation, `@concurrent`, approachable concurrency |
| macOS target | 26 (Tahoe) | Liquid Glass free, latest APIs, no backwards-compat baggage |
| Menu bar | `NSStatusItem` + SwiftUI views | `MenuBarExtra` still lacks right-click, programmatic control |
| Script execution | `swift-subprocess` | First-party, async/await native, replaces `Foundation.Process` |
| File monitoring | `DispatchSource` | Simple, reliable for watching plugin directory |
| State management | `@Observable` | Property-level tracking, no Combine needed |
| Concurrency | MainActor default + `@concurrent` | Swift 6.2 approachable concurrency model |
| Distribution | Outside App Store | Sandbox incompatible with running arbitrary scripts |
| Dependencies | `swift-subprocess` only | Everything else is platform SDK |

### Key Design Decisions

**NSStatusItem over MenuBarExtra**: MenuBarExtra still can't handle right-click, has no programmatic control over presentation, and `SettingsLink` is broken in that context. We wrap `NSStatusItem` in a thin Swift layer and use SwiftUI for the settings window.

**NSStatusItem lifecycle rules** (prevents SwiftBar #442, #458):

- **Always set `autosaveName`** before any visibility changes — this is required for position persistence
- **Never toggle `isVisible`** — it deletes position data from UserDefaults. Instead, hide/show the button contents
- **Hold strong references in a stable `[PluginID: NSStatusItem]` dictionary** — never replace the container, only insert/remove. If the reference goes out of scope, the item vanishes
- **When disabling a plugin**, explicitly call `NSStatusBar.system.removeStatusItem(_:)` before dropping the reference. Do not rely on deinit
- **macOS 26 complication**: Tahoe adds per-app "Allow in Menu Bar" toggles in System Settings. Users can system-disable your items. No API to detect this.

**Plugin model — struct + enum, not protocol hierarchy**:

```swift
enum PluginKind {
    case executable(interval: Duration)
    case streamable
}

struct Plugin: Identifiable {
    let id: String
    let name: String
    let path: URL
    let kind: PluginKind
    var state: PluginState
    var lastOutput: [ParsedMenuItem]
    var error: PluginError?
}
```

**Zero third-party dependencies** (except `swift-subprocess` which is first-party Apple):
- Cron → simple interval parsing from filename
- Preferences → SwiftUI `Settings` scene
- Sparkle → manual updates / GitHub releases initially
- HotKey → dropped for now

**Single metadata format**: Only support `<swiftbar.key>value</swiftbar.key>` comment-based metadata. Drop BitBar compatibility layer. Simple, one parser. Only scan the first 8KB of a script file for metadata tags.

**Opening Settings from menu bar** (notoriously broken — working pattern per Peter Steinberger, 2025):

1. Declare a hidden `Window` scene BEFORE the `Settings` scene (required for environment propagation on Sequoia+)
2. Use `NotificationCenter` to decouple menu action from SwiftUI context
3. Toggle activation policy: `.accessory` → `.regular` when settings opens, revert on close
4. Use `NSApp.activate(ignoringOtherApps: true)` to bring the window to front

Set `LSUIElement = YES` in Info.plist for dock-icon-less operation.

**@Observable state management**:

```swift
@Observable
final class AppState {
    var plugins: [String: Plugin] = [:]
    var pluginDirectory: URL = URL.homeDirectory.appending(path: "SwifterBar")
    var isEnabled: Bool = true
}
```

- Own with `@State` in the App struct, inject via `.environment(appState)`
- In child views: `@Environment(AppState.self) private var appState`, then `@Bindable var appState = appState` for writable bindings
- Bridge to AppKit via `withObservationTracking` for NSStatusItem updates
- For UserDefaults persistence: use `@ObservationIgnored` with manual `access`/`withMutation` calls

### Concurrency Model

The architecture review flagged that the plan didn't specify where non-MainActor work happens:

- **MainActor (default)**: All UI code, AppState mutations, NSStatusItem/NSMenu manipulation
- **`@concurrent`**: `ScriptRunner.execute()`, `OutputParser.parse()`, Base64 image decoding
- **DispatchSource**: Directory watcher fires on a dispatch queue, bridges to MainActor via `Task { @MainActor in ... }`

Flow: Timer fires (main) → dispatch to `@concurrent` (script execution + output parsing + image decoding) → return parsed result to main → rebuild NSMenu.

## Security

The security review identified that this app's core premise (executing arbitrary scripts) requires explicit hardening even without a sandbox.

### Shell Injection Prevention (CRITICAL)

The `bash=` parameter is the highest-risk feature. SwiftBar had a known shell injection flaw.

**Rule: Never construct shell command strings.** Use `swift-subprocess` with an explicit argument array:

```swift
// SAFE: arguments passed as argv, no shell interpretation
let result = try await Subprocess.run(
    .path(executablePath),
    arguments: [param1, param2],
    output: .string
)

// DANGEROUS: string interpolation into shell command
// let result = try await Subprocess.run(.path("/bin/bash"), arguments: ["-c", "echo \(userInput)"])
```

When running plugin scripts via a shell, pass user data as positional parameters after `--`:
```swift
try await Subprocess.run(
    .path("/bin/bash"),
    arguments: ["-c", "echo \"$1\"", "--", userInput],
    output: .string
)
```

### Input Validation Requirements

| Input | Validation |
|-------|-----------|
| Plugin output lines | Max 4KB per line, max 500 lines, strip null bytes |
| Metadata tags | Only scan first 8KB of script file |
| Numeric params (`size=`, `length=`) | Clamp to sane ranges (font: 1-200) |
| `image=` (Base64) | Max 1MB decoded size, max 1024x1024 dimensions |
| `href=` URLs | Allowlist schemes: `http://`, `https://` only |
| `bash=` executable | Require absolute path, validate exists and is executable |
| Interval from filename | Min 5 seconds, max 24 hours |
| Plugin files | Must be owned by current user, must have execute bit, resolve symlinks |

### Plugin Directory Safety

On startup, validate:
- `~/SwifterBar/` is not world-writable or group-writable
- Each script is owned by the current user
- Symlinks are resolved and validated (reject if target is outside plugin directory)

### Environment Hygiene

Construct a minimal environment for plugins instead of inheriting everything:
```swift
environment: .custom([
    "PATH": resolvedPath,        // /opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin
    "HOME": home,
    "USER": user,
    "SHELL": shell,
    "LANG": "en_US.UTF-8",
    "SWIFTERBAR_PLUGIN_PATH": pluginPath,
    "SWIFTERBAR_PLUGIN_CACHE_PATH": cachePath,
    "SWIFTERBAR_PLUGIN_DATA_PATH": dataPath,
    "SWIFTERBAR_REFRESH_REASON": reason,
    "SWIFTERBAR_OS_APPEARANCE": appearance,
])
```

## Performance

### Process Spawning

- **Resolve shell environment once at startup, cache it.** Pass the resolved env dictionary to every subprocess. This saves 50-100ms per execution on machines with heavy `.zshrc` files.
- **Stagger plugin execution.** On startup, spread initial runs: plugin N starts at `N * (interval / pluginCount)` offset. Prevents CPU spikes.
- **Guard against concurrent execution.** If a script takes longer than its interval, skip the next tick. Simple `isRunning` flag.
- **Enforce minimum 5-second interval.** Prevents CPU/battery abuse.

### swift-subprocess Patterns

```swift
// Executable plugin: run and collect output
@concurrent
func execute(plugin: Plugin, environment: [String: String]) async throws -> String {
    var platformOptions = PlatformOptions()
    platformOptions.teardownSequence = [
        .sendSignal(.terminate, allowedDurationToNextStep: .seconds(2)),
        .sendSignal(.kill, allowedDurationToNextStep: .seconds(1)),
    ]

    let result = try await Subprocess.run(
        .path(plugin.path.path()),
        environment: .custom(environment),
        platformOptions: platformOptions,
        output: .string(limit: 256 * 1024)  // 256KB max output
    )
    return result.standardOutput  // NOTE: does NOT throw on non-zero exit
}

// Streamable plugin: use Subprocess.run(.path(...), output: .sequence) { execution in ... }
// Read execution.standardOutput as AsyncSequence, split on ~~~ separators, keep only latest block
```

**Timeout implementation** — race subprocess against a timer via `withThrowingTaskGroup`:
```swift
try await withThrowingTaskGroup(of: String.self) { group in
    group.addTask { try await self.execute(plugin: plugin, environment: env) }
    group.addTask { try await Task.sleep(for: .seconds(30)); throw TimeoutError() }
    let result = try await group.next()!
    group.cancelAll()  // triggers teardownSequence on the subprocess
    return result
}
```

### NSStatusItem Memory Management

Prevents SwiftBar #477 (memory leak):

- **Never use SwiftUI `NSHostingView` inside `NSMenuItem`** for the main menu — it leaks (FB7539293, still unfixed). Use pure AppKit `NSMenuItem` with `.title`, `.image`, `.action`.
- **If SwiftUI is needed in menu items later**: keep persistent `NSHostingView` instances and update `.rootView`, never recreate
- **Use `NSCache` for decoded images**: keyed by Base64 string hash, `countLimit` of 100. Decode off main thread.
- **Set `NSMenuItem.target` explicitly** — if nil, AppKit walks the responder chain unpredictably

### Memory Projections

| Scenario | Plugins | Avg Interval | Spawns/sec | Memory Est. |
|----------|---------|-------------|------------|-------------|
| Light | 5 | 30s | 0.17 | 15-20MB |
| Target | 10 | 10s avg | 1.0 | 30-40MB |
| Heavy | 20 | 5s avg | 4.0 | 50-70MB |

### Timer Efficiency

Use `DispatchSource.makeTimerSource` with a `leeway` parameter (1 second) to let the system coalesce timer fires for power efficiency.

## Implementation Phases

### Phase 1: Foundation (MVP)

Core plugin execution with menu bar display. **This is the only phase that matters for launch.**

- [x] **SwifterBarApp.swift** — Entry point, `@Observable` AppState, `LSUIElement` for menu-bar-only, `NSApplicationDelegateAdaptor` for AppKit lifecycle
- [x] **Plugin.swift** — `Plugin` struct with `PluginKind` enum (`.executable(interval:)`, `.streamable`), `PluginState` enum (`.idle`, `.running`, `.error`), `PluginError` enum
- [x] **PluginManager.swift** — Scan plugin directory, discover plugins by filename pattern (`name.5s.sh`), `DispatchSource` directory watching with 500ms debounce, plugin lifecycle (start/stop/refresh), guard against concurrent execution of same plugin
- [x] **ScriptRunner.swift** — `swift-subprocess` wrapper, shell environment resolution (cached at startup), timeout via TaskGroup, `@concurrent` execution, teardown sequence (SIGTERM → SIGKILL)
- [x] **OutputParser.swift** — Parse header/body/`---` separators/parameters into `[ParsedMenuItem]`, input validation (max line length, max lines, null byte rejection)
- [x] **MenuBarManager.swift** — Create `NSStatusItem` per plugin (with `autosaveName`), build `NSMenu` from `[ParsedMenuItem]`, handle basic parameters (`color=`, `href=`, `bash=`, `refresh=true`, `sfimage=`), right-click context menu (Open Plugin Folder, Refresh All, Quit), strong reference dictionary keyed by plugin ID, `alwaysVisible` support
**Acceptance criteria**: Can place a script in `~/SwifterBar/`, see its output in menu bar, auto-refresh on interval, basic styling works. Right-click any plugin's menu bar item → Open Plugin Folder, Refresh All, Quit.

Security validations are distributed: PluginManager validates directory/file permissions, ScriptRunner sanitizes arguments and enforces timeouts, OutputParser enforces size limits and strips null bytes, MenuBarManager validates URLs and image sizes.

**No Settings window in Phase 1.** Configuration is the plugin folder path (default `~/SwifterBar/`) and plugin filenames. No SwiftUI workarounds needed yet.

### Phase 2: Rich Features

**Only after Phase 1 ships and you have real-world feedback.**

- [ ] **StreamablePlugin** — Long-running process with `~~~` separators, async output via `swift-subprocess` streaming, max 64KB per output block, rate limiting
- [ ] **Full styling** — `font=`, `size=`, `image=` (base64 with size validation), `templateImage=`, dark/light alternate colors
- [ ] **Nested menu items** — Indentation-based submenu hierarchy
- [ ] **Plugin metadata** — Parse `<swiftbar.*>` tags from script comments (first 8KB only)
- [ ] **Plugin environment** — Minimal `SWIFTERBAR_*` env vars (not full shell inheritance)
- [ ] **Disabled state fix** — Respect `color=` on non-actionable items (use no-op action)
- [ ] **Launch at login** — `ServiceManagement` framework
- [ ] **SettingsView.swift** — SwiftUI Settings scene with hidden Window workaround, plugin folder picker, enable/disable toggles, tabbed Form

**Acceptance criteria**: Existing SwiftBar plugins (that use supported features) work without modification. Settings window opens from right-click menu.

### Phase 3: Only If Users Request It

- [ ] **Plugin variables** — `<swiftbar.var.NAME>default</swiftbar.var.NAME>` metadata, GUI editor in settings
- [ ] **Plugin error UI** — Dedicated error display in dropdown, execution metrics (avg/p95 time per plugin)
- [ ] **Plugin reordering** — Drag to reorder status items, persist order
- [ ] **Global pause mode** — Suspend all timers (useful on battery/presenting)

## System-Wide Impact

- **Interaction graph**: Plugin refresh → ScriptRunner executes (`@concurrent`) → output parsed (`@concurrent`) → result sent to MainActor → MenuBarManager rebuilds NSMenu. Settings changes → PluginManager reloads → plugins restart. Directory watcher fires on dispatch queue → debounced 500ms → bridges to MainActor → PluginManager rescans.
- **Error propagation**: `swift-subprocess` errors caught → `PluginError` enum set on plugin → `PluginState.error` → Menu bar shows error indicator → Error details in dropdown menu. Non-zero exit codes are NOT exceptions — must check `.terminationStatus.isSuccess`. Timeouts handled via TaskGroup racing with `Task.sleep`.
- **State lifecycle risks**: Plugin directory changes during refresh could orphan status items. Mitigate with serial access to the plugin dictionary on MainActor. When disabling: explicitly `removeStatusItem` before dropping reference.
- **API surface parity**: Single interface — menu bar + settings window. No URL schemes, no web API, no shortcuts integration.
- **macOS 26 risk**: New per-app "Allow in Menu Bar" system toggle can hide items without app knowledge. `isVisible` still returns `true`. No workaround — document for users.

## Acceptance Criteria

- [ ] Scripts in plugin folder appear as menu bar items with their output
- [ ] Executable plugins refresh on their configured interval
- [ ] Menu item parameters (color, font, image, actions) work correctly
- [ ] App works reliably on macOS 26 Tahoe
- [ ] Status items don't disappear or reorder unexpectedly (SwiftBar #442, #458)
- [ ] App does not leak memory on menu rebuilds (SwiftBar #477)
- [ ] `bash=` actions use argv arrays, never shell string interpolation
- [ ] Plugin output validated (size limits, null bytes rejected)
- [ ] `href=` only opens http/https URLs
- [ ] Base64 images capped at 1MB decoded / 1024x1024 pixels
- [ ] Test coverage on OutputParser, PluginManager, and ScriptRunner
- [ ] Clean, readable codebase — target ~1500-2000 lines for Phase 1

## Success Metrics

- Existing SwiftBar executable plugins work without modification (supported parameter subset)
- App uses <30MB memory with 10 active plugins (pure AppKit menus, no SwiftUI hosting leak)
- Plugin refresh completes in <100ms for typical scripts
- 6 source files for Phase 1, 7 with Settings in Phase 2. Single SPM target

## Dependencies & Risks

| Risk | Mitigation |
|------|-----------|
| `swift-subprocess` API changes | Pin to stable Swift 6.2 toolchain. Package is `from: "0.1.0"`. |
| macOS 26 beta instability | Develop on macOS 15, test on 26 beta |
| NSStatusItem deprecation | Unlikely — Apple's own apps use it. Monitor WWDC |
| Plugin compatibility expectations | Document supported parameters clearly, don't promise 100% SwiftBar compat |
| Liquid Glass visual changes | Comes free with recompile — test that menus look right |
| macOS 26 "Allow in Menu Bar" toggle | Document for users. No API to detect system-suppression. |
| NSHostingView memory leaks (FB7539293) | Use pure AppKit NSMenuItem for menus, avoid NSHostingView |
| SettingsLink broken in menu bar context | Use hidden Window scene + NotificationCenter + activation policy workaround |
| Shell env differences (launchd vs interactive) | Resolve PATH once at startup, construct minimal env for plugins |

## Sources & References

### SwiftBar Analysis
- [swiftbar/SwiftBar](https://github.com/swiftbar/SwiftBar) — Source repo analyzed
- Key issues: #442 (disappearing items, 9+ reactions), #440 (app hanging), #458 (position instability), #465 (disabled state colors), #467 (menu reuse), #469 (plugin vars), #477 (memory leak)
- Key PRs: #472 (xbar.var support), #463 (tab stops), #476 (memory leak fix), #461 (stdin for streamable)

### Swift & macOS APIs
- [Swift 6.2 Released](https://www.swift.org/blog/swift-6.2-released/) — Approachable concurrency, default MainActor
- [swift-subprocess GitHub](https://github.com/swiftlang/swift-subprocess) — Modern process execution
- [SF-0007 Subprocess Proposal](https://github.com/swiftlang/swift-foundation/blob/main/Proposals/0007-swift-subprocess.md) — Full API spec
- [Embracing Swift Concurrency - WWDC25](https://developer.apple.com/videos/play/wwdc2025/268/)
- [@Observable guide](https://www.avanderlee.com/swiftui/observable-macro-performance-increase-observableobject/)
- [UserDefaults and Observation](https://fatbobman.com/en/posts/userdefaults-and-observation/) — @Observable + UserDefaults pattern

### NSStatusItem & Menu Bar
- [FB7539293: NSHostingView NSMenuItem leak](https://github.com/feedback-assistant/reports/issues/84) — Still unfixed macOS 15.4
- [FB9052637: isVisible deletes position](https://github.com/feedback-assistant/reports/issues/200) — Never toggle isVisible
- [CursorMeter: 13MB AppKit menu bar app](https://dev.to/woojinahn/a-13mb-cursor-monitor-appkit-undocumented-apis-zero-dependencies-1k72) — Pure AppKit vs SwiftUI memory comparison
- [Jesse Squires: NSStatusItem right-click](https://www.jessesquires.com/blog/2019/08/16/workaround-highlight-bug-nsstatusitem/) — Right-click pattern
- [Maccy: menubar icon missing on Tahoe](https://github.com/p0deje/Maccy/issues/1224) — macOS 26 per-app toggle issue

### Design Decisions
- [MenuBarExtraAccess](https://github.com/orchetect/MenuBarExtraAccess) — Evaluated, decided against (prefer direct NSStatusItem)
- [Showing Settings from Menu Bar Items](https://steipete.me/posts/2025/showing-settings-from-macos-menu-bar-items) — The definitive guide to the SettingsLink workaround
- [SettingsAccess library](https://github.com/orchetect/SettingsAccess) — Alternative workaround (evaluated, prefer manual approach)
- [MenuBarExtra docs](https://developer.apple.com/documentation/SwiftUI/MenuBarExtra) — Limitations documented
