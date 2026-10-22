APP_NAME := Wisp
BUNDLE_ID := com.yus100.wisp
# A real identity (security find-identity -p codesigning) lets macOS show Wisp's notifications.
SIGN_IDENTITY ?= -
APP := build/$(APP_NAME).app
INSTALL_DIR := $(HOME)/Applications
SOURCES := Sources Tests Package.swift scripts/make-icon.swift

.PHONY: help build app install uninstall run stop test lint format icon screenshots smoke clean

help: ## List the targets
	@grep -E '^[a-z]+:.*## ' $(MAKEFILE_LIST) | awk -F ':.*## ' '{printf "  make %-10s %s\n", $$1, $$2}'

build: ## Compile a release build
	swift build -c release

app: build ## Assemble and sign build/Wisp.app
	rm -rf "$(APP)"
	mkdir -p "$(APP)/Contents/MacOS" "$(APP)/Contents/Resources"
	cp ".build/release/$(APP_NAME)" "$(APP)/Contents/MacOS/$(APP_NAME)"
	cp Resources/Info.plist "$(APP)/Contents/Info.plist"
	cp Resources/ghostty-grok Resources/AppIcon.icns "$(APP)/Contents/Resources/"
	cp -R .build/release/Wisp_WispRendering.bundle "$(APP)/Contents/Resources/"
	chmod +x "$(APP)/Contents/Resources/ghostty-grok"
	# Signed (ad-hoc by default) with the bundle ID as designated requirement, so macOS privacy grants
	# (microphone, files, Automation) survive rebuilds instead of being tied to one binary hash.
	codesign --force --sign "$(SIGN_IDENTITY)" --identifier $(BUNDLE_ID) \
		-r='designated => identifier "$(BUNDLE_ID)"' "$(APP)"
	@echo "Built $(APP)"

install: app stop ## Install to ~/Applications and launch
	mkdir -p "$(INSTALL_DIR)"
	rm -rf "$(INSTALL_DIR)/$(APP_NAME).app"
	cp -R "$(APP)" "$(INSTALL_DIR)/"
	open "$(INSTALL_DIR)/$(APP_NAME).app"
	@echo "Installed $(INSTALL_DIR)/$(APP_NAME).app"

uninstall: stop ## Quit and remove the app (keeps config, logs, and history)
	rm -rf "$(INSTALL_DIR)/$(APP_NAME).app"

run: app stop ## Launch the freshly built app without installing it
	open "$(APP)"

stop: ## Quit a running Wisp
	-@/usr/bin/pkill -x $(APP_NAME) 2>/dev/null; sleep 0.5

test: ## Run the unit tests
	swift test

lint: ## Check formatting
	swift format lint --strict --recursive $(SOURCES)

format: ## Format the sources in place
	swift format --in-place --recursive $(SOURCES)

icon: ## Redraw Resources/AppIcon.icns and docs/assets/icon.png
	swift scripts/make-icon.swift

screenshots: build ## Render docs/assets/panel.png from sample data (offscreen)
	.build/release/$(APP_NAME) render-screenshots docs/assets

smoke: ## End-to-end check against the installed app (needs "remoteControl": true)
	scripts/smoke-test.sh

clean: ## Remove build products
	rm -rf .build build
