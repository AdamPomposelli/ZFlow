APP_NAME ?= ZFlow Dev
BUNDLE_ID ?= com.zippy.zflow.dev
BUILD_DIR = build
APP_BUNDLE = $(BUILD_DIR)/$(APP_NAME).app
CODESIGN_IDENTITY ?= ZFlow Dev
CONTENTS = $(APP_BUNDLE)/Contents
MACOS_DIR = $(CONTENTS)/MacOS
empty :=
space := $(empty) $(empty)
APP_EXECUTABLE = $(MACOS_DIR)/$(APP_NAME)
APP_EXECUTABLE_TARGET := $(subst $(space),\ ,$(APP_EXECUTABLE))

SOURCES = $(shell find Sources -name '*.swift' -type f | LC_ALL=C sort)
TEST_RUNNER = $(BUILD_DIR)/ZFlowTests
TEST_PRODUCTION_SOURCES = \
	Sources/AppContextService.swift \
	Sources/AppName.swift \
	Sources/AppPaths.swift \
	Sources/AudioUploadEncoder.swift \
	Sources/AudioSegmentationCore.swift \
	Sources/CleanupPromptCore.swift \
	Sources/ClipboardRestoreCore.swift \
	Sources/CorrectionAdjudicator.swift \
	Sources/EditSettleTracker.swift \
	Sources/DockVisibility.swift \
	Sources/FileTranscriptionCore.swift \
	Sources/HotkeyRecoveryCore.swift \
	Sources/LanguageCatalog.swift \
	Sources/LocaleReservationCore.swift \
	Sources/LearnedCorrectionsCore.swift \
	Sources/CorrectionWatcher.swift \
	Sources/LLMAPITransport.swift \
	Sources/LLMCooldownManager.swift \
	Sources/MeetingSummaryCore.swift \
	Sources/ModelConfiguration.swift \
	Sources/NotetakerCore.swift \
	Sources/PasteTargetCore.swift \
	Sources/PermissionsCore.swift \
	Sources/PipelineMode.swift \
	Sources/TimedTranscriptCore.swift \
	Sources/SavingsCore.swift \
	Sources/SettingsBridgeServer.swift \
	Sources/SpeechAssetGateCore.swift \
	Sources/ToastCountdownCore.swift \
	Sources/UsageStatisticsCore.swift \
	Sources/TranscriptionEngine.swift \
	Sources/TranscriptionErrorPresentationCore.swift \
	Sources/TranscriptionRequestCore.swift \
	Sources/TranscriptionTimeoutCore.swift \
	Sources/TranscriptTextCore.swift \
	Sources/UpdateManager.swift \
	Sources/ShortcutCore/DictationShortcutSessionController.swift \
	Sources/ShortcutCore/ShortcutMatcher.swift \
	Sources/ShortcutCore/ShortcutModels.swift
TEST_SOURCES = $(shell find Tests -name '*.swift' -type f | LC_ALL=C sort)
# Every shell script in the repository, wherever it lives.
SHELL_SCRIPTS = $(shell find . -name '*.sh' -type f -not -path './node_modules/*' -not -path './electron/node_modules/*' -not -path './build/*' | LC_ALL=C sort)
RESOURCES = $(CONTENTS)/Resources
# The Electron settings front end. Built separately by `make ui` and copied
# into Resources when present, so a plain `make` still works without Node.
UI_DIR = electron
UI_APP = $(UI_DIR)/release/ZFlow UI.app
ARCH ?= $(shell uname -m)

# Pick the icon source based on which bundle we are building. Dev builds get
# a distinct hammer-on-waveform icon so a developer's dock shows at a glance
# which ZFlow they are running when both are installed side by side.
ifeq ($(APP_NAME),ZFlow Dev)
ICON_SOURCE = Resources/AppIcon-Dev-Source.png
ICON_ICNS = Resources/AppIcon-Dev.icns
else
ICON_SOURCE = Resources/AppIcon-Source.png
ICON_ICNS = Resources/AppIcon.icns
endif

.PHONY: all check clean run icon dmg codesign-dmg notarize test typecheck validate ui ui-test

all: $(APP_EXECUTABLE_TARGET)

$(APP_EXECUTABLE_TARGET): $(SOURCES) Info.plist $(ICON_ICNS)
	@mkdir -p "$(MACOS_DIR)" "$(RESOURCES)"
