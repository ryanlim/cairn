# cairn iOS app — common operations.
#
# All targets are thin wrappers around xcodegen + bundle exec fastlane so
# the day-to-day commands stay short and discoverable. Run `make help` to
# see what's available.

.PHONY: help install generate open clean test build beta metadata release setup-certs sync-certs screenshots export-wordmark device device-run device-list device-logs sim-run sim-seed

# Bundle identifier — must match PRODUCT_BUNDLE_IDENTIFIER in project.yml.
BUNDLE_ID := app.cairn.ios

# First connected iPhone/iPad, or pass DEVICE=<name-or-UDID> to override.
# Parses `xcrun devicectl list devices`, restricted to iPhone/iPad rows
# tagged "connected" or "available (paired)" so an Apple Watch / Apple TV
# in the same list isn't picked first by lexical accident.
DEVICE ?= $(shell xcrun devicectl list devices 2>/dev/null | grep -E '(iPhone|iPad)' | grep -E 'connected|available \(paired\)' | grep -oE '[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}' | head -1)

# Apple Developer Team ID used for code signing. `project.yml` leaves this
# blank so the YAML stays repo-portable; each developer supplies their own
# via (in priority order):
#   1. DEVELOPMENT_TEAM env var, or
#   2. iOS/.team (single-line file, gitignored), or
#   3. ~/.cairn-team (for multi-repo convenience).
# First match wins; empty → the device target errors with instructions.
DEVELOPMENT_TEAM ?= $(shell cat .team 2>/dev/null || cat $(HOME)/.cairn-team 2>/dev/null)
DEVELOPMENT_TEAM := $(strip $(DEVELOPMENT_TEAM))

# Dev-only Immich credentials seeded into the app's Keychain on first
# launch (when Keychain is empty — normal case after a reinstall). Two-
# line format, gitignored:
#
#     url=https://your-immich.example.com
#     key=abc123xyz
#
# Forwarded into the app via `devicectl`'s DEVICECTL_CHILD_* pass-through
# and only honored in DEBUG builds. If the file is missing, `make device`
# proceeds without seeding and the app shows onboarding as usual.
DEV_SEED_URL := $(shell sed -n 's/^url=//p' .dev-secrets 2>/dev/null | head -1)
DEV_SEED_KEY := $(shell sed -n 's/^key=//p' .dev-secrets 2>/dev/null | head -1)

# When the target device runs a public/developer iOS beta, the matching
# Developer Disk Image only ships with the corresponding Xcode beta —
# the release Xcode's DDI rejects newer-OS installs with a misleading
# "Developer Mode is disabled" error. Auto-pick the newest installed
# `Xcode-*-beta*.app` so `device` / `device-run` use it; sim and CI
# targets stay on the user's selected Xcode. Override with
# DEVICE_XCODE=/Applications/Xcode.app to force the release toolchain.
DEVICE_XCODE ?= $(lastword $(sort $(wildcard /Applications/Xcode-*-beta*.app)))
ifneq ($(DEVICE_XCODE),)
DEVICE_DEVELOPER_DIR := DEVELOPER_DIR=$(DEVICE_XCODE)/Contents/Developer
else
DEVICE_DEVELOPER_DIR :=
endif

