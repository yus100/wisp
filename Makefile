APP_NAME := Wisp
BUNDLE_ID := com.yus100.wisp
BUILD_DIR := .build/release
APP := build/$(APP_NAME).app
INSTALL_DIR := $(HOME)/Applications

.PHONY: all build app install run stop clean

all: app

build:
	swift build -c release

app: build
	rm -rf "$(APP)"
	mkdir -p "$(APP)/Contents/MacOS" "$(APP)/Contents/Resources"
	cp "$(BUILD_DIR)/$(APP_NAME)" "$(APP)/Contents/MacOS/$(APP_NAME)"
	cp Resources/Info.plist "$(APP)/Contents/Info.plist"
	cp Resources/ghostty-grok "$(APP)/Contents/Resources/ghostty-grok"
	chmod +x "$(APP)/Contents/Resources/ghostty-grok"
	# Ad-hoc signature with a designated requirement on the bundle ID only, so macOS privacy grants
	# (microphone, files, Ghostty automation) survive rebuilds instead of being tied to one binary hash.
	codesign --force --sign - --identifier $(BUNDLE_ID) \
		-r='designated => identifier "$(BUNDLE_ID)"' "$(APP)"
	@echo "Built $(APP)"

stop:
	-@pkill -x $(APP_NAME) 2>/dev/null; sleep 0.5

install: app stop
	mkdir -p "$(INSTALL_DIR)"
	rm -rf "$(INSTALL_DIR)/$(APP_NAME).app"
	cp -R "$(APP)" "$(INSTALL_DIR)/"
	open "$(INSTALL_DIR)/$(APP_NAME).app"
	@echo "Installed to $(INSTALL_DIR)/$(APP_NAME).app"

run: app stop
	open "$(APP)"

clean:
	rm -rf .build build
