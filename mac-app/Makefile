.PHONY: all clean run install

APP_NAME = Bridge.app
CONTENTS = $(APP_NAME)/Contents
MACOS = $(CONTENTS)/MacOS
RESOURCES = $(CONTENTS)/Resources

SWIFT_SOURCES = Sources/main.swift Sources/BridgeServer.swift Sources/BridgeModel.swift Sources/BridgeMenuView.swift

all: $(APP_NAME)

$(APP_NAME): $(SWIFT_SOURCES) Info.plist
	@mkdir -p $(MACOS) $(RESOURCES)
	@cp Info.plist $(CONTENTS)/Info.plist
	@cp -R Resources/* $(RESOURCES)/ 2>/dev/null || true
	swiftc $(SWIFT_SOURCES) -o $(MACOS)/Bridge -framework AppKit -framework SwiftUI -framework Network -framework CryptoKit -framework CoreImage -framework CoreText -framework UserNotifications -O
	@xattr -cr $(APP_NAME) 2>/dev/null || true
	@codesign --force --deep --sign - $(APP_NAME) 2>/dev/null || true
	@swift -e 'import AppKit; if let img = NSImage(contentsOfFile: "Resources/Bridge.icns") { NSWorkspace.shared.setIcon(img, forFile: "Bridge.app", options: []) }' 2>/dev/null || true
	@/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f $(APP_NAME) 2>/dev/null || true
	@echo "Built $(APP_NAME) successfully!"

run: $(APP_NAME)
	@killall Bridge 2>/dev/null || true
	@killall ClipboardSyncDaemon 2>/dev/null || true
	@sleep 0.4
	open /Applications/$(APP_NAME) 2>/dev/null || open $(APP_NAME)
	@echo "Bridge is running in your Mac menu bar!"

install: $(APP_NAME)
	@rm -rf /Applications/$(APP_NAME)
	@cp -R $(APP_NAME) /Applications/
	@xattr -cr /Applications/$(APP_NAME) 2>/dev/null || true
	@codesign --force --deep --sign - /Applications/$(APP_NAME) 2>/dev/null || true
	@swift -e 'import AppKit; if let img = NSImage(contentsOfFile: "Resources/Bridge.icns") { NSWorkspace.shared.setIcon(img, forFile: "/Applications/Bridge.app", options: []) }' 2>/dev/null || true
	@/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/$(APP_NAME) 2>/dev/null || true
	@touch /Applications/$(APP_NAME)
	@echo "Installed Bridge to /Applications/Bridge.app"

clean:
	rm -rf $(APP_NAME)
