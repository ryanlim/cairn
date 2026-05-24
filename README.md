# cairn

Reconciles your iPhone photo library against your [Immich](https://immich.app) server. When you delete a photo on your phone, `cairn` moves the matching asset on Immich to Trash. That's the whole job.

`cairn` is not affiliated with Immich — it talks to Immich over its public API.

<p align="center">
  <img src="iOS/fastlane/screenshots/en-US/iPhone 17 Pro Max-01-Status-Light.png" width="220" alt="Status screen" />
  &nbsp;&nbsp;
  <img src="iOS/fastlane/screenshots/en-US/iPhone 17 Pro Max-02-PendingReview-Light.png" width="220" alt="Pending Review screen" />
  &nbsp;&nbsp;
  <img src="iOS/fastlane/screenshots/en-US/iPhone 17 Pro Max-05-Setup-Welcome-Light.png" width="220" alt="Setup Welcome screen" />
</p>

<p align="center">
  <a href="https://apps.apple.com/app/id6763392945">
    <img src="https://developer.apple.com/assets/elements/badges/download-on-the-app-store.svg" alt="Download cairn on the App Store" height="48">
  </a>
</p>

## Why

The Immich iOS app uploads; it doesn't reap. If you rely on its automatic upload and delete from your iPhone, the server copy stays forever. `cairn` closes that loop.

It's deliberately narrow:

- No uploads. Use the Immich app for that.
- No viewing, albums, tags, metadata editing, or AI.
- One job, done carefully.

## How it works

1. **Content identity is SHA1.** Immich's `AssetResponseDto.checksum` is the canonical identifier; everything `cairn` does is keyed on it.
2. **Ever-seen set.** `cairn` keeps a local persistent set of every SHA1 it has observed on this device. This distinguishes "photo the user deleted from this iPhone" from "photo that was never on this iPhone" (e.g. a Mac-only upload).
3. **Confirmed-deletion signal.** On iOS, `cairn` subscribes to `PHPhotoLibrary.fetchPersistentChanges(since:)` and gets a direct event when iOS soft-deletes a photo — before the 30-day Recently Deleted purge even starts. That's the positive signal; absence from the current library is the fallback.
4. **Quarantine window.** Confirmed deletions age for a configurable window (default 14 days) before they're eligible to move to Immich's Trash, so an accidental mass-offload has time to be caught.
5. **Safety rails.** Trash-never-hard-delete; percent threshold with an absolute floor; empty-local-library abort; first-run dry-run; sanity check on empty server responses.
6. **Breadcrumb tags.** Every run writes a tag `cairn/v1/run/<run_id>` onto every affected asset on Immich. The tag plus Immich's 30-day Trash retention form the undo surface.
7. **Append-only local journal.** A JSONL file records every step of every run (planned, tagged, trashed, restored, failed) for forensics and restore.

The full design is in [`immich-ios-deletion-sync-plan.md`](immich-ios-deletion-sync-plan.md) — deliberately long, including non-goals, failure modes, and the pivot from Recently-Deleted enumeration to persistent-change events.

## Install

**[App Store](https://apps.apple.com/app/id6763392945).** Current public release.

**From source (iOS app):** see [`iOS/README.md`](iOS/README.md). Short version: Xcode 16+, `make install && make generate`, set your development team in Xcode once, `Cmd-R`.

**From source (CLI):** `swift build && swift run cairn --help`. Works on macOS 14+; talks to any Immich server reachable from your shell.

## CLI

```sh
swift run cairn verify                                   # connectivity + auth check
swift run cairn dump-server-checksums --output ever.txt  # seed for dry-run
swift run cairn dry-run --local-checksums-file ever.txt  # preview, no mutation
swift run cairn trash --local-checksums-file ever.txt    # the real thing; refuses on first ever run
swift run cairn restore --run-id <id>                    # undo, by run / asset / filename pattern
swift run cairn journal list                             # local audit log
swift run cairn history list                             # server-side reconstruction (needs tag.read scope)
swift run cairn diagnose                                 # visibility classes + Live Photo integrity
```

`cairn --help` enumerates every subcommand and flag. API key scopes needed: `asset.read`, `asset.view`, `asset.download`, `asset.delete`, `tag.create`, `tag.asset` — plus `tag.read` for `history` and `restore --file-name-matches`.

## Safety model

`cairn` is destructive-by-intent, so the safety model is the product:

- **Two signals before acting.** "No longer in library" plus "iOS confirmed the deletion" (strict mode) — or the quarantine window alone (trusting mode, default).
- **Preview before confirm.** Every run shows you the candidate list and an Immich-side summary before anything touches the server.
- **Trash, not delete.** `cairn` only calls `DELETE /api/assets {force: false}` — assets land in Immich's Trash with 30 days of retention. Restoration is one tap.
- **Percent cap + floor.** A run that would touch more than N% of matched assets aborts without touching the server, unless the candidate count is below the floor (prevents small-library spurious aborts).
- **Quarantine.** Confirmed deletions wait a configurable window (default 14 days) before being eligible.
- **Exclusions.** Protect specific assets from ever being flagged; survives indexing resets.
- **Breadcrumbs and journal.** Every run is tagged on the server and journalled locally — forensic trail on both sides.

First-time users are routed through a dry-run regardless of their settings.

## What cairn does on your Immich server

When you confirm a sync, `cairn` performs this sequence on your Immich server, in order:

1. **Upserts a tag** named `cairn/v1/run/<run-id>`, where `<run-id>` is an ISO-8601 timestamp plus a short device id — a stable, sortable, unambiguous handle for that specific run. Tag schema is versioned at the path so future `cairn/v2/...` variants can coexist with old tags.
2. **Applies that tag** to every affected asset via `PUT /api/tags/assets`. Includes Live Photo pairs: a still asset and its paired motion video are always tagged together so a later restore can find both halves.
3. **Moves to Immich's Trash** via `DELETE /api/assets {force: false}`. The server moves the asset to its Trash folder; Immich's default retention keeps it recoverable for 30 days.

Restoring from the Runs tab (or `cairn restore --run-id ...`) calls `POST /api/trash/restore/assets` with the asset ids from that run. **The tag stays on the asset** — it's a breadcrumb, not a state flag. You can always find what a given run touched via Immich's Tags view, even after restore.

Past the 30-day Immich retention window, whatever Immich's configured retention policy does is what happens. `cairn` never calls the hard-delete variant (`DELETE /api/assets {force: true}`).

**Where to inspect it on Immich.** Open the Immich web UI → Tags — every `cairn/v1/run/…` tag shows exactly which assets that run touched. The Trash view shows everything currently recoverable regardless of which tool moved it there.

**Local journal.** Every step is also written to an append-only `deletion-journal.jsonl` on the device running the tool. The iOS Runs tab and `cairn journal` / `cairn history` subcommands render this file. The forensic trail lives on both sides — even if the local journal is lost, `cairn history` can reconstruct everything from the server-side tags alone (requires `tag.read` scope on the API key).

## Privacy

- **No telemetry, analytics, crash reporting, or ads.** `cairn` makes network requests only to your Immich server.
- **Credentials stay on-device.** Server URL and API key live in the iOS Keychain.
- **No third parties.** There is no "`cairn` backend." The app runs locally; the CLI runs locally.
- **Your Immich server is your Immich server.** `cairn` sends authenticated requests to it using your API key; what that server logs or retains is your call, not ours.

Full privacy policy: [`PRIVACY.md`](PRIVACY.md).

## Development

- `swift test` runs the full SPM test suite (reconciliation logic, safety rails, SHA1 hashing, journal, orchestrators, Immich client, tag schema, iOS-side store implementations).
- `make test` (from `iOS/`) runs the same tests.
- `CLAUDE.md` captures project conventions and accumulated context — worth reading before touching anything substantial.

## License

MIT — see [`LICENSE`](LICENSE). `cairn` is released under MIT; the Immich project is AGPL-3.0. `cairn` is a separate client talking to Immich over its public API; the licenses don't mix.

If a compiled binary ships through TestFlight or the App Store, Apple's usual EULA governs that distribution — MIT doesn't constrain how the compiled artifact is packaged or priced. Build from source is always supported.
