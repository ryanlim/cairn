#!/usr/bin/env bash
# export-wordmark.sh — render the cairn hero wordmark (mark + "cairn"
# text, with the app's real Fira Code font) to a PNG under
# docs/brand/cairn-wordmark.png.
#
# Runs the app with `-CAIRN_RENDER_WORDMARK 1`, which short-circuits
# the normal root view and instead uses SwiftUI's `ImageRenderer` to
# rasterise `CairnWordmark(variant: .hero)` at 3× retina, writing the
# PNG into the app's Documents directory. This script then copies it
# out of the simulator container and into the repo.
#
# Bypasses the UITest pipeline because the wordmark is a static
# visual — no navigation, no state, no need for a full XCUITest
# bundle. Straight ImageRenderer → PNG is faster and the output is
# pixel-exact to what the app would draw on a real iPhone.

set -euo pipefail

cd "$(dirname "$0")/.."  # iOS/

# Optional env overrides:
#   DEST=<path>          Output PNG path (default: ../docs/brand/cairn-wordmark.png)
#   APPEARANCE=light|dark  Simulator UI mode at render time (default: light).
#                          Use `dark` to produce the GitHub-dark-mode variant
#                          (text renders via `t.text` which resolves to a
#                          light foreground under the dark palette).
DEST="${DEST:-../docs/brand/cairn-wordmark.png}"
APPEARANCE="${APPEARANCE:-light}"
BUNDLE_ID="app.cairn.ios"
SIM_NAME="${SIM_NAME:-iPhone 17 Pro Max}"
DERIVED="/tmp/cairn-wordmark-dd"

echo "→ Regenerating Xcode project…"
xcodegen generate > /dev/null

# Resolve simulator by name, boot if not booted.
UDID=$(xcrun simctl list devices available -j | python3 -c "
import json, sys
name = '$SIM_NAME'
data = json.load(sys.stdin)
for _, devices in data.get('devices', {}).items():
    for d in devices:
        if d.get('name') == name and d.get('isAvailable', False):
            print(d['udid']); break
    else:
        continue
    break
")

if [[ -z "$UDID" ]]; then
  echo "✗ No available simulator named '$SIM_NAME'"; exit 1
fi

xcrun simctl boot "$UDID" 2>/dev/null || true
# Set the simulator UI appearance before installing the app so
# SwiftUI resolves cairnTokens against the requested color scheme
# when ImageRenderer rasterises the wordmark.
xcrun simctl ui "$UDID" appearance "$APPEARANCE"

echo "→ Building for $SIM_NAME ($UDID)…"
xcodebuild -project Cairn.xcodeproj -scheme Cairn \
  -configuration Debug \
  -destination "platform=iOS Simulator,id=$UDID" \
  -derivedDataPath "$DERIVED" \
  build -quiet

APP="$DERIVED/Build/Products/Debug-iphonesimulator/Cairn.app"
xcrun simctl terminate "$UDID" "$BUNDLE_ID" 2>/dev/null || true
xcrun simctl uninstall "$UDID" "$BUNDLE_ID" 2>/dev/null || true
xcrun simctl install "$UDID" "$APP"

echo "→ Launching in wordmark-export mode (appearance=$APPEARANCE)…"
LAUNCH_ARGS=(-CAIRN_RENDER_WORDMARK 1)
if [[ "$APPEARANCE" == "dark" ]]; then
  # ImageRenderer doesn't pick up the system color scheme; force it
  # explicitly inside the rendered view tree.
  LAUNCH_ARGS+=(-CAIRN_WORDMARK_DARK 1)
fi
xcrun simctl launch "$UDID" "$BUNDLE_ID" "${LAUNCH_ARGS[@]}" > /dev/null

# The app writes to its Documents dir once ImageRenderer completes.
# Poll with short backoff; fail out after ~15s so we don't hang.
echo "→ Waiting for PNG…"
CONTAINER=$(xcrun simctl get_app_container "$UDID" "$BUNDLE_ID" data)
for i in {1..30}; do
  if [[ -f "$CONTAINER/Documents/cairn-wordmark.png" ]]; then
    mkdir -p "$(dirname "$DEST")"
    cp "$CONTAINER/Documents/cairn-wordmark.png" "$DEST"
    echo "✓ Wrote $DEST ($(wc -c < "$DEST") bytes)"
    xcrun simctl terminate "$UDID" "$BUNDLE_ID" 2>/dev/null || true
    exit 0
  fi
  sleep 0.5
done

echo "✗ Timeout — no PNG found at $CONTAINER/Documents/cairn-wordmark.png"
exit 1
