.PHONY: all clean run install dmg

APP_NAME = Bridge.app
DMG_NAME ?= Bridge-macOS.dmg
CONTENTS = $(APP_NAME)/Contents
MACOS = $(CONTENTS)/MacOS
RESOURCES = $(CONTENTS)/Resources
FRAMEWORKS = $(CONTENTS)/Frameworks
PLUGINS = $(CONTENTS)/PlugIns
SHARE_APPEX = $(PLUGINS)/BridgeShare.appex
QUICK_APPEX = $(PLUGINS)/BridgeQuickAction.appex
MRA_DIR = Vendor/mediaremote-adapter
MRA_FW = $(FRAMEWORKS)/MediaRemoteAdapter.framework
MRA_SOURCES = $(wildcard $(MRA_DIR)/src/adapter/*.m $(MRA_DIR)/src/private/*.m $(MRA_DIR)/src/utility/*.m)

# Minimum supported macOS. Without an explicit target, swiftc stamps the binary
# with the build machine's macOS version, which locks out older systems.
MACOS_MIN ?= 13.0
ARCH ?= $(shell uname -m)
SWIFT_TARGET = -target $(ARCH)-apple-macosx$(MACOS_MIN)

SWIFT_SOURCES = Sources/main.swift Sources/BridgeNotificationModels.swift Sources/BridgeFileTransferModels.swift Sources/LaunchAtLoginManager.swift Sources/MacMediaPauser.swift Sources/CallBannerPanelController.swift Sources/MacSystemControlManager.swift Sources/MacMediaControlCLI.swift Sources/MacMediaMonitor.swift Sources/AXNotificationObserver.swift Sources/BridgeNotificationManager.swift Sources/BridgeFileTransferManager.swift Sources/PhoneVideoDecoder.swift Sources/PhoneMirrorManager.swift Sources/PhoneMirrorWindowController.swift Sources/BridgeServer.swift Sources/BridgeModel.swift Sources/BridgeMenuView.swift

all: $(APP_NAME)

$(APP_NAME): $(SWIFT_SOURCES) $(MRA_SOURCES) $(MRA_DIR)/bin/mediaremote-adapter.pl $(MRA_DIR)/FrameworkInfo.plist Info.plist ShareExtension/Info.plist ShareExtension/ShareController.swift ShareExtension/BridgeShare.entitlements QuickActionExtension/Info.plist
	@mkdir -p $(MACOS) $(RESOURCES) $(FRAMEWORKS) $(SHARE_APPEX)/Contents/MacOS $(SHARE_APPEX)/Contents/Resources $(QUICK_APPEX)/Contents/MacOS $(QUICK_APPEX)/Contents/Resources
	@cp Info.plist $(CONTENTS)/Info.plist
	@cp -R Resources/* $(RESOURCES)/ 2>/dev/null || true
	@rm -rf $(RESOURCES)/QuickAction $(RESOURCES)/Bridge.icon $(RESOURCES)/dmg 2>/dev/null || true
	@cp $(MRA_DIR)/bin/mediaremote-adapter.pl $(RESOURCES)/mediaremote-adapter.pl
	@chmod +x $(RESOURCES)/mediaremote-adapter.pl
	@rm -rf $(MRA_FW)
	@mkdir -p $(MRA_FW)/Versions/A/Headers $(MRA_FW)/Versions/A/Resources
	@cp $(MRA_DIR)/include/MediaRemoteAdapter.h $(MRA_FW)/Versions/A/Headers/MediaRemoteAdapter.h
	@cp $(MRA_DIR)/FrameworkInfo.plist $(MRA_FW)/Versions/A/Resources/Info.plist
	clang -fobjc-arc -fvisibility=default -dynamiclib -target $(ARCH)-apple-macosx$(MACOS_MIN) -install_name "@rpath/MediaRemoteAdapter.framework/Versions/A/MediaRemoteAdapter" -I$(MRA_DIR)/include -I$(MRA_DIR)/src -framework Foundation -framework AppKit -framework UniformTypeIdentifiers $(MRA_SOURCES) -o $(MRA_FW)/Versions/A/MediaRemoteAdapter
	@ln -s A $(MRA_FW)/Versions/Current
	@ln -s Versions/Current/MediaRemoteAdapter $(MRA_FW)/MediaRemoteAdapter
	@ln -s Versions/Current/Headers $(MRA_FW)/Headers
	@ln -s Versions/Current/Resources $(MRA_FW)/Resources
	@ACTOOL=$$(xcrun --find actool 2>/dev/null || ls /Applications/Xcode*.app/Contents/Developer/usr/bin/actool 2>/dev/null | head -n 1); \
	if [ -n "$$ACTOOL" ] && [ -d Resources/Bridge.icon ]; then \
		mkdir -p .build-icon; \
		"$$ACTOOL" Resources/Bridge.icon --compile .build-icon --platform macosx --minimum-deployment-target $(MACOS_MIN) --app-icon Bridge --output-partial-info-plist .build-icon/partial.plist >/dev/null 2>&1 && cp .build-icon/Assets.car $(RESOURCES)/Assets.car || true; \
		rm -rf .build-icon; \
	fi
	swiftc $(SWIFT_SOURCES) -o $(MACOS)/Bridge -framework AppKit -framework SwiftUI -framework Network -framework CryptoKit -framework CoreImage -framework CoreText -framework UserNotifications -framework ApplicationServices -framework UniformTypeIdentifiers -framework ServiceManagement -framework CoreAudio -framework AudioToolbox -framework IOKit -framework VideoToolbox -framework CoreMedia $(SWIFT_TARGET) -O
	@cp ShareExtension/Info.plist $(SHARE_APPEX)/Contents/Info.plist
	@cp Resources/Bridge.icns $(SHARE_APPEX)/Contents/Resources/Bridge.icns 2>/dev/null || true
	swiftc ShareExtension/ShareController.swift -module-name BridgeShare -o $(SHARE_APPEX)/Contents/MacOS/BridgeShare -framework AppKit -framework Foundation -framework UniformTypeIdentifiers -Xlinker -e -Xlinker _NSExtensionMain $(SWIFT_TARGET) -O
	@cp QuickActionExtension/Info.plist $(QUICK_APPEX)/Contents/Info.plist
	@cp Resources/Bridge.icns $(QUICK_APPEX)/Contents/Resources/Bridge.icns 2>/dev/null || true
	@cp Resources/MenuBarIcon@2x.png $(QUICK_APPEX)/Contents/Resources/NSActionTemplate.png 2>/dev/null || true
	swiftc ShareExtension/ShareController.swift -module-name BridgeQuickAction -o $(QUICK_APPEX)/Contents/MacOS/BridgeQuickAction -framework AppKit -framework Foundation -framework UniformTypeIdentifiers -Xlinker -e -Xlinker _NSExtensionMain $(SWIFT_TARGET) -O
	@xattr -cr $(APP_NAME) 2>/dev/null || true
	@codesign --force --sign - $(MRA_FW)
	@codesign --force --sign - --entitlements ShareExtension/BridgeShare.entitlements --identifier com.link.bridge.share $(SHARE_APPEX)
	@codesign --force --sign - --entitlements ShareExtension/BridgeShare.entitlements --identifier com.link.bridge.quickaction $(QUICK_APPEX)
	@codesign --force --sign - --identifier com.link.bridge -r='designated => identifier "com.link.bridge"' $(APP_NAME)
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
	@ditto $(APP_NAME) /Applications/$(APP_NAME)
	@xattr -cr /Applications/$(APP_NAME) 2>/dev/null || true
	@codesign --force --sign - /Applications/$(APP_NAME)/Contents/Frameworks/MediaRemoteAdapter.framework
	@codesign --force --sign - --entitlements ShareExtension/BridgeShare.entitlements --identifier com.link.bridge.share /Applications/$(APP_NAME)/Contents/PlugIns/BridgeShare.appex
	@codesign --force --sign - --entitlements ShareExtension/BridgeShare.entitlements --identifier com.link.bridge.quickaction /Applications/$(APP_NAME)/Contents/PlugIns/BridgeQuickAction.appex
	@codesign --force --sign - --identifier com.link.bridge -r='designated => identifier "com.link.bridge"' /Applications/$(APP_NAME)
	@/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/$(APP_NAME) 2>/dev/null || true
	@pluginkit -a /Applications/$(APP_NAME)/Contents/PlugIns/BridgeShare.appex 2>/dev/null || true
	@pluginkit -e use -i com.link.bridge.share 2>/dev/null || true
	@pluginkit -a /Applications/$(APP_NAME)/Contents/PlugIns/BridgeQuickAction.appex 2>/dev/null || true
	@pluginkit -e use -i com.link.bridge.quickaction 2>/dev/null || true
	@python3 -c "import plistlib, os; p=os.path.expanduser('~/Library/Preferences/com.apple.Sharing.plist'); d=plistlib.load(open(p,'rb')) if os.path.exists(p) else {}; ord=d.get('ExtensionsPreferences.ShareMenu.displayOrder',[]); ord.append('com.link.bridge.share') if 'com.link.bridge.share' not in ord else None; d['ExtensionsPreferences.ShareMenu.displayOrder']=ord; plistlib.dump(d,open(p,'wb'))" 2>/dev/null || true
	@killall -HUP sharingd 2>/dev/null || true
	@mkdir -p "$(HOME)/Library/Services/Share with Bridge.workflow/Contents/Resources"
	@cp Resources/QuickAction/Info.plist "$(HOME)/Library/Services/Share with Bridge.workflow/Contents/Info.plist"
	@cp Resources/QuickAction/document.wflow "$(HOME)/Library/Services/Share with Bridge.workflow/Contents/document.wflow"
	@cp Resources/QuickAction/document.wflow "$(HOME)/Library/Services/Share with Bridge.workflow/Contents/Resources/document.wflow"
	@defaults write pbs FinderActive -dict-add "APPEXTENSION-com.link.bridge.quickaction" -bool true 2>/dev/null || true
	@defaults write pbs FinderActive -dict-add "SERVICE-com.link.bridge.workflow - Share with Bridge - runWorkflowAsService" -bool true 2>/dev/null || true
	@/System/Library/CoreServices/pbs -flush 2>/dev/null || true
	@/System/Library/CoreServices/pbs -update 2>/dev/null || true
	@swift -e 'import Foundation; DistributedNotificationCenter.default().postNotificationName(NSNotification.Name("_NSQuickActionConfigurationDidChangeNotification"), object: nil, userInfo: nil, deliverImmediately: true)' 2>/dev/null || true
	@touch /Applications/$(APP_NAME)
	@echo "Installed Bridge to /Applications/Bridge.app and registered Finder right-click Quick Action & Share Extension"

dmg: $(APP_NAME)
	@./scripts/make-dmg.sh "$(APP_NAME)" "$(DMG_NAME)"

clean:
	rm -rf $(APP_NAME) .build-tests .build-icon *.dmg

.PHONY: test
test:
	@mkdir -p .build-tests
	swiftc Tests/BridgeTests.swift Sources/BridgeNotificationModels.swift Sources/BridgeFileTransferModels.swift Sources/LaunchAtLoginManager.swift Sources/MacMediaPauser.swift Sources/CallBannerPanelController.swift Sources/MacSystemControlManager.swift Sources/MacMediaControlCLI.swift Sources/MacMediaMonitor.swift Sources/AXNotificationObserver.swift Sources/BridgeNotificationManager.swift Sources/BridgeFileTransferManager.swift Sources/PhoneVideoDecoder.swift Sources/PhoneMirrorManager.swift Sources/PhoneMirrorWindowController.swift Sources/BridgeServer.swift Sources/BridgeModel.swift Sources/BridgeMenuView.swift -o .build-tests/BridgeTests -framework AppKit -framework SwiftUI -framework Network -framework CryptoKit -framework CoreImage -framework CoreText -framework UserNotifications -framework ApplicationServices -framework UniformTypeIdentifiers -framework ServiceManagement -framework CoreAudio -framework AudioToolbox -framework IOKit -framework VideoToolbox -framework CoreMedia $(SWIFT_TARGET)
	@.build-tests/BridgeTests
	@rm -rf .build-tests
