# cairn iOS app — common operations.
#
# All targets are thin wrappers around xcodegen + bundle exec fastlane so
# the day-to-day commands stay short and discoverable. Run `make help` to
# see what's available.

.PHONY: help install generate open clean test build beta release setup-certs sync-certs

help:           ## Show this help.
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-18s\033[0m %s\n", $$1, $$2}'

install:       ## Install dependencies (xcodegen + fastlane gems).
	@which xcodegen > /dev/null || brew install xcodegen
	bundle install --path vendor/bundle

generate:      ## Regenerate Cairn.xcodeproj from project.yml.
	xcodegen generate
	@echo "✅ Cairn.xcodeproj regenerated"

open: generate ## Regenerate and open the project in Xcode.
	open Cairn.xcodeproj

clean:         ## Remove generated project + build artifacts.
	rm -rf Cairn.xcodeproj build/ vendor/bundle

test:          ## Run all Swift Package tests (CairnCore + CairnIOSCore).
	cd .. && swift test

build:         ## Build a release IPA via fastlane.
	bundle exec fastlane build

beta:          ## Build + upload to TestFlight.
	bundle exec fastlane beta

release:       ## Build + upload to App Store.
	bundle exec fastlane release

setup-certs:   ## First-time match setup (creates certs in your match repo).
	bundle exec fastlane setup_certificates

sync-certs:    ## Sync certs from match repo (read-only — for CI / fresh machines).
	bundle exec fastlane sync_certificates
