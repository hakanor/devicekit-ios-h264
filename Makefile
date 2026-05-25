PROJECT = devicekit.h264.xcodeproj
SCHEME = devicekit.h264
BUILD_DIR = build
ARCHIVE_PATH = $(BUILD_DIR)/$(SCHEME).xcarchive
EXPORT_PATH = $(BUILD_DIR)/export

CONFIGURATION ?= Release

.PHONY: help clean ipa-unsigned lint

.DEFAULT_GOAL := help

help:
	@echo "Available targets:"
	@echo "  ipa-unsigned   Build unsigned IPA for real iOS devices"
	@echo "  lint           Run SwiftLint"
	@echo "  clean          Remove build artifacts"

clean:
	rm -rf $(BUILD_DIR)
	xcodebuild clean -project $(PROJECT) -scheme $(SCHEME) -configuration $(CONFIGURATION)

ipa-unsigned:
	@echo "Archiving $(SCHEME) (unsigned)..."
	xcodebuild archive \
		-project $(PROJECT) \
		-scheme $(SCHEME) \
		-configuration $(CONFIGURATION) \
		-destination 'generic/platform=iOS' \
		-archivePath $(ARCHIVE_PATH) \
		CODE_SIGN_IDENTITY="" \
		CODE_SIGNING_REQUIRED=NO \
		CODE_SIGNING_ALLOWED=NO | xcbeautify
	@echo "Packaging IPA..."
	@rm -rf $(EXPORT_PATH)
	@mkdir -p $(EXPORT_PATH)/Payload
	@cp -r "$(ARCHIVE_PATH)/Products/Applications/$(SCHEME).app" $(EXPORT_PATH)/Payload/
	@cd $(EXPORT_PATH) && zip -r $(SCHEME).ipa Payload
	@rm -rf $(EXPORT_PATH)/Payload
	@echo "IPA created at: $(EXPORT_PATH)/$(SCHEME).ipa"

lint:
	@echo "Running SwiftLint..."
	swiftlint lint --strict