help:           ## Show this help.
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-18s\033[0m %s\n", $$1, $$2}'

install:       ## Install dependencies (xcodegen + fastlane gems).
	@which xcodegen > /dev/null || brew install xcodegen
	@# Bundler version drift: if the running `bundle` doesn't match the
	@# version embedded in installed gemspecs, `bundle install` errors with
	@# "running version of Bundler does not match the version of the
	@# specification installed for it." Update bundler first to dodge this.
	gem install bundler --no-document --conservative
	bundle config set --local path 'vendor/bundle'
	bundle install

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

metadata:      ## Push App Store listing metadata + screenshots to ASC (no rebuild). Use after `make beta` to populate description/keywords/screenshots without copy-pasting.
	bundle exec fastlane metadata

release:       ## Build + upload to App Store.
	bundle exec fastlane release

setup-certs:   ## First-time match setup (creates certs in your match repo).
	bundle exec fastlane setup_certificates

sync-certs:    ## Sync certs from match repo (read-only — for CI / fresh machines).
	bundle exec fastlane sync_certificates

screenshots:   ## Capture App Store screenshots at 1320×2868 (Apple's 6.9" iPhone tier). Uses fixtures, no Immich needed. Pass DEVICES="iPhone 17 Pro Max,iPhone 17" to add smaller-iPhone tiers.
	./scripts/capture-screenshots.sh

export-wordmark: ## Render the hero "cairn" wordmark (mark + text) to docs/brand/cairn-wordmark.png at 3× retina.
	./scripts/export-wordmark.sh

device-list:   ## List connected iOS devices and their pairing status.
	@xcrun devicectl list devices

device: generate  ## Build + install + launch Debug build on a real device (DEVICE=<name-or-UDID> to pick; CAP=100 caps first-sync hashing for testing).
	@if [ -z "$(DEVICE)" ]; then \
		echo "❌ No paired device found. Connect an iPhone via USB (or pair over Wi-Fi), trust this Mac, then run 'make device-list' to verify."; \
		exit 1; \
	fi
	@if [ -z "$(DEVELOPMENT_TEAM)" ]; then \
		echo "❌ Development team ID not set. Find yours at developer.apple.com → Account → Membership, then pick one:"; \
		echo "   • echo 'ABC1234XYZ' > iOS/.team      (per-repo, gitignored)"; \
		echo "   • echo 'ABC1234XYZ' > ~/.cairn-team  (global)"; \
		echo "   • DEVELOPMENT_TEAM=ABC1234XYZ make device"; \
		exit 1; \
	fi
	@echo "📱 Building for device $(DEVICE) with team $(DEVELOPMENT_TEAM)"
	@if [ -n "$(DEVICE_XCODE)" ]; then echo "🧪 Using $(DEVICE_XCODE) for DDI compatibility (override with DEVICE_XCODE=...)."; fi
	@$(DEVICE_DEVELOPER_DIR) xcodebuild -project Cairn.xcodeproj \
		-scheme Cairn \
		-configuration Debug \
		-destination 'generic/platform=iOS' \
		-derivedDataPath build/device \
		CODE_SIGN_STYLE=Automatic \
		DEVELOPMENT_TEAM=$(DEVELOPMENT_TEAM) \
		build
	@$(DEVICE_DEVELOPER_DIR) xcrun devicectl device install app --device "$(DEVICE)" build/device/Build/Products/Debug-iphoneos/Cairn.app
	@# `DEVICECTL_CHILD_*` env vars are forwarded by devicectl to the
	@# launched app as (unprefixed) env vars. We use this for two things:
	@#   1. `CAIRN_ASSET_CAP` — cap first-sync hashing at N assets for
	@#      timing experiments against real camera rolls. Pass CAP=100.
	@#   2. `CAIRN_DEV_SEED_URL` / `CAIRN_DEV_SEED_KEY` — auto-populate
	@#      the Keychain on launches where it's empty (the common case
	@#      after each reinstall, since iOS wipes Keychain items when the
	@#      provisioning profile regenerates). Read from iOS/.dev-secrets
	@#      (two lines: `url=...` and `key=...`, gitignored).
	@# The seed is honored only in DEBUG builds; release builds ignore
	@# these env vars regardless.
	@DEVICECTL_CHILD_CAIRN_ASSET_CAP=$(CAP) \
		DEVICECTL_CHILD_CAIRN_DEV_SEED_URL="$(DEV_SEED_URL)" \
		DEVICECTL_CHILD_CAIRN_DEV_SEED_KEY="$(DEV_SEED_KEY)" \
		DEVICECTL_CHILD_CAIRN_RESET=$(RESET) \
		$(DEVICE_DEVELOPER_DIR) xcrun devicectl device process launch --device "$(DEVICE)" $(BUNDLE_ID)
	@echo "✅ Launched on device. First install? Trust cert on device: Settings → General → VPN & Device Management."
	@if [ -z "$(DEV_SEED_URL)" ] || [ -z "$(DEV_SEED_KEY)" ]; then \
		echo "💡 Tip: create iOS/.dev-secrets with two lines (url=... / key=...) to skip onboarding on future installs."; \
	fi
	@if [ "$(RESET)" = "1" ]; then \
		echo "⚠️  RESET=1: hash cache, token, ever-seen, and confirmed-deleted state wiped on this launch."; \
	fi

device-run: generate  ## Like `make device` but attaches the app's stdout/stderr to this terminal. Best for watching [cairn.hash] timing logs live. `RESET=1` wipes indexed state on launch for clean timing runs.
	@if [ -z "$(DEVICE)" ]; then \
		echo "❌ No paired device. Run 'make device-list' to check."; exit 1; \
	fi
	@if [ -z "$(DEVELOPMENT_TEAM)" ]; then \
		echo "❌ DEVELOPMENT_TEAM not set. See 'make device' for setup."; exit 1; \
	fi
	@echo "📱 Building + deploying to $(DEVICE) with console attached"
	@if [ -n "$(DEVICE_XCODE)" ]; then echo "🧪 Using $(DEVICE_XCODE) for DDI compatibility (override with DEVICE_XCODE=...)."; fi
	@$(DEVICE_DEVELOPER_DIR) xcodebuild -project Cairn.xcodeproj \
		-scheme Cairn \
		-configuration Debug \
		-destination 'generic/platform=iOS' \
		-derivedDataPath build/device \
		CODE_SIGN_STYLE=Automatic \
		DEVELOPMENT_TEAM=$(DEVELOPMENT_TEAM) \
		build
	@$(DEVICE_DEVELOPER_DIR) xcrun devicectl device install app --device "$(DEVICE)" build/device/Build/Products/Debug-iphoneos/Cairn.app
	@echo "ℹ️  Attaching — app stdout/stderr will stream below. Ctrl-C to detach."
	@if [ "$(RESET)" = "1" ]; then \
		echo "⚠️  RESET=1: hash cache, token, ever-seen, and confirmed-deleted state wiped on this launch."; \
	fi
	@DEVICECTL_CHILD_CAIRN_ASSET_CAP=$(CAP) \
		DEVICECTL_CHILD_CAIRN_DEV_SEED_URL="$(DEV_SEED_URL)" \
		DEVICECTL_CHILD_CAIRN_DEV_SEED_KEY="$(DEV_SEED_KEY)" \
		DEVICECTL_CHILD_CAIRN_RESET=$(RESET) \
		$(DEVICE_DEVELOPER_DIR) xcrun devicectl device process launch --console --device "$(DEVICE)" $(BUNDLE_ID)

device-logs:   ## Open macOS Console.app pre-positioned for device logs. `make device-run` is usually better for timing experiments.
	@open -a Console
	@echo "ℹ️  In Console.app: pick your device in the sidebar, then filter by 'subsystem:app.cairn.ios' to see the structured hash perf logs."

# Simulator support — uses the booted sim or SIM=<name> to pick.
SIM ?= $(shell xcrun simctl list devices booted -j 2>/dev/null | python3 -c "import sys,json; ds=json.load(sys.stdin)['devices']; udids=[d['udid'] for v in ds.values() for d in v if d['state']=='Booted']; print(udids[0] if udids else '')" 2>/dev/null)

sim-seed:      ## Add 500 test photos to the booted simulator. SIM=<udid> to pick.
	@if [ -z "$(SIM)" ]; then echo "❌ No booted simulator. Boot one first."; exit 1; fi
	@echo "🖼  Generating 500 test images…"
	@python3 -c "\
	import struct, zlib, os, random; random.seed(42); os.makedirs('/tmp/cairn-sim-photos', exist_ok=True); \
	[open(f'/tmp/cairn-sim-photos/test_{i:04d}.png','wb').write( \
	  b'\x89PNG\r\n\x1a\n' + \
	  (lambda d: struct.pack('>I',len(d)) + b'IHDR' + d + struct.pack('>I',zlib.crc32(b'IHDR'+d)&0xffffffff))(struct.pack('>IIBBBBB',200,200,8,2,0,0,0)) + \
	  (lambda d: struct.pack('>I',len(d)) + b'IDAT' + d + struct.pack('>I',zlib.crc32(b'IDAT'+d)&0xffffffff))(zlib.compress(b''.join(b'\x00'+bytes([random.randint(30,255),random.randint(30,255),random.randint(30,255)])*200 for _ in range(200)))) + \
	  struct.pack('>I',0) + b'IEND' + struct.pack('>I',zlib.crc32(b'IEND')&0xffffffff) \
	) for i in range(500)]"
	@echo "📲 Adding to simulator $(SIM)…"
	@xcrun simctl addmedia "$(SIM)" /tmp/cairn-sim-photos/*.png
	@echo "✅ 500 test photos added."

sim-run: generate  ## Build + run on the booted simulator with console output. SIM=<udid> to pick. RESET=1 wipes state. CAP=N caps hashing.
	@if [ -z "$(SIM)" ]; then echo "❌ No booted simulator. Boot one first."; exit 1; fi
	@echo "📱 Building for simulator $(SIM)"
	@xcodebuild -project Cairn.xcodeproj \
		-scheme Cairn \
		-configuration Debug \
		-sdk iphonesimulator \
		-destination "id=$(SIM)" \
		-derivedDataPath build/sim \
		CODE_SIGNING_ALLOWED=NO \
		build
	@xcrun simctl install "$(SIM)" build/sim/Build/Products/Debug-iphonesimulator/Cairn.app
	@echo "ℹ️  Launching with console attached. Ctrl-C to stop."
	@SIMCTL_CHILD_CAIRN_ASSET_CAP=$(CAP) \
		SIMCTL_CHILD_CAIRN_DEV_SEED_URL="$(DEV_SEED_URL)" \
		SIMCTL_CHILD_CAIRN_DEV_SEED_KEY="$(DEV_SEED_KEY)" \
		SIMCTL_CHILD_CAIRN_RESET=$(RESET) \
		xcrun simctl launch --console-pty "$(SIM)" $(BUNDLE_ID)
