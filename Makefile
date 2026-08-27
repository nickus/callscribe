APP      := build/CallScribe.app
BUNDLE_ID := com.slavayus.callscribe
KEYCHAIN  := $(HOME)/Library/Keychains/callscribe-signing.keychain-db
# Sign by the identity's SHA-1 hash, not its name: "CallScribe Dev" can appear
# in more than one keychain and codesign-by-name is ambiguous across them.
IDENTITY_HASH := $(shell security find-identity -p codesigning "$(KEYCHAIN)" 2>/dev/null | awk '/CallScribe Dev/{print $$2; exit}')

# The CommandLineTools toolchain ships Testing.framework outside the default
# search paths; swift test needs them spelled out (not needed for swift build).
DEVDIR     := $(shell xcode-select -p)/Library/Developer
TEST_FLAGS := -Xswiftc -F$(DEVDIR)/Frameworks \
              -Xlinker -F$(DEVDIR)/Frameworks \
              -Xlinker -rpath -Xlinker $(DEVDIR)/Frameworks \
              -Xlinker -rpath -Xlinker $(DEVDIR)/usr/lib

.PHONY: build app run install test lint golden cert clean icon

build:
	swift build -c release

# Regenerate the app icon (Support/AppIcon.icns) from the native drawing script.
icon:
	swift scripts/make-icon.swift

app: build
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp .build/release/callscribe $(APP)/Contents/MacOS/callscribe
	cp Support/Info.plist $(APP)/Contents/Info.plist
	cp Support/AppIcon.icns $(APP)/Contents/Resources/AppIcon.icns
	find $(APP) -name '*.cstemp' -delete 2>/dev/null || true
	@test -n "$(IDENTITY_HASH)" || { echo "No 'CallScribe Dev' identity — run 'make cert' first."; exit 1; }
	codesign --force --sign "$(IDENTITY_HASH)" --keychain "$(KEYCHAIN)" \
	  --identifier $(BUNDLE_ID) $(APP)

run: app
	open $(APP)

install: app
	mkdir -p ~/Applications
	rm -rf ~/Applications/CallScribe.app
	cp -R $(APP) ~/Applications/CallScribe.app

# Strict: every warning fails. Config in .swiftlint.yml.
lint:
	@command -v swiftlint >/dev/null || { echo "swiftlint not installed — brew install swiftlint"; exit 1; }
	swiftlint lint --quiet --strict

test: lint
	swift test $(TEST_FLAGS)

golden:
	CALLSCRIBE_GOLDEN=1 swift test $(TEST_FLAGS) --filter GoldenPipelineTests

cert:
	scripts/make-cert.sh

clean:
	rm -rf build .build