ifeq ($(ARCH),universal)
	swiftc \
		-parse-as-library \
		-o "$(MACOS_DIR)/$(APP_NAME)-arm64" \
		-sdk $(shell xcrun --show-sdk-path) \
		-target arm64-apple-macosx13.0 \
		$(SOURCES)
	swiftc \
		-parse-as-library \
		-o "$(MACOS_DIR)/$(APP_NAME)-x86_64" \
		-sdk $(shell xcrun --show-sdk-path) \
		-target x86_64-apple-macosx13.0 \
		$(SOURCES)
	lipo -create -output "$(MACOS_DIR)/$(APP_NAME)" \
		"$(MACOS_DIR)/$(APP_NAME)-arm64" \
		"$(MACOS_DIR)/$(APP_NAME)-x86_64"
	@rm "$(MACOS_DIR)/$(APP_NAME)-arm64" "$(MACOS_DIR)/$(APP_NAME)-x86_64"
else
	swiftc \
		-parse-as-library \
		-o "$(MACOS_DIR)/$(APP_NAME)" \
		-sdk $(shell xcrun --show-sdk-path) \
		-target $(ARCH)-apple-macosx13.0 \
		$(SOURCES)
endif
	@cp Info.plist "$(CONTENTS)/"
	@plutil -replace CFBundleName -string "$(APP_NAME)" "$(CONTENTS)/Info.plist"
	@plutil -replace CFBundleDisplayName -string "$(APP_NAME)" "$(CONTENTS)/Info.plist"
	@plutil -replace CFBundleExecutable -string "$(APP_NAME)" "$(CONTENTS)/Info.plist"
	@plutil -replace CFBundleIdentifier -string "$(BUNDLE_ID)" "$(CONTENTS)/Info.plist"
	@cp $(ICON_ICNS) "$(RESOURCES)/AppIcon.icns"
	@if [ -d "$(UI_APP)" ]; then \
		rm -rf "$(RESOURCES)/ZFlow UI.app"; \
		cp -R "$(UI_APP)" "$(RESOURCES)/ZFlow UI.app"; \
		echo "Bundled $(UI_APP)"; \
	else \
		echo "No settings front end at $(UI_APP) — run 'make ui' to build it"; \
	fi
	@plutil -replace NSMicrophoneUsageDescription -string "$(APP_NAME) needs microphone access to transcribe your speech." "$(CONTENTS)/Info.plist"
	@plutil -replace NSSpeechRecognitionUsageDescription -string "$(APP_NAME) needs speech recognition to convert your voice to text." "$(CONTENTS)/Info.plist"
	@plutil -replace NSAccessibilityUsageDescription -string "$(APP_NAME) needs accessibility access to detect the text cursor position and paste transcribed text." "$(CONTENTS)/Info.plist"
	@codesign --force --options runtime --sign "$(CODESIGN_IDENTITY)" --entitlements ZFlow.entitlements "$(APP_BUNDLE)"
	@echo "Built $(APP_BUNDLE)"

check: typecheck test validate ui-test

typecheck:
	swiftc \
		-parse-as-library \
		-typecheck \
		-warnings-as-errors \
		-sdk $(shell xcrun --show-sdk-path) \
		-target $(ARCH)-apple-macosx13.0 \
		$(SOURCES)

test:
	@mkdir -p "$(BUILD_DIR)"
	swiftc \
		-parse-as-library \
		-warnings-as-errors \
		-o "$(TEST_RUNNER)" \
		-sdk $(shell xcrun --show-sdk-path) \
		-target $(ARCH)-apple-macosx13.0 \
		$(TEST_PRODUCTION_SOURCES) \
		$(TEST_SOURCES)
	@$(TEST_RUNNER)

validate:
	plutil -lint Info.plist ZFlow.entitlements
	@set -e; for script in $(SHELL_SCRIPTS); do bash -n "$$script"; done

