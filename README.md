# cairn

Reconciles an iOS Photos library against an [Immich](https://immich.app) server: when a photo leaves the local library, cairn moves the matching asset on Immich to trash. That's the whole job.

**Status: Phase 1 CLI prototype.** A Swift Package with a working command-line tool that's been end-to-end validated against a real Immich server. The iOS app (Phase 2) is not yet built.

`cairn` is **not** an official Immich client and is not affiliated with the Immich project. Compatibility only.

## Why

If you use the Immich iOS app to upload photos and rely on the official app's automatic upload, you end up with photos on your server indefinitely — even after you've deleted them from your phone. The Immich app uploads; it doesn't reap. cairn closes that loop, conservatively, with multiple safety layers. It's deliberately narrow:

- No uploads. Let the official app handle that.
- No photo viewing, albums, tags, metadata editing, or AI.
- One job, done carefully.

## How it works

1. **Identity is SHA1 of file content.** Immich's `AssetResponseDto.checksum` is the canonical identifier; everything cairn does is keyed on it.
2. **Client-side "ever-seen" set.** cairn keeps a local persistent set of every SHA1 it has observed on this device. This lets it distinguish "photo the user deleted from their iPhone" from "photo that was never on their iPhone" (e.g. a Mac-only upload).
3. **Reconciliation diff.** A server asset whose checksum is in ever-seen *and* not in the current local set is a delete candidate.
4. **Safety rails** (all layered): trash-never-hard-delete, percent threshold with absolute floor, empty-local-library abort, first-run-must-be-dry-run, sanity check on empty server responses.
5. **Breadcrumb tags on Immich.** Every trash run writes a tag `cairn/v1/run/<run_id>` onto every trashed asset. The tag plus Immich's 30-day trash window form the user-facing undo surface.
6. **Append-only local journal.** A JSONL file records every step of every run (planned, tagged, trashed, restored, failed) for forensics.

See [`immich-ios-deletion-sync-plan.md`](immich-ios-deletion-sync-plan.md) for the full design, including deliberate non-goals and the Phase 1 vs Phase 2 split on Live Photo handling.

## Requirements

- macOS 14 (Sonoma) or later — SwiftData and Swift Testing dependencies.
- Swift 6.0 (Xcode 16 or the command-line toolchain).
- An Immich server you can reach from the machine running cairn.
- An Immich API key scoped to `asset.read`, `asset.delete`, `tag.create`, `tag.asset`, and `tag.read`.

## Setup

1. Clone this repo.
2. Copy `.env.example` to `.env` and fill in your Immich URL and API key.
3. `swift build`.

## Usage

Every subcommand reads `.env` from the current directory by default.

```sh
# Smoke-test connectivity and auth.
swift run cairn verify

# Seed the ever-seen set from a file of base64 SHA1 checksums.
# For the CLI prototype we simulate the iPhone library by dumping the
# server and treating that as "local"; the iOS app will produce this
# file from PhotoKit at runtime.
swift run cairn dump-server-checksums --output ever-seen-seed.txt
swift run cairn dry-run --local-checksums-file ever-seen-seed.txt

# Do the real thing. Refuses to run if ever-seen is empty (forces a
# dry-run first). Prompts for confirmation unless --yes is passed.
swift run cairn trash --local-checksums-file ever-seen-seed.txt

# See what happened locally.
swift run cairn journal list
swift run cairn journal show --last

# See what the server thinks (works across devices, no journal needed).
swift run cairn history list
swift run cairn history show --run-id <id>

# Undo. Three modes: whole run, specific asset IDs, or a filename regex.
swift run cairn restore --run-id <id>
swift run cairn restore --run-id <id> --asset-id <uuid> --asset-id <uuid>
swift run cairn restore --run-id <id> --file-name-matches "IMG_2024.*\\.HEIC"

# Diagnostics across visibility classes (surfaces hidden motion videos etc.).
swift run cairn diagnose
```

Safety flags worth knowing:

- `--max-delete-percent N` — abort if more than N% of in-purview assets would be trashed. Default 1.
- `--min-delete-count-for-threshold N` — the percent rail only fires above this absolute count, so small libraries can delete a few photos without spurious aborts. Default 5.
- `--dry-run` — implicit on `dry-run`; mutating subcommands are explicit.

## Tests

```sh
swift test
```

The test suite exercises the reconciliation algorithm, safety rails, SHA1 hashing, the deletion journal, the trash and restore orchestrators, Immich API client HTTP shape via URLProtocol mocks, and the v1 tag schema.

## Open source vs. App Store

MIT-licensed source here (see [`LICENSE`](LICENSE)). If/when a compiled iOS binary is distributed through TestFlight or the App Store, that binary is released under Apple's usual EULA — MIT doesn't constrain how the compiled artifact is packaged or priced. Users who prefer to build from source always can.

MIT sidesteps the AGPL / App Store friction that affects some GPL-family projects. Immich itself is AGPL-3.0; cairn is a separate client that talks to Immich over its public API, so license compatibility is a non-issue.
