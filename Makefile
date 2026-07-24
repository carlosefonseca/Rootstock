# Rootstock — build and release
#
# `make release VERSION=1.1.0` builds Release, signs with the Developer ID
# identity, notarizes, zips, generates a signed Sparkle appcast, and publishes
# a GitHub release with both as assets. Sparkle's feed URL
# (releases/latest/download/appcast.xml) always resolves to whatever the most
# recent release published, so nothing else needs to change per release.

REPO := carlosefonseca/Rootstock
BUILD_NUMBER := $(shell git rev-list --count HEAD)

APPLE_ID := carlosefonseca@gmail.com
TEAM_ID := VF8BTMF3F4
API_KEY_ID := HPN75M9228
API_ISSUER_ID := 0b909d67-63d6-4bfa-8304-40c75863a34b
API_KEY_PATH := $(HOME)/.appstoreconnect/private_keys/AuthKey_$(API_KEY_ID).p8

SPARKLE_VERSION := 2.9.4
SPARKLE_TOOLS := .sparkle-tools/bin

RELEASE_DIR := build/release
APP_PATH := $(RELEASE_DIR)/Build/Products/Release/Rootstock.app

.PHONY: open build run release sparkle-tools clean

open: ## Opens the project in Xcode.
	xcodegen generate --spec Project.json
	open Rootstock.xcodeproj

build: ## Builds the Debug configuration.
	xcodegen generate --spec Project.json
	xcodebuild -project Rootstock.xcodeproj -scheme Rootstock -configuration Debug build | xcbeautify

run: build ## Builds and launches the Debug build.
	@BUILT_PRODUCTS_DIR=$$(xcodebuild -project Rootstock.xcodeproj -scheme Rootstock -configuration Debug -showBuildSettings | awk -F ' = ' '/ BUILT_PRODUCTS_DIR /{print $$2; exit}'); \
	open "$$BUILT_PRODUCTS_DIR/Rootstock.app"

sparkle-tools: ## Downloads Sparkle's generate_appcast/sign_update CLI tools.
	@if [ ! -x "$(SPARKLE_TOOLS)/generate_appcast" ]; then \
		echo "Downloading Sparkle $(SPARKLE_VERSION) tools..."; \
		mkdir -p .sparkle-tools; \
		curl -sL -o /tmp/sparkle-tools.tar.xz "https://github.com/sparkle-project/Sparkle/releases/download/$(SPARKLE_VERSION)/Sparkle-$(SPARKLE_VERSION).tar.xz"; \
		tar -xf /tmp/sparkle-tools.tar.xz -C .sparkle-tools; \
	fi

# `make release VERSION=1.1.0` (add `PRERELEASE=1` to publish without moving
# the Sparkle "latest" feed — existing installs won't be offered the update)
GH_PRERELEASE_FLAG := $(if $(PRERELEASE),--prerelease,)

release: sparkle-tools ## Builds, signs, notarizes, and publishes a GitHub release + Sparkle appcast.
	@test -n "$(VERSION)" || (echo "Usage: make release VERSION=1.1.0"; exit 1)
	@echo "==> Building Rootstock $(VERSION) (build $(BUILD_NUMBER))"
	xcodegen generate --spec Project.json
	rm -rf "$(RELEASE_DIR)"
	xcodebuild -project Rootstock.xcodeproj -scheme Rootstock -configuration Release \
		MARKETING_VERSION=$(VERSION) CURRENT_PROJECT_VERSION=$(BUILD_NUMBER) \
		-derivedDataPath "$(RELEASE_DIR)" build | xcbeautify
	@echo "==> Re-signing deep (Xcode's embed-framework step doesn't re-sign Sparkle's bundled Autoupdate/XPC helpers with our identity, timestamp, or hardened runtime on its own)"
	codesign --force --deep --options runtime --timestamp \
		--sign "Developer ID Application: Carlos Fonseca ($(TEAM_ID))" "$(APP_PATH)"
	codesign --verify --deep --strict --verbose=2 "$(APP_PATH)"
	@echo "==> Notarizing"
	ditto -c -k --keepParent "$(APP_PATH)" "$(RELEASE_DIR)/Rootstock-notarize.zip"
	xcrun notarytool submit "$(RELEASE_DIR)/Rootstock-notarize.zip" \
		--key "$(API_KEY_PATH)" --key-id "$(API_KEY_ID)" --issuer "$(API_ISSUER_ID)" --wait
	xcrun stapler staple "$(APP_PATH)"
	@echo "==> Packaging"
	mkdir -p "$(RELEASE_DIR)/archive"
	ditto -c -k --keepParent "$(APP_PATH)" "$(RELEASE_DIR)/archive/Rootstock-$(VERSION).zip"
	@echo "==> Generating Sparkle appcast"
	$(SPARKLE_TOOLS)/generate_appcast "$(RELEASE_DIR)/archive" \
		--download-url-prefix "https://github.com/$(REPO)/releases/download/v$(VERSION)/"
	@echo "==> Publishing GitHub release v$(VERSION)"
	gh release create "v$(VERSION)" \
		"$(RELEASE_DIR)/archive/Rootstock-$(VERSION).zip" \
		"$(RELEASE_DIR)/archive/appcast.xml" \
		--repo "$(REPO)" --title "Rootstock $(VERSION)" --generate-notes $(GH_PRERELEASE_FLAG)
	@echo "==> Done: https://github.com/$(REPO)/releases/tag/v$(VERSION)"

clean: ## Removes build output.
	rm -rf build Rootstock.xcodeproj