# The settings window's own checks: its schema against itself and against
# the components that draw it. Node's built-in runner, no dependency. Needs
# Node 22 or later, which the window needs anyway; skipped with a note where
# it is missing, so `make check` still runs on a machine without Node.
ui-test:
	@if command -v node >/dev/null 2>&1 && node -e 'process.exit(+process.versions.node.split(".")[0] >= 22 ? 0 : 1)'; then \
		cd $(UI_DIR) && node --experimental-strip-types --no-warnings --test tests/*.test.mjs; \
	else \
		echo "ui-test skipped: Node 22 or later is not installed"; \
	fi

# Builds the settings front end. Needs Node; everything else in this Makefile
# does not, which is why this is a separate target rather than a dependency.
ui:
	cd $(UI_DIR) && npm install --no-audit --no-fund && ./scripts/package.sh

icon: $(ICON_ICNS)

$(ICON_ICNS): $(ICON_SOURCE)
	@mkdir -p $(BUILD_DIR)/AppIcon.iconset
	@sips -z 16 16 $< --out $(BUILD_DIR)/AppIcon.iconset/icon_16x16.png > /dev/null
	@sips -z 32 32 $< --out $(BUILD_DIR)/AppIcon.iconset/icon_16x16@2x.png > /dev/null
	@sips -z 32 32 $< --out $(BUILD_DIR)/AppIcon.iconset/icon_32x32.png > /dev/null
	@sips -z 64 64 $< --out $(BUILD_DIR)/AppIcon.iconset/icon_32x32@2x.png > /dev/null
	@sips -z 128 128 $< --out $(BUILD_DIR)/AppIcon.iconset/icon_128x128.png > /dev/null
	@sips -z 256 256 $< --out $(BUILD_DIR)/AppIcon.iconset/icon_128x128@2x.png > /dev/null
	@sips -z 256 256 $< --out $(BUILD_DIR)/AppIcon.iconset/icon_256x256.png > /dev/null
	@sips -z 512 512 $< --out $(BUILD_DIR)/AppIcon.iconset/icon_256x256@2x.png > /dev/null
	@sips -z 512 512 $< --out $(BUILD_DIR)/AppIcon.iconset/icon_512x512.png > /dev/null
	@sips -z 1024 1024 $< --out $(BUILD_DIR)/AppIcon.iconset/icon_512x512@2x.png > /dev/null
	@iconutil -c icns -o $@ $(BUILD_DIR)/AppIcon.iconset
	@rm -rf $(BUILD_DIR)/AppIcon.iconset
	@echo "Generated $@"

dmg: all
	@rm -f "$(BUILD_DIR)/$(APP_NAME).dmg"
	@rm -rf $(BUILD_DIR)/dmg-staging
	@mkdir -p $(BUILD_DIR)/dmg-staging
	@cp -R "$(APP_BUNDLE)" $(BUILD_DIR)/dmg-staging/
	@osascript -e 'tell application "Finder" to make alias file to POSIX file "/Applications" at POSIX file "'"$$(cd $(BUILD_DIR)/dmg-staging && pwd)"'"'
	@ALIAS=$$(find $(BUILD_DIR)/dmg-staging -maxdepth 1 -not -name '*.app' -not -name '.DS_Store' -type f | head -1) && mv "$$ALIAS" "$(BUILD_DIR)/dmg-staging/Applications"
	@fileicon set "$(BUILD_DIR)/dmg-staging/Applications" /System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/ApplicationsFolderIcon.icns
	@echo "Creating DMG..."
	@create-dmg \
		--volname "$(APP_NAME)" \
		--volicon "$(ICON_ICNS)" \
		--background "Resources/dmg-background.tiff" \
		--window-pos 200 120 \
		--window-size 660 400 \
		--icon-size 128 \
		--icon "$(APP_NAME).app" 180 170 \
		--hide-extension "$(APP_NAME).app" \
		--icon "Applications" 480 170 \
		--no-internet-enable \
		"$(BUILD_DIR)/$(APP_NAME).dmg" \
		"$(BUILD_DIR)/dmg-staging"
	@rm -rf $(BUILD_DIR)/dmg-staging
	@echo "Created $(BUILD_DIR)/$(APP_NAME).dmg"

codesign-dmg: dmg
	codesign --force --sign "$(CODESIGN_IDENTITY)" "$(BUILD_DIR)/$(APP_NAME).dmg"

notarize:
	xcrun notarytool submit "$(BUILD_DIR)/$(APP_NAME).dmg" \
		--keychain-profile "$(NOTARIZE_PROFILE)" --wait
	xcrun stapler staple "$(BUILD_DIR)/$(APP_NAME).dmg"

clean:
	rm -rf $(BUILD_DIR)

run: all
	open "$(APP_BUNDLE)"
