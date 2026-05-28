#!/bin/bash
# Aggregate per-build TestFlight changelogs between two refs into a
# release-notes draft. Each "Bump to build N" commit checkpoints the
# build's `iOS/fastlane/beta_changelog.txt`; this script walks those
# commits in range and concatenates each snapshot with a header so
# you can group the result by theme and paste it into App Store
# release notes.
#
# Usage:
#   scripts/release-notes.sh <from-ref> [to-ref]
#
# Examples:
#   scripts/release-notes.sh v0.3.0          # v0.3.0..HEAD
#   scripts/release-notes.sh v0.3.0 v0.3.1   # v0.3.0..v0.3.1
#
# Output goes to stdout. Pipe to a file, or to pbcopy:
#   scripts/release-notes.sh v0.3.0 | pbcopy

set -euo pipefail

if [[ $# -lt 1 ]]; then
    echo "usage: $(basename "$0") <from-ref> [to-ref]" >&2
    exit 2
fi

FROM="$1"
TO="${2:-HEAD}"
CHANGELOG_PATH="iOS/fastlane/beta_changelog.txt"

# Validate refs early — git's "unknown revision" message is fine but
# the resulting empty log is silent, which is worse.
git rev-parse --verify "$FROM" >/dev/null 2>&1 || { echo "error: unknown ref '$FROM'" >&2; exit 1; }
git rev-parse --verify "$TO" >/dev/null 2>&1   || { echo "error: unknown ref '$TO'"   >&2; exit 1; }

# List build-bump commits, oldest → newest. Tolerates both subject
# conventions observed in the history:
#   "Bump to build N (...)"   — builds 56+
#   "Bump build to N (...)"   — builds 49-55, pre-convention-shift
# Marketing-version bumps ("Bump marketing version to X.Y.Z") are
# deliberately excluded — they're not per-build entries.
COMMITS=$(git log --reverse "${FROM}..${TO}" --extended-regexp \
    --grep='^Bump (to )?build (to )?[0-9]+' \
    --format='%H|%ad|%s' --date=short)

if [[ -z "$COMMITS" ]]; then
    echo "# No 'Bump to build N' commits between $FROM and $TO." >&2
    exit 0
fi

# Header.
printf '# Release notes draft — %s..%s\n' "$FROM" "$TO"
printf '# Generated %s. Hand-edit / group by theme before pasting into App Store release notes.\n\n' "$(date '+%Y-%m-%d')"

# Walk each bump commit and dump its beta_changelog snapshot.
while IFS='|' read -r sha date subject; do
    # Extract the build number out of the subject for the section
    # header. Handles both "Bump to build N" and "Bump build to N".
    # Falls back to the full subject if neither matches (defensive
    # — should always match given the grep above).
    if [[ "$subject" =~ ^Bump\ (to\ )?build\ (to\ )?([0-9]+) ]]; then
        build="${BASH_REMATCH[3]}"
        header="## Build $build — $date"
    else
        header="## $subject — $date"
    fi

    printf '%s\n\n' "$header"
    # `git show <sha>:<path>` resurrects the file as it existed in
    # that commit. If the path didn't exist there (unlikely — every
    # bump touches the changelog), fall back to a placeholder.
    if git show "$sha:$CHANGELOG_PATH" 2>/dev/null; then
        :
    else
        printf '(no beta_changelog.txt in this commit)\n'
    fi
    printf '\n'
done <<< "$COMMITS"
