---
title: "Make SwifterBar a distributable .app"
type: feat
status: active
date: 2026-03-18
---

# Make SwifterBar a distributable .app

## Overview

SwifterBar currently builds as a bare Mach-O binary via `swift build`. It works for development but can't be installed, updated, or distributed properly. This plan covers turning it into a signed, notarized `.app` bundle with Sparkle auto-updates and Homebrew Cask installation.

## Current State

- Pure SPM project, no Xcode project
- `swift build` produces a 1.7MB binary at `.build/release/SwifterBar`
- No Info.plist, no entitlements file, no app icon, no .app bundle
- `LSUIElement` is set at runtime via `NSApp.setActivationPolicy(.accessory)` — works but should also be in Info.plist
- ServiceManagement (Launch at Login) already imported and used

## Proposed Solution

### Approach: Xcode Project wrapping SPM package

Use a minimal Xcode project that references the existing SPM package as a local dependency. This is the standard path for macOS app distribution — it gives full access to Xcode's signing, archiving, and export workflows without restructuring the codebase.

**Why not swift-bundler?** It's a third-party tool that adds a build dependency. Xcode's toolchain is what Apple supports for signing/notarization, and it's what CI runners have pre-installed.

**Why not manual .app script?** Works for simple cases but becomes fragile when you need entitlements, Sparkle framework embedding, and notarization.

### What Changes

| Component | Before | After |
|-----------|--------|-------|
| Build system | `swift build` | `xcodebuild` (Xcode project references Package.swift) |
| Output | Bare binary | `SwifterBar.app` bundle |
| Info.plist | None (runtime only) | Proper plist with LSUIElement, bundle ID, Sparkle keys |
| Icon | None | App icon (icns) |
| Updates | Manual | Sparkle 2 auto-updates |
| Distribution | None | GitHub Releases → Homebrew Cask |
| Signing | None | Developer ID + notarization |

## Implementation Phases

### Phase 1: .app Bundle

Create the Xcode project and produce a working `.app`.

- [x] Create `SwifterBar.xcodeproj` with a macOS App target that depends on the local SPM package
- [x] Add `Info.plist` with: `LSUIElement=true`, `CFBundleIdentifier=com.pvinis.swifterbar`, version strings, `NSHumanReadableCopyright`
- [x] Add app icon (create a simple SF Symbol-based icon or placeholder `.icns`)
- [x] Add entitlements file (hardened runtime for notarization)
- [x] Verify `xcodebuild -scheme SwifterBar -configuration Release build` produces a working `.app`
- [ ] Verify the `.app` launches correctly, shows in menu bar, runs plugins, Settings works
- [x] Add `Makefile` or script: `make build`, `make run`, `make archive`
- [x] Keep `swift build` and `swift test` working for development (no Xcode required for dev/test)

### Phase 2: Sparkle Auto-Updates

Add Sparkle 2 for self-updating.

- [ ] Add Sparkle SPM dependency (`from: "2.8.0"`)
- [ ] Add `SUFeedURL` and `SUPublicEDKey` to Info.plist
- [ ] Generate EdDSA keypair (`generate_keys`), store public key in plist, private key securely
- [ ] Add `SPUStandardUpdaterController` initialization in AppDelegate
- [ ] Add "Check for Updates..." menu item in the context menu
- [ ] Host appcast.xml on GitHub Pages or as a file in the releases repo
- [ ] Add `generate_appcast` step to the release process

### Phase 3: Code Signing, Notarization & CI

Automated build-sign-notarize-release pipeline.

- [ ] Set up Developer ID Application certificate (requires Apple Developer account)
- [x] Create GitHub Actions workflow: build → sign → create DMG → notarize → staple → upload to release
- [ ] Store secrets: `DEVELOPER_ID_CERTIFICATE` (base64), cert password, Apple ID, app-specific password, team ID, Sparkle EdDSA private key
- [x] Use `create-dmg` or `hdiutil` to create a DMG with Applications symlink
- [ ] Auto-generate Sparkle appcast on release
- [x] Tag-based releases: push `v1.0.0` tag → CI builds and publishes

### Phase 4: Homebrew Cask

Make it installable via `brew install --cask swifterbar`.

- [ ] Create `homebrew-swifterbar` repo at `pvinis/homebrew-swifterbar`
- [ ] Write cask formula pointing to GitHub Releases DMG
- [ ] Set `auto_updates true` (Sparkle handles updates)
- [ ] Add `livecheck` block for version tracking
- [ ] Document: `brew tap pvinis/swifterbar && brew install --cask swifterbar`
- [ ] Optionally: auto-update the cask formula in CI when a new release is published

## File Structure After

```
SwifterBar/
├── Package.swift                    # SPM (still works for swift build/test)
├── SwifterBar.xcodeproj/           # Xcode project for .app builds
├── SwifterBar/                     # Xcode target wrapper
│   ├── Info.plist
│   ├── SwifterBar.entitlements
│   └── Assets.xcassets/
│       └── AppIcon.appiconset/
├── Sources/SwifterBar/             # Existing source (unchanged)
├── Tests/SwifterBarTests/          # Existing tests (unchanged)
├── Makefile                        # build, run, archive, dmg
├── .github/workflows/
│   └── release.yml                 # CI: build → sign → notarize → release
├── LICENSE
├── README.md
└── docs/plans/
```

## Acceptance Criteria

- [ ] `xcodebuild` produces a `SwifterBar.app` that launches and works identically to `swift run`
- [ ] `swift build` and `swift test` still work for development
- [ ] App has a proper icon and appears as "SwifterBar" in Activity Monitor
- [ ] LSUIElement in Info.plist — no dock icon
- [ ] Sparkle checks for updates and can install them
- [ ] "Check for Updates..." appears in the right-click context menu
- [ ] GitHub Actions produces a signed, notarized DMG on tag push
- [ ] `brew install --cask swifterbar` installs the app to /Applications
- [ ] App is code-signed with Developer ID and passes `spctl --assess`

## Dependencies & Risks

| Risk | Mitigation |
|------|-----------|
| Apple Developer account required ($99/yr) | Required for distribution — no workaround |
| Xcode project maintenance overhead | Minimal — it just wraps the SPM package, all source stays in Sources/ |
| Sparkle adds a dependency | Sparkle is the standard for macOS auto-updates, well-maintained, SPM-native |
| Notarization can be slow/flaky | `--wait` flag + CI retry logic |
| DMG creation varies across CI | Use `hdiutil` (built into macOS runners) |

## Sources

- [Sparkle 2 Documentation](https://sparkle-project.org/documentation/)
- [Homebrew Cask Cookbook](https://docs.brew.sh/Cask-Cookbook)
- [Apple: Notarizing macOS Software](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
- [Federico Terzi: Code-signing with GitHub Actions](https://federicoterzi.com/blog/automatic-code-signing-and-notarization-for-macos-apps-using-github-actions/)
- [rsms macOS Distribution Guide](https://gist.github.com/rsms/929c9c2fec231f0cf843a1a746a416f5)
- [swift-bundler](https://github.com/stackotter/swift-bundler) — evaluated, decided against (prefer Xcode for signing)
