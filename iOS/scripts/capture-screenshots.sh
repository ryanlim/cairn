#!/usr/bin/env bash
# capture-screenshots.sh — drive Fastlane's SnapshotHelper UITest via
# xcodebuild directly, bypassing `fastlane snapshot`'s simulator
# resolution. Apple's `simctl list devices` reports runtime builds
# with a short version label ("iOS 26.4") that doesn't always match
# what `xcodebuild -showdestinations` wants ("OS:26.4.1"). Fastlane
# snapshot builds its `-destination` from simctl, xcodebuild rejects
# it, and the test never runs. This script resolves each device by
# UDID so the destination is unambiguous.
#
# Output lands in `fastlane/screenshots/en-US/<device>-<name>.png`
# — identical layout to what fastlane would produce, so downstream
# consumers (README references, App Store Connect upload) don't
# need to change.
#
# Usage:
#   ./scripts/capture-screenshots.sh                    # all devices
#   ./scripts/capture-screenshots.sh "iPhone 17"        # one device
#   DEVICES="iPhone 17 Pro Max" ./scripts/capture-screenshots.sh

set -euo pipefail

cd "$(dirname "$0")/.."   # land in iOS/

# Devices to capture on. Comma-separated in DEVICES env var, or
# positional args, or the default list below.
if [[ -n "${DEVICES:-}" ]]; then
  IFS=',' read -ra DEVICE_LIST <<< "$DEVICES"
elif [[ $# -gt 0 ]]; then
  DEVICE_LIST=("$@")
else
  DEVICE_LIST=(
    "iPhone 17 Pro Max"
    "iPhone 17"
  )
fi

SCHEME="Cairn"
PROJECT="Cairn.xcodeproj"
# Narrow or override with TEST_FILTER env var. The default runs the
# whole screenshots test class; for smoke testing a single shot
# (fastest turnaround), pass TEST_FILTER=CairnUITests/ScreenshotsUITests/testOnboardingScreenshot.
TEST_FILTER="${TEST_FILTER:-CairnUITests/ScreenshotsUITests}"
LOCALE="en-US"
OUT_DIR="fastlane/screenshots/$LOCALE"
CACHE_DIR="$HOME/Library/Caches/tools.fastlane/screenshots"

echo "→ Regenerating Xcode project…"
xcodegen generate > /dev/null

echo "→ Preparing output: $OUT_DIR"
rm -rf "fastlane/screenshots"
mkdir -p "$OUT_DIR"

# SnapshotHelper writes to CACHE_DIR without creating parent dirs —
# it `print`s a silent error and drops the screenshot if the path
# doesn't exist. Ensure a clean + present dir before each run.
rm -rf "$CACHE_DIR"
mkdir -p "$CACHE_DIR"

for DEVICE in "${DEVICE_LIST[@]}"; do
  echo
  echo "=== $DEVICE ==="

  # Resolve UDID of an *available* simulator with this name. Picks
  # the first match — if there's more than one, that's a user config
  # issue (duplicate sims) and they can `xcrun simctl delete` the
  # extras.
  UDID=$(
    xcrun simctl list devices available -j \
      | python3 -c "
import json, sys
name = '$DEVICE'
data = json.load(sys.stdin)
for _, devices in data.get('devices', {}).items():
    for d in devices:
        if d.get('name') == name and d.get('isAvailable', False):
            print(d['udid']); break
    else:
        continue
    break
"
  )

  if [[ -z "$UDID" ]]; then
    echo "  ⚠  No available simulator named '$DEVICE' — skipping."
    echo "     Available: $(xcrun simctl list devices available | grep -oE '[A-Za-z0-9 ]+\(' | sort -u | head -5 | tr '\n' ',')"
    continue
  fi

  echo "  UDID: $UDID"

  # Boot if needed. `|| true` because `simctl boot` errors when
  # already booted, which is fine for us.
  xcrun simctl boot "$UDID" 2>/dev/null || true

  # Pin the status bar — full battery, full signal, Wi-Fi, 2:37.
  # Matches Apple's Human Interface Guidelines for App Store
  # screenshots and reads as "polished" rather than "my dev sim at
  # 3:12pm." Cleared on script exit via the trap below, so the
  # override doesn't stick around on the user's sim between runs.
  xcrun simctl status_bar "$UDID" override \
    --time "2:37" \
    --dataNetwork wifi \
    --wifiMode active \
    --wifiBars 3 \
    --cellularMode active \
    --cellularBars 4 \
    --batteryState charged \
    --batteryLevel 100 \
    2>/dev/null || true

  # Always clear overrides on exit so the user's sim returns to its
  # real clock / battery state. Re-registered per-device so the trap
  # picks the current UDID if the loop is mid-iteration.
  trap "xcrun simctl status_bar '$UDID' clear 2>/dev/null || true" EXIT

  echo "  Running UI tests (this takes a minute)…"
  xcodebuild test \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -destination "platform=iOS Simulator,id=$UDID" \
    -only-testing:"$TEST_FILTER" \
    -quiet \
    2>&1 | grep -E "Test Case|snapshot:|error:|BUILD SUCCEEDED|BUILD FAILED|\*\* TEST" || true

  # Collect screenshots. SnapshotHelper names them
  # "<device-name>-<snapshot-label>.png" inside CACHE_DIR.
  COUNT=0
  for SHOT in "$CACHE_DIR"/"$DEVICE"-*.png; do
    if [[ -f "$SHOT" ]]; then
      cp "$SHOT" "$OUT_DIR/"
      COUNT=$((COUNT + 1))
    fi
  done
  echo "  ✓ $COUNT screenshot(s) moved to $OUT_DIR/"
done

echo
echo "Done. Screenshots in: $OUT_DIR"
ls -la "$OUT_DIR" 2>&1 | grep -v '^total' | tail -n +2
