# Minimal iOS Immich Deletion-Sync App — Plan

## Goal and scope

A small iOS app that detects photos deleted from the iOS Photos library which were previously uploaded to an Immich server, and trashes the corresponding server assets. Nothing else.

**Out of scope:** uploads (let the official Immich app handle that), photo viewing, album sync, metadata editing, two-way sync. This is a chore-doer, not a replacement for the Immich app. Target ~1,000-2,000 lines of Swift.

**Name:** **cairn** in user-facing prose (lowercase, stylistic choice). Swift identifiers stay conventional PascalCase: package `Cairn`, modules `CairnCore` / `CairnCLI`. CLI binary is `cairn`; server-side breadcrumb tags are prefixed `cairn/<run_id>`. The metaphor: a cairn is a stone-pile marker left at the site of something gone — the per-run breadcrumb tag is literally that. The app name deliberately does **not** include "Immich" — see "Naming and the Immich brand" below.

### Naming and the Immich brand

This app is *not* official, not affiliated, and intentionally avoids "Immich" in its own name. Reasons:

- Apple App Review is strict about apps that use third-party brand names without explicit authorization, especially when the function involves deleting user data.
- Brand confusion: a user who assumes affiliation and has a bad experience (erroneous deletion) would leave reviews blaming the Immich project.
- The [Immich FAQ](https://docs.immich.app/FAQ/) directs trademark questions to the maintainers. License (AGPL-3.0) and trademark are separate grants.

Compatibility with Immich goes in the App Store description, screenshots, and README — *"Reconciles your iOS Photos library against an Immich server"* — not in the app/binary identifiers.

## User flows

### Setup (once)

1. Paste Immich server URL + API key; tap Verify.
2. Grant **Full** Photos library access (Add-only won't work — we need to enumerate everything).
3. Grant Background App Refresh.
4. Set safety threshold (default: abort if > 1% of synced assets would be trashed in a single run).
5. Initial run executes in dry-run mode, shows a "would trash N photos" preview, user confirms.

### Steady state

- Status screen: last run time, pending candidates, manual "Sync Now" button.
- Settings: server, key, threshold, dry-run toggle, verbose logging, log history.
- If a run ever trips the safety threshold, a local notification fires and the next app launch opens the review screen.

## Architecture

Three components.

### A. PhotoKit layer (read-only)

- `PHAsset.fetchAssets` with `includeHiddenAssets = false`, gather the set of current `localIdentifier` values.
- Optionally register a `PHPhotoLibraryChangeObserver` to trigger a sync while foregrounded.
- Skip anything currently in Recently Deleted — those aren't really gone yet; let iCloud's 30-day window close before propagating.

### B. Immich API layer

Relevant endpoints (all authenticated with `x-api-key` header):

| Endpoint | Purpose |
|---|---|
| `POST /api/search/metadata` (paginated) | Fetch server assets with their `checksum` field |
| `DELETE /api/assets` body `{ "ids": [uuid...], "force": false }` | Move to Immich trash (plural path; `RouteKey.Asset = 'assets'`) |
| `POST /api/assets/bulk-upload-check` body `{ "assets": [{id, checksum}] }` | Batch presence check by SHA1 |
| `POST /api/sync/stream` (JSONL) | Change-event stream used by the official mobile app (candidate for steady-state tracking) |
| `GET /api/server-info/ping` | Connection test during setup |

API keys created per-user in the Immich web UI with only `asset.read` and `asset.delete` scopes.

### C. Reconciliation engine

Identity on the server is **SHA1 of file contents** (`AssetResponseDto.checksum`, base64-encoded). The `deviceAssetId` / `deviceId` fields the original Immich mobile app used for device-origin tracking were removed from the server schema in Apr 2026 (`server/src/schema/migrations/1776263790468-DropDeviceIdAndDeviceAssetId.ts`) — don't build around them.

Because the server dedupes by checksum, there is exactly one server asset per unique photo content, regardless of how many devices uploaded it. To express "delete on iPhone propagates to Immich" without also nuking photos that were never on the iPhone (e.g. Mac-only uploads), we maintain a client-side **ever-seen checksum set**: the set of SHA1 checksums this iPhone has ever observed in its local library.

Per-run logic:

1. Enumerate current PHAssets; for each, look up its SHA1 in a local `(localIdentifier, modificationDate) → checksum` cache, computing it lazily on miss (CryptoKit `Insecure.SHA1`, hardware-accelerated).
2. Merge current checksums into the persistent ever-seen set.
3. Fetch server asset checksums (paginated).
4. Compute delete candidates: server asset checksums that are **in** ever-seen but **not** in current-local.
5. Apply safety rails (see below); abort if any trip.
6. `DELETE /api/assets` with `force: false` (trash, not hard-delete).
7. Log outcome.

This gives the intended behavior:
- Photo on iPhone → deleted from iPhone → trashed on server.
- Photo never on iPhone (Mac-only, CLI imports) → never touched; its checksum is not in ever-seen.
- Photo on iPhone *and* Mac → single server asset (content-deduped); iPhone deletion is authoritative for content it has held. This is intentional — we treat the iPhone library as the source of truth for anything it has ever contained.
- Photo edited in Photos app → new SHA1 → treated as a new asset; the old checksum becomes a candidate when it's no longer on device. Acceptable since the edit produces a different file anyway.

## Live Photos and hidden assets

A Live Photo is one `PHAsset` on iOS but **two Immich assets**: the still (visibility `timeline`) and the motion video (visibility `hidden`), linked by the still's `livePhotoVideoId` field. Immich's `POST /api/search/metadata` endpoint excludes `hidden` by default, so a naive asset list undercounts by the number of Live Photos in the library.

Empirical findings (verified 2026-04-21):

- The server does **not** cascade trash via `livePhotoVideoId`. Trashing the still alone leaves the motion video live and orphaned. The delete batch must explicitly include the linked video UUID.
- The `locked` visibility class requires an elevated-permissions auth flow (PIN/session upgrade) that API-key auth doesn't have; listing it returns HTTP 401. Our tooling skips it.

### Phase 1 (current): exclude-hidden view, orchestrator cascades

`listAllAssets` defaults to the server's native filter (excludes hidden). `TrashOrchestrator` explicitly includes every candidate's `livePhotoVideoId` in the delete batch. Tests pin this behavior (`TrashOrchestratorTests.livePhotoVideoIncluded`). The `cairn diagnose` subcommand queries every visibility class separately and reports counts plus integrity (dangling video references, orphaned hidden assets) for observability.

### Phase 2 (iOS): include-hidden view, uniform checksum diff

When the iOS target lands, switch to:

1. Hash every `PHAssetResource` that Immich would have uploaded — for Live Photos that's both `.photo` (still) and `.pairedVideo` (motion video). Each ends up in `ever-seen` independently.
2. `listAllAssets` queries all non-locked visibility classes and merges. Hidden motion videos enter reconciliation as first-class entities.
3. Drop the `livePhotoVideoId` cascade logic in `TrashOrchestrator` — the diff naturally flags both halves when the user deletes the Live Photo from the iPhone.

The result is a simpler, more uniform pipeline that **doesn't depend on `livePhotoVideoId` existing on the server response**. If Immich ever drops or restructures that field, Phase-2 reconciliation continues to work; Phase-1 would silently orphan motion videos. Phase 1 ships the correct behavior today; Phase 2 removes a special case and raises the robustness floor.

## Tag schema (server-side breadcrumbs)

Every destructive run leaves a tag on Immich that together with the trash contents forms a complete audit trail even if the client's local journal is lost.

**Schema (v1):**

```
cairn/v1/run/<run_id>
```

where `<run_id>` = `<iso-8601 timestamp>-<short device id>`. Example: `cairn/v1/run/2026-04-21T17:57:15Z-034389BC`.

**One tag per trash run.** Every asset trashed in that run — including linked Live Photo motion videos — is attached to that single tag.

**Version is at the path level** because Immich tags have no description or arbitrary-metadata fields (only name/value/color/timestamps). If semantics change, bump to `v2`; old tags remain interpretable by old tools. The `run/` qualifier leaves room for sibling categories (`cairn/v1/archive/*`, etc.) without breaking changes.

**Deliberately NOT in the schema:**
- Per-asset status tags — status lives on the asset itself (`isTrashed`), not duplicated in tags.
- Device dimension as its own tag — device ID is in the run-id slug; can be promoted to `cairn/v2/device/*` if needed.
- Checksum-keyed or outcome-keyed tags — abusive use of the tag system.

**Reserved (non-breaking additions within v1):** tag `color` — a single hex-string metadata field, currently unused. Could later indicate run status at a glance in the Immich UI (green = all restored, etc.).

**API key scope:** writing tags needs `tag.create` + `tag.asset`; the `history` subcommand additionally needs `tag.read` to list runs from the server.

## Confirmed-deletion signal (Wave 4)

The default reconciliation strategy interprets "checksum is in ever-seen but no longer in `PHAsset.fetchAssets()`" as a deletion candidate. That's a *negative* signal — we infer intent from absence — and it has known failure modes:

- **iCloud sync degradation.** Photos drop out of local enumeration over time; each individual sync is under the threshold rail; cumulatively, the library could be silently emptied.
- **Account changes / partial restores.** A library that shrinks to a non-empty subset can slip under the threshold rail.
- **"Remove from this iPhone" with iCloud Photo Library.** This evicts the PHAsset from local enumeration without the user's intent being "delete from server."

> **Important note on iCloud Optimized Storage:** an *optimized* asset (where iOS has evicted the original to iCloud, keeping only a thumbnail on device) **still appears in `PHAsset.fetchAssets()`**. PhotoKit transparently downloads the original on demand if `isNetworkAccessAllowed = true`, which our `PhotoKitPhotoEnumerator` sets. So Optimize Storage is not a correctness issue — but first-sync hashing pays a network cost for every iCloud-only asset. See "Performance estimates" below.

### The positive signal: Recently Deleted

iOS exposes the Recently Deleted album to apps with Full Photos access:

```swift
PHAssetCollection.fetchAssetCollections(
    with: .smartAlbum,
    subtype: .smartAlbumRecentlyDeleted,
    options: nil
)
```

A checksum that has appeared in this album is *positive proof* of user-initiated deletion intent. Wave 4 introduces a `ConfirmedDeletedStore` (parallel to `EverSeenStore`) that accumulates these checksums.

### Hybrid model with strictness modes

A new `CairnSettings.deletionStrictness` setting:

- **`.strict`** (recommended default for cautious users):
  - Candidates whose checksums are in `ConfirmedDeletedStore` flow through the normal trash pipeline.
  - Candidates discovered by the diff but **not** in `ConfirmedDeletedStore` are held in a "pending review" state — surfaced in the UI as a Run-detail-style view where the user manually approves or skips each.
- **`.trusting`**:
  - Current behavior. Any diff-discovered candidate is eligible. Faster iteration, more risk.

Either mode keeps the existing safety rails (percent threshold, count floor, empty-local guard).

### Scan cadence and observation strategy

Hybrid of scheduled and reactive:

- **Scheduled scan** (configurable cadence; default daily): on every `BGAppRefreshTask` and on app foreground, enumerate Recently Deleted and hash anything not yet in `ConfirmedDeletedStore`. Recently Deleted is small (≤30 days of deletions, usually low hundreds), so the scan is cheap. Scanning more often than iOS's 30-day auto-purge guarantees we never miss a user-initiated deletion to the auto-purge window.
- **Reactive observation**: register a `PHPhotoLibraryChangeObserver` while the app is in memory. When PhotoKit reports an asset moved into Recently Deleted, schedule an immediate confirmed-deleted update. Belt-and-suspenders with the scheduled scan, not load-bearing.
- **Restore handling**: `ConfirmedDeletedStore` is append-only ("ever-seen in Recently Deleted"). If the user restores a photo from Recently Deleted, its checksum stays in current-local — the reconciliation diff filter excludes it from candidates regardless of whether it's still in confirmed-deleted. The diff is the gate; confirmed-deleted being a stale "yes" doesn't matter.
- **Re-deletion handling**: works correctly via the same mechanism — checksum re-enters Recently Deleted, current-local drops it again, candidate re-emerges.

### User-facing messaging (in the spirit of onboarding tone)

This is the kind of caveat that needs to be communicated honestly without alarm. Suggested copy seeds:

- **Onboarding (after Photos permission, before first dry-run):**
  > "cairn watches your Photos library and your Recently Deleted album. When you delete a photo, cairn confirms it via Recently Deleted before trashing the matching photo on your Immich server. This is the most reliable signal we have, but it has a 30-day window — if you don't open cairn for a month, it falls back to a more conservative inference. You can pick how strict cairn is in Settings."
- **Strict mode setting tooltip:**
  > "cairn only trashes server photos that we positively saw in your Recently Deleted album. Anything else gets held for your review. Use this if you want maximum safety, especially with iCloud Photo Library or iCloud-Optimized Storage."
- **Trusting mode setting tooltip:**
  > "cairn trashes any server photo that's no longer on your device, even if we didn't see it in Recently Deleted. Faster, but vulnerable to iCloud sync hiccups and library restores."
- **Pending-review banner on Home:**
  > "We saw N photos vanish from your library but couldn't confirm you deleted them. Tap to review."

These are starting points. Final copy should go through Claude Design alongside the existing microcopy.

### Acknowledged limitations

cairn is operating outside the bounds of what the Immich team designed for. Some failure modes can't be eliminated:

- A user who never opens cairn for >30 days AND uses iCloud sync that breaks during that window: confirmed-deleted gives no positive signal, and the diff is potentially noisy. Strict mode degrades to "everything goes to pending review" — annoying but safe.
- A user who genuinely wants to use cairn to clean up after a major library reorganization can override. That's fine — the rails are calibrated to err on the side of inaction; the user can always raise the threshold or accept candidates manually.

The honest framing for users: cairn is the best inference we can build on top of the iOS Photos API, with multiple layered safety nets. It is not a guarantee. The 30-day Immich trash window remains the ultimate insurance.

## Performance estimates (first-sync hashing)

The first-ever cairn sync hashes every asset in the user's Photos library to seed `EverSeenStore`. This is one-time but can be slow on large libraries with iCloud-Optimized Storage.

**Order-of-magnitude estimates** (mixed library, ~80% photos / ~20% videos):

| Library size | Fully local | iCloud-Optimized on WiFi |
|---|---|---|
| 5,000 | ~5–10 min | ~30–60 min |
| 25,000 | ~30–60 min | ~3–5 hr |
| 50,000 | ~1–2 hr | ~6–12 hr (overnight) |

**Bottlenecks:**
- SHA1 itself is hardware-accelerated on Apple silicon (~3–5 GB/s) — never the limit.
- iPhone NAND read: ~100–300 MB/s effective. Average HEIC ~3 MB → ~10–30 ms each.
- iCloud download: network-bound. ~5 MB photo on 50 Mbps WiFi → ~800 ms each.

**Empirical baseline (macOS, NVMe SSD, no iCloud)**, measured 2026-04-21 with the production `Hashing` module path (`FileHandle` → 1 MB chunks → `Insecure.SHA1` → base64):

| Synthetic asset | Per-file | Throughput |
|---|---|---|
| 3 MB HEIC × 100 | ~1.2 ms | ~2.4 GB/s |
| 8 MB HEIC × 50 | ~3.4 ms | ~2.2 GB/s |
| 30 MB video × 20 | ~12.7 ms | ~2.2 GB/s |

This says: **the SHA1 + disk-read pipeline is essentially never the bottleneck on local data.** iPhone NAND is roughly 5–10× slower than Mac NVMe, so expect ~200–500 MB/s on device — still fast enough that 5,000 fully-local photos hash in under two minutes. The 5–10 minute estimate above includes PhotoKit overhead, async/await scheduling, and per-asset enumeration cost.

**iCloud download is the actual long pole.** A user with iCloud Optimized Storage and a 50,000-asset library on a typical home WiFi will see hours, not minutes. The benchmark mode mentioned below should report local-vs-iCloud breakdown so users understand which regime they're in.

**Methodology for getting real numbers:**
1. In-app benchmark mode that runs the existing `Hashing` module over the whole library and reports total time + per-file p50/p95/p99 + local-vs-iCloud breakdown.
2. Run on a few representative devices in beta.
3. Replace the table above with measured curves.

**Onboarding implication:** the first-sync wizard should be honest:
> "First sync may take anywhere from a few minutes to a few hours depending on your library size and whether you use iCloud-Optimized Storage. Plug in and use WiFi if you can — the sync resumes if interrupted, and after this it'll be fast."

## Safety rails

Roughly in order of importance:

1. **Trash, never hard-delete.** Always `force: false`. The 30-day Immich trash window is the ultimate safety net.
2. **Threshold abort.** If a single run would trash more than N% of matched assets (default 1%), abort and notify the user for manual review. Tunable but never zero.
3. **Dry-run toggle** available from settings; every run can be run without side effects for debugging.
4. **First-ever run is always dry-run** with explicit user confirmation before the first actual deletion.
5. **Skip Recently Deleted.** Photos in iOS's 30-day Recently Deleted album are not considered deleted.
6. **Sanity check on empty server response.** If the API returns 0 matched assets but the last successful run had thousands, something is wrong — abort.
7. **Permission guard.** If Photos access is revoked or demoted to Limited, abort with a clear message.
8. **Ever-seen set is append-only in steady state.** The persistent SHA1 set only grows under normal operation. A one-time reset path (for reinstalls, device migrations) should require explicit user action and re-seed by scanning the current library without flagging any deletions.

## Background execution

iOS is stingy. We get:

- `BGAppRefreshTask` — short (~30 s), scheduled at iOS's discretion based on user habits.
- `BGProcessingTask` — longer, requires plugged-in + idle.
- `PHPhotoLibraryChangeObserver` — reactive, but only fires while app is in memory.

Strategy:
- Register both background task types at launch.
- `BGAppRefreshTask` at ~4 hour cadence runs an incremental diff (easily fits in 30 s for realistic library sizes).
- `BGProcessingTask` at ~daily cadence runs the full reconciliation.
- Don't fight iOS's scheduler — if it decides the user doesn't open the app often enough to justify background refresh, so be it. The trash window absorbs days of latency.

## Tech stack

All Apple-provided; zero third-party dependencies if feasible.

- **SwiftUI** for UI
- **iOS 17+** target (enables modern PhotoKit async APIs, SwiftData)
- **async/await** throughout
- **URLSession** for HTTP
- **Keychain Services** (small wrapper) for the API key
- **BackgroundTasks** framework
- **PhotoKit**
- **SwiftData** for persistence (simpler than Core Data for our scale)
- **Swift Testing** for unit tests (new framework, not XCTest)

## Tooling / workflow

- **Claude Design** (research preview, launched Apr 2026) for UI prototyping before writing any SwiftUI. Design the flow conversationally, iterate with inline edits, then use its Claude Code handoff to jump to implementation. Well suited for the small set of screens here — more productive than sketching directly in SwiftUI previews.
- **Claude Code** in Xcode for the actual implementation. Most of this app is scaffolding (PhotoKit boilerplate, Keychain wrapper, SwiftData models, URLSession setup) which Claude Code will handle well. Concentrate your attention on the reconciliation logic and safety rails.
- **Xcode's Instruments** for any background-task debugging in Phase 3. BackgroundTasks behavior in the simulator is misleading; test on a real device.

## Milestones

### Phase 0 — Research spike (2-4 h)

- Spin up a test Immich instance (or use your existing one with a disposable API key).
- Poke `POST /api/search/metadata`, `DELETE /api/assets`, and `POST /api/assets/bulk-upload-check` with `curl` to confirm pagination, response shapes, and that `force: false` actually trashes rather than hard-deletes.
- Verify Live Photo delete cascade: if we call `DELETE /api/assets` with the still-image UUID, does the server also trash the linked motion video (via `livePhotoVideoId`), or do we have to include both UUIDs explicitly? Check `server/src/services/asset.service.ts` and the deletion job handler in the cloned Immich repo at `/Users/graham/code/immich`.
- Xcode Playground: enumerate `PHAsset`s, measure end-to-end `(PHAsset → Data → SHA1)` throughput on a realistic library (5–10k photos). Informs whether first-run hashing needs a progress UI or background-run.
- Decide between `POST /api/search/metadata` (paginated pull) and `POST /api/sync/stream` (JSONL change feed) for steady-state tracking. Pull is simpler; stream is what the official mobile app uses and likely lighter-weight at scale.

### Phase 1 — CLI prototype (4-8 h)

Swift Package, runs as a macOS CLI tool (not an iOS app yet). Takes server URL, API key, and a stub "photo IDs" file as args. Fetches Immich assets, computes diff against the stub, prints what would be deleted. Validates reconciliation logic in isolation with fast iteration. No PhotoKit yet.

### Phase 2 — Minimum-viable iOS app (8-16 h)

- **Design the three screens in Claude Design first** (Setup, Status, Settings, plus the dry-run confirmation modal). Iterate on the flow there; it's cheaper than iterating in SwiftUI. Use its Claude Code handoff when the design is stable.
- SwiftUI app: Setup, Status, Settings screens
- Manual "Sync Now" flow with dry-run preview and confirmation
- Trash-on-confirmation via the API
- Keychain-stored API key, SwiftData-stored settings and sync history
- No background sync yet; user opens the app to trigger runs

This is the first deliverable worth testing end-to-end on a real device.

### Phase 3 — Background tasks (4-8 h)

- Register `BGAppRefreshTask` and `BGProcessingTask`
- Hook up the same reconciliation engine
- Local notifications for threshold aborts
- Xcode's "Simulate Background Fetch" for testing

### Phase 4 — Polish (ongoing)

- Error states, retry logic, copy
- Icon, launch screen, onboarding
- TestFlight beta with a handful of Immich self-hosters
- GitHub repo, README, issue templates

Rough total: 20-40 hours of focused work to get to something usable and shareable.

## Testing plan

- **Unit (Swift Testing)**: reconciliation logic with mock API responses and mock PhotoKit results. This is the correctness-critical code — exercise every edge case.
- **Integration**: against a disposable local Immich instance. Scriptable via Docker.
- **Manual on-device**: real Apple ID in a safe state (ideally a test account with a small library, at least for initial runs).

Edge-case tests to write early:

- Empty local library → **must not** trash the whole server
- Empty server response → don't crash, don't delete
- Network error mid-run → resume safely, no partial state
- Permission revoked mid-run → abort cleanly
- 100 new photos added between fetches → no false positives
- Photo moved to Recently Deleted but not yet purged → not a candidate
- iCloud Shared Library photo in timeline → correctly excluded (not uploaded by us)

## Distribution and licensing

- **License**: MIT or Apache-2.0. Immich is AGPL-3.0, but this is a separate client so license compatibility is a non-issue; pick whatever encourages contributions.
- **GitHub** repo with README documenting the Immich API key setup.
- **TestFlight** for betas — your paid dev account covers this, 10,000 external testers allowed, 90-day build validity.
- **App Store**: optional. App Review will ask why a third-party app needs Full Photos access and Immich API permissions; a clear privacy policy ("photos are never transmitted anywhere except your own Immich server, which you configure") and a short demo video should be sufficient.

## Open questions for Phase 0

1. ~~**Live Photo delete cascade.**~~ **Resolved 2026-04-21 by empirical test.** Immich does **not** cascade trash through `livePhotoVideoId`: `DELETE /api/assets` with only the still-image UUID trashes the still and leaves the linked motion video live and orphaned. The reconciliation pipeline must therefore always include the linked video UUID in every delete batch. `TrashOrchestrator` already does this (composes `stillIds + livePhotoVideoIds` and dedupes before the DELETE call).
2. **Trashed server assets in search results.** Does `POST /api/search/metadata` include already-trashed assets? We should exclude them from the diff (they're already where we'd send them).
3. **iCloud Shared Library.** Do photos shared *to* you appear in `PHAsset.fetchAssets`? If yes, they get their checksums added to ever-seen on first scan, meaning our diff *would* consider them for deletion once the user removes them from the shared library — which is probably desirable (shared photos aren't "yours" but the user is opting in to iPhone-library-as-source-of-truth). Confirm behavior and decide whether to exclude via `PHAsset.sourceType` or include.
4. **`PHAsset.localIdentifier` stability across iOS restore from backup.** Matters because our cache key is `(localIdentifier, modificationDate) → checksum`. If identifiers change on restore, we re-hash on first post-restore run. Acceptable but worth measuring.
5. **First-run hashing cost.** Measure actual throughput for PhotoKit `requestData → SHA1` on a 5–10k-photo library. If it's minutes, we need progress UI and/or a background-run mode for the initial scan.
6. **Pull vs. sync stream.** Evaluate `POST /api/sync/stream` — if it cleanly emits asset create/delete events with checksums, it might replace the paginated metadata pull as our server-state source, especially for incremental background refreshes.

## Portability

Android is a plausible future target (Immich has a large self-hosting audience that uses Android phones). Decided direction: **stay single-platform Swift for now, port to Kotlin later if demand materializes.** Not Kotlin Multiplatform, not a Rust core with FFI — both add complexity disproportionate to a ~1,000-line reconciliation layer.

Three constraints to keep a future port tractable:

1. **`CairnCore` stays pure Foundation + CryptoKit.** Nothing Apple-specific leaks into the core module — no PhotoKit, SwiftData, Keychain, BackgroundTasks, UIKit, SwiftUI. If a new type needs an Apple API, it belongs in the iOS target.
2. **Apple APIs live behind protocols defined in Core.** The iOS target supplies concrete implementations (PhotoKit-backed enumerator, SwiftData-backed ever-seen store, Keychain-backed secret vault). A future Android port supplies Kotlin equivalents of the same protocol shapes.
3. **The test suite is the spec.** The Kotlin port's first milestone is "translate `Tests/CairnCoreTests/*` to Kotest/JUnit and make them pass." Every new piece of core logic gets a test to keep the spec complete.

**Port order when the time comes:** `Types` → `SafetyRails` + `ReconciliationEngine` → `Hashing` → `DeletionJournal` + `JournalReader` → `TagSchema` → `ImmichClient` → `TrashOrchestrator` + `RestoreOrchestrator`. Each has minimal dependencies on the previous. Each Apple stdlib dep has a near-identical Android counterpart (`URLSession` → `OkHttp`/`Ktor`, `CryptoKit` → `java.security.MessageDigest`, `ISO8601DateFormatter` → `java.time.Instant`, `FileHandle` → `java.io.RandomAccessFile`).

The cost of maintaining two implementations is small because the codebase is small and the tests are thorough. The cost of drift is mitigated by porting the tests first — if both test suites pass, both implementations are correct enough.

## Anti-scope (discipline reminder)

To keep this buildable and maintainable:

- No photo viewing — Immich does this.
- No uploads — Immich does this.
- No albums, tags, metadata editing, AI, analytics, telemetry, cloud services, IAPs, accounts.
- No "smart" heuristics for what to delete — if it's gone from Photos, it's gone; trust the user.

Boring is the goal. Two screens of UI. One job done well.
