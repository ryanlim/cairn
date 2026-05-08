#!/usr/bin/env bash
# curate-screenshots.sh — pick the App Store upload set from the
# full screenshot output.
#
# `capture-screenshots.sh` produces ~17 PNGs covering every screen
# in both appearances plus a 5-stage demo walkthrough. App Store
# Connect uploads everything in fastlane/screenshots/<lang>/ and
# accepts up to 10 per device, so without curation the upload set
# is whatever sorts first by filename — which is not what we want
# to show on the listing.
#
# This script picks the 4 we actually want to ship, in alternating
# Light/Dark, and copies them to fastlane/upload-screenshots/<lang>/.
# The Fastfile's `metadata` lane reads from that directory, so the
# uncurated working set in `screenshots/` stays available for design
# review without leaking into the listing.
#
# Order on the App Store listing (1-indexed):
#   1. Status         — Light  (the hero screen; Light Mode is the
#                                default appearance most users see)
#   2. PendingReview  — Dark   (alternation begins)
#   3. Runs           — Light
#   4. Settings       — Dark
#
# Edit the SOURCES array to swap Light↔Dark or change the order. The
# numeric prefix in the destination filename controls upload order.

set -euo pipefail

cd "$(dirname "$0")/.."   # land in iOS/

LANG_DIR="en-US"
DEVICE="${DEVICE:-iPhone 17 Pro Max}"
SRC="fastlane/screenshots/${LANG_DIR}"
DST="fastlane/upload-screenshots/${LANG_DIR}"

mkdir -p "$DST"
# Wipe any prior upload set so a curation change doesn't leave
# stragglers that ASC would still upload.
rm -f "$DST/${DEVICE}-"*.png

# Source files (Light / Dark) → desired destination order.
declare -a SOURCES=(
  "01-Status-Light:01-Status"
  "02-PendingReview-Dark:02-PendingReview"
  "03-Runs-Light:03-Runs"
  "04-Settings-Dark:04-Settings"
)

for entry in "${SOURCES[@]}"; do
  src_name="${entry%%:*}"
  dst_name="${entry##*:}"
  src_path="$SRC/${DEVICE}-${src_name}.png"
  dst_path="$DST/${DEVICE}-${dst_name}.png"

  if [[ ! -f "$src_path" ]]; then
    echo "❌ missing: $src_path" >&2
    echo "   run ./scripts/capture-screenshots.sh first" >&2
    exit 1
  fi

  cp "$src_path" "$dst_path"
  echo "→ ${DEVICE}-${dst_name}.png  (from ${src_name})"
done

echo "✅ curated 4 screenshots → $DST"
