NAME := OfflineGuard
BUILD := build
IOS_MIN := 15.0
VERSION ?= dev
export VERSION
DEVELOPER_DIR ?= /Applications/Xcode.app/Contents/Developer
TEST_DEVELOPER_DIR ?= /Library/Developer/CommandLineTools
export DEVELOPER_DIR
SOURCES := Sources/OfflineGuard.m Sources/SocketHooks.c Sources/NetworkStateHooks.m Sources/ReachabilityCallback.m Vendor/fishhook/fishhook.c
VERSION_HEADER := $(BUILD)/generated/BuildVersion.h
HEADERS := Sources/SocketHooks.h Sources/NetworkStateHooks.h Sources/ReachabilityCallback.h Vendor/fishhook/fishhook.h $(VERSION_HEADER)
FLAGS := -O2 -fvisibility=hidden -Wall -Wextra -Werror -Wno-unused-parameter -I Vendor/fishhook -I $(BUILD)/generated
FRAMEWORKS := -framework Foundation -framework Network -framework WebKit -framework SystemConfiguration
SWIFT_SOURCE := Sources/SwiftNetworkState.swift
IOS_OBJECTS := $(addprefix $(BUILD)/ios/,$(addsuffix .o,$(basename $(SOURCES))))
MAC_OBJECTS := $(addprefix $(BUILD)/macos/,$(addsuffix .o,$(basename $(SOURCES))))
IOS_FLAGS = -isysroot "$$(xcrun --sdk iphoneos --show-sdk-path)" -arch arm64 -miphoneos-version-min=$(IOS_MIN)
MAC_XCRUN := DEVELOPER_DIR="$(TEST_DEVELOPER_DIR)" xcrun

.PHONY: all clean test check-ios force-version
all: $(BUILD)/$(NAME).dylib

force-version:

$(VERSION_HEADER): scripts/write-version-header.py force-version
	python3 scripts/write-version-header.py "$@"

check-ios:
	@xcrun --sdk iphoneos --show-sdk-path >/dev/null || { echo 'Install Xcode and accept its license: sudo xcodebuild -license accept'; exit 1; }

$(BUILD):
	mkdir -p $@

$(BUILD)/ios/%.o: %.m $(HEADERS) Makefile | check-ios
	mkdir -p $(dir $@)
	xcrun --sdk iphoneos clang $(FLAGS) $(IOS_FLAGS) -fobjc-arc -c $< -o $@

$(BUILD)/ios/%.o: %.c $(HEADERS) Makefile | check-ios
	mkdir -p $(dir $@)
	xcrun --sdk iphoneos clang $(FLAGS) $(IOS_FLAGS) -c $< -o $@

$(BUILD)/macos/%.o: %.m $(HEADERS) Makefile
	mkdir -p $(dir $@)
	$(MAC_XCRUN) clang $(FLAGS) -fobjc-arc -c $< -o $@

$(BUILD)/macos/%.o: %.c $(HEADERS) Makefile
	mkdir -p $(dir $@)
	$(MAC_XCRUN) clang $(FLAGS) -c $< -o $@

$(BUILD)/$(NAME).dylib: $(IOS_OBJECTS) $(SWIFT_SOURCE) Makefile | $(BUILD) check-ios
	xcrun --sdk iphoneos swiftc -O -emit-library -module-name OfflineGuard -sdk "$$(xcrun --sdk iphoneos --show-sdk-path)" -target arm64-apple-ios$(IOS_MIN) $(SWIFT_SOURCE) $(IOS_OBJECTS) $(FRAMEWORKS) -Xlinker -install_name -Xlinker @rpath/$(NAME).dylib -o $@
	codesign --force --sign - $@
	@echo 'Import build/OfflineGuard.dylib into an app-specific LiveContainer tweak folder.'

# Tests default to Command Line Tools; CI can use its selected full Xcode.
$(BUILD)/OfflineGuard-macOS.dylib: $(MAC_OBJECTS) $(SWIFT_SOURCE) Makefile
	$(MAC_XCRUN) swiftc -O -emit-library -module-name OfflineGuard $(SWIFT_SOURCE) $(MAC_OBJECTS) $(FRAMEWORKS) -o $@

test: $(BUILD)/OfflineGuard-macOS.dylib | $(BUILD)
	$(MAC_XCRUN) clang $(FLAGS) -dynamiclib Tests/LateClient.c -o $(BUILD)/LateClient.dylib
	$(MAC_XCRUN) clang $(FLAGS) -fobjc-arc Tests/Integration.m $(FRAMEWORKS) -o $(BUILD)/integration
	$(MAC_XCRUN) clang $(FLAGS) -fobjc-arc Tests/NetworkState.m $(FRAMEWORKS) -o $(BUILD)/network-state
	$(MAC_XCRUN) swiftc Tests/NetworkState.swift -o $(BUILD)/swift-network-state
	$(MAC_XCRUN) clang $(FLAGS) -fobjc-arc Tests/ReachabilityCallbacks.m $(BUILD)/macos/Sources/ReachabilityCallback.o -framework Foundation -framework SystemConfiguration -o $(BUILD)/reachability-callbacks
	./$(BUILD)/integration
	./$(BUILD)/integration --cold
	./$(BUILD)/network-state
	./$(BUILD)/swift-network-state
	./$(BUILD)/reachability-callbacks

clean:
	rm -rf $(BUILD)
