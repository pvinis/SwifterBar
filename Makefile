.PHONY: build run test clean archive dmg

SCHEME = SwifterBar
PROJECT = SwifterBar.xcodeproj
CONFIG = Release
BUILD_DIR = .build/app
ARCHIVE_PATH = $(BUILD_DIR)/SwifterBar.xcarchive
APP_PATH = $(BUILD_DIR)/SwifterBar.app
DMG_PATH = $(BUILD_DIR)/SwifterBar.dmg

# Build the .app
build:
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration $(CONFIG) \
		-derivedDataPath $(BUILD_DIR)/DerivedData build
	@echo "\n✅ Built: $$(find $(BUILD_DIR)/DerivedData -name 'SwifterBar.app' -maxdepth 5 | head -1)"

# Run the built .app
run: build
	@APP=$$(find $(BUILD_DIR)/DerivedData -name 'SwifterBar.app' -maxdepth 5 | head -1) && \
		open "$$APP"

# Run tests via SPM (faster than xcodebuild)
test:
	swift test

# Archive for distribution
archive:
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration $(CONFIG) \
		-archivePath $(ARCHIVE_PATH) archive
	xcodebuild -exportArchive -archivePath $(ARCHIVE_PATH) \
		-exportPath $(BUILD_DIR) \
		-exportOptionsPlist ExportOptions.plist 2>/dev/null || \
		cp -R "$(ARCHIVE_PATH)/Products/Applications/SwifterBar.app" "$(APP_PATH)"
	@echo "\n✅ Archived: $(APP_PATH)"

# Create DMG for distribution
dmg: archive
	@rm -f $(DMG_PATH)
	hdiutil create -volname "SwifterBar" -srcfolder "$(APP_PATH)" \
		-ov -format UDZO "$(DMG_PATH)"
	@echo "\n✅ DMG: $(DMG_PATH)"

# Clean build artifacts
clean:
	rm -rf $(BUILD_DIR)
	rm -rf ~/Library/Developer/Xcode/DerivedData/SwifterBar-*
	swift package clean

# Regenerate Xcode project from project.yml
generate:
	xcodegen generate
