PRODUCT := NativeTrajectory
BUILD_DIR := build
DIST_DIR := dist
SOURCES := src/IL2CPPBridge.mm src/NativeTrajectory.mm src/Overlay.mm
HEADERS := src/Geometry.hpp src/IL2CPPBridge.hpp src/NativeTrajectoryProbe.hpp
IOS_MIN := 13.0

.PHONY: all test dylib package clean

all: test dylib

test:
	@mkdir -p $(BUILD_DIR)
	python3 tests/source_contract_tests.py
	xcrun clang++ -std=c++17 -Wall -Wextra -Werror tests/geometry_tests.cpp -o $(BUILD_DIR)/geometry_tests
	$(BUILD_DIR)/geometry_tests

dylib: $(SOURCES) $(HEADERS)
	@mkdir -p $(BUILD_DIR)
	xcrun --sdk iphoneos clang++ \
		-arch arm64 \
		-isysroot "$$(xcrun --sdk iphoneos --show-sdk-path)" \
		-miphoneos-version-min=$(IOS_MIN) \
		-std=c++17 -stdlib=libc++ -fobjc-arc -fblocks \
		-O2 -fvisibility=hidden -Wall -Wextra \
		-dynamiclib $(SOURCES) \
		-framework Foundation -framework UIKit -framework QuartzCore -framework CoreGraphics \
		-Wl,-dead_strip -Wl,-install_name,@rpath/$(PRODUCT).dylib \
		-o $(BUILD_DIR)/$(PRODUCT).dylib
	codesign --force --sign - $(BUILD_DIR)/$(PRODUCT).dylib
	file $(BUILD_DIR)/$(PRODUCT).dylib
	codesign -dvv $(BUILD_DIR)/$(PRODUCT).dylib

package: all
	@rm -rf $(DIST_DIR)
	@mkdir -p $(DIST_DIR)
	cp $(BUILD_DIR)/$(PRODUCT).dylib $(DIST_DIR)/
	shasum -a 256 $(DIST_DIR)/$(PRODUCT).dylib > $(DIST_DIR)/SHA256SUMS.txt
	cp README.md $(DIST_DIR)/README.md
	cp RELEASE_NOTES_0.1.0.md $(DIST_DIR)/RELEASE_NOTES_0.1.0.md
	cd $(DIST_DIR) && zip -9 $(PRODUCT)-arm64.zip $(PRODUCT).dylib SHA256SUMS.txt README.md RELEASE_NOTES_0.1.0.md

clean:
	rm -rf $(BUILD_DIR) $(DIST_DIR)
