# CLAUDE.md

Guidance for Claude Code sessions working in this repo. Read this whole file before doing anything substantive — the project has a lot of accumulated context that the codebase doesn't fully self-document.

## Project name

The product is **cairn** — rendered all-lowercase in user-facing prose (README, App Store, marketing). Swift identifiers stay conventional PascalCase: package `Cairn`, modules `CairnCore` / `CairnIOSCore` / `CairnCLI`, type `struct Cairn`. Binary (`cairn`), tag prefix (`cairn/v1/run/<id>`), env vars, and file paths are lowercase.

The name does **not** contain "Immich" by design (App Store trademark risk, brand-confusion liability, stewardship). cairn is not affiliated with Immich; compatibility is described in user-facing prose, not in identifiers.

## Repo layout

Root: `/Users/graham/code/cairn/` (was `immich_delete_prototype/` until 2026-04-21; older session contexts may reference the old path).

```
Sources/
  CairnCore/          # Multi-platform pure-logic library. No Apple-only APIs.
  CairnIOSCore/       # iOS-side: SwiftData/Keychain/PhotoKit/UserDefaults impls + SwiftUI screens.
    UI/               # All SwiftUI views (palette, tokens, primitives, 7 screens, root).
  CairnCLI/           # `cairn` command-line tool (verify / dry-run / trash / restore / journal / history / diagnose).
Tests/
  CairnCoreTests/
  CairnIOSCoreTests/
iOS/                  # iOS app target (XcodeGen + Fastlane). See iOS/README.md.
  App/
    CairnApp.swift            # @main App, BGTaskScheduler.register
    AppDependencies.swift     # Concrete wiring (has TODO markers — see "Open work" below)
  fastlane/                   # Adapted from ReferenceFrame's setup
  project.yml                 # XcodeGen config — single source of truth
  Makefile                    # `make help` lists everything
cairn/                # Claude Design prototype (HTML/JSX) + HANDOFF.md. Reference, not shipped.
notes/                # Bug reports + ad-hoc notes to file later
immich-ios-deletion-sync-plan.md   # The master design doc. Read this.
README.md
LICENSE               # MIT
.env.example
```

## Reference: Immich source

A shallow clone of the Immich repo lives at `/Users/graham/code/immich` for reading the mobile app (`mobile/`, Dart/Flutter) and server API (`server/src/`, NestJS + Kysely). Use it to ground any assumption about Immich's current behavior — the project moves fast and training-data knowledge is unreliable. The HEAD when this clone was taken was `be1b9a5`; verify migrations/DTOs against the actual checkout, not against memory.

## Project status (as of 2026-04-22)

**Phase 1 CLI:** complete and validated end-to-end against a real Immich instance.
**Phase 2 iOS:** running end-to-end on simulator against a real Immich; user is actively shaking it out.

Wave-by-wave status:

| Wave | What it added | Status |
|---|---|---|
| Phase 1 | CLI: reconciliation, safety rails, journal, restore, history, diagnose | ✓ done |
| Wave 1 | ExclusionStore, CairnSettings, RunSummary enrichment | ✓ done |
| Wave 2 | Reconciliation+exclusion integration, two-confirm trash, journal events | ✓ done |
| Wave 3A | Add `CairnIOSCore` SPM target; HANDOFF.md API corrections | ✓ done |
| Wave 3B | iOS-side concrete protocol impls (PhotoKit / Keychain / SwiftData / UserDefaults) | ✓ done |
| Wave 3C | SwiftUI port of all 7 prototype screens + foundations + `CairnAppRoot` | ✓ done |
| Wave 4 | Confirmed-deletion signal (originally planned via Recently Deleted; re-architected around `fetchPersistentChanges`), strictness modes, pending review | ✓ done |
| Wave 4b | Quarantine window, held-by-quarantine vs unconfirmed split, mass-offload banner, `PendingReviewScreen`, live reconciliation wired into `CairnAppModel` | ✓ done |
| iOS app shell | XcodeGen `project.yml`, Fastlane lanes, `App/CairnApp.swift`, `App/AppDependencies.swift` | ✓ done; building + launching on sim |
| Thumbnails | `ImmichThumbnailLoader` (CairnCore actor) + `ImmichAssetThumb` view; replaces `MockAssetThumb` everywhere | ✓ done |
| App icon / mark | SVG asset at `Sources/CairnIOSCore/Resources/Media.xcassets/CairnMark.imageset`, 1024×1024 PNG at `iOS/App/Assets.xcassets/AppIcon.appiconset` | ✓ done |
| Pending-review multi-select | Select toggle, per-row checkboxes, bottom bulk-action bar (Trash N / Exclude N / Cancel / Select All) | ✓ done |
| Onboarding credentials persistence | `verifyServer` writes server URL + key to Keychain on success, rebuilds `ImmichClient` + `ImmichThumbnailLoader` | ✓ done |

**Test count: 181 passing across 27 suites.**

## Build / test / run

### Swift package (CairnCore + CairnIOSCore + CairnCLI)

```sh
swift build                  # compile all targets
swift test                   # 181 tests
swift run cairn --help       # CLI
```

CLI reads `.env` from CWD. Required vars: `IMMICH_URL`, `IMMICH_API_KEY`. **Never echo `.env` contents to tool output.** Common subcommands:

- `cairn verify` — connectivity + auth check.
- `cairn dump-server-checksums --output FILE` — write base64 SHA1s for all server assets, one per line.
- `cairn dry-run --local-checksums-file FILE` — full reconciliation, no mutation.
- `cairn trash --local-checksums-file FILE [--yes]` — destructive. Refuses on first run; forces dry-run first.
- `cairn restore --run-id X [--asset-id ...] [--file-name-matches REGEX]` — undo a run, optionally per-asset or by filename pattern.
- `cairn journal show [--run-id X | --last]` / `cairn journal list` — local audit log.
- `cairn history list [--detailed]` / `cairn history show --run-id X` — server-side reconstruction (requires `tag.read` on API key).
- `cairn diagnose` — visibility-class breakdown, Live Photo integrity check.

Persistent state (gitignored): `ever-seen.json`, `deletion-journal.jsonl`, `exclusions.json`, `confirmed-deleted.json`, `cairn-settings.json`.

### iOS app

See `iOS/README.md` for the full setup walkthrough. Short version:

```sh
cd iOS
make install       # brew install xcodegen + bundle install (see "Known gotchas" below)
make generate      # produces Cairn.xcodeproj from project.yml
open Cairn.xcodeproj
# In Xcode: select Cairn target → Signing & Capabilities → set Team
# Then: Cmd-R to build to simulator
```

After that:

```sh
make test          # swift test
make beta          # bump build, build IPA, upload to TestFlight
make release       # bump build, build IPA, upload to App Store
```

## Identity model (the key thing that was wrong and has been corrected)

Asset identity on the Immich server is **SHA1 of file content**, base64-encoded, exposed as `AssetResponseDto.checksum` (`server/src/dtos/asset-response.dto.ts:112`). The server enforces `sha1` as the only supported algorithm (`server/src/enum.ts:44`).

The older `deviceAssetId` / `deviceId` scheme used by the Immich mobile app was removed from the server schema in Apr 2026 (migration `1776263790468-DropDeviceIdAndDeviceAssetId.ts`). Mobile still sends those fields but they aren't persisted. Do not build reconciliation around them.

Our reconciliation uses a client-side **ever-seen SHA1 set** to express "delete on iPhone propagates to Immich" without touching photos that were never on the iPhone.

## API endpoints that matter

All auth via `x-api-key` header.

- `DELETE /api/assets` with `{ ids:[...], force: false }` → trash (not hard-delete). Plural path.
- `POST /api/search/metadata` (paginated) → lists assets including `checksum`. Default visibility excludes `hidden`; pass `visibility` to filter explicitly. To get all visibilities, iterate.
- `POST /api/trash/restore/assets` with `{ ids:[...] }` → restore.
- `POST /api/tags` → upsert tag by name.
- `PUT /api/tags/assets` → bulk-tag assets.
- `GET /api/tags` → list tags (needs `tag.read`).
- `POST /api/sync/stream` → JSONL change-event stream (used by official mobile app; not currently consumed by cairn).

## Portability contract (Option C — Swift now, Kotlin if/when)

Decision: stay single-platform Swift for Phase 1 and Phase 2. Port `CairnCore` to Kotlin directly if Android demand materializes. Not KMP, not a Rust core.

Rules to keep that future port viable:

- `CairnCore` stays pure Foundation + CryptoKit. No PhotoKit, SwiftData, Keychain, UIKit, SwiftUI, BackgroundTasks.
- Apple-only APIs live behind protocols defined in Core. iOS provides concrete impls in `CairnIOSCore`.
- The test suite is the conformance spec.
- Port order: Types → SafetyRails + ReconciliationEngine → Hashing → DeletionJournal + JournalReader → TagSchema → ImmichClient → TrashOrchestrator + RestoreOrchestrator.

LoC reality check (post-Wave 4): we're at ~7,000 LoC of iOS-bound code (impls + UI), well above the original "1,000–2,000" plan estimate. Half is feature additions beyond the original plan; half is design polish driven by the prototype. Worth knowing if Android ever becomes serious — see plan doc "Portability".

## Tag schema (v1)

Every trash run writes `cairn/v1/run/<run_id>` as a tag on Immich. One tag per run; every trashed asset (including Live Photo motion videos) attached. `<run_id>` = ISO-8601 timestamp + short device id. Schema-versioned at the path — bump to `v2` for breaking changes; old tools keep reading old tags.

API key scopes: `asset.read`, `asset.view`, `asset.download`, `asset.delete`, `tag.create`, `tag.asset` for normal operation; `tag.read` additionally for `cairn history` and `--file-name-matches`. `asset.view` + `asset.download` are required for thumbnail fetching in the iOS app.

## Confirmed-deletion signal (Wave 4 → 4b)

The default reconciliation strategy is a *negative* signal — "checksum is in ever-seen but no longer in current-local → delete candidate." Vulnerable to gradual library loss (iCloud sync degradation, partial restores, "Remove from this iPhone").

Wave 4 adds a *positive* signal that proves a checksum's absence is a real user-initiated deletion.

### How the positive signal is derived

The original design assumed cairn could enumerate `PHAssetCollectionSubtype.smartAlbumRecentlyDeleted` on a schedule. **That was wrong** — Apple never exposed Recently Deleted as a public enumerable subtype. A live probe (iOS 26.4 sim, `PersistentChangeProbeView` in pre-Wave-4b git history) verified that `PHPhotoLibrary.fetchPersistentChanges(since:)` fires a `deletedLocalIdentifiers` event immediately at soft-delete time (not deferred to the 30-day purge), so the architecture pivoted to that API.

Current pipeline (`Sources/CairnIOSCore/PhotoKitPersistentChangeReconciler.swift`):

1. **First run** (or after `PHPhotosError.persistentChangeTokenExpired`): enumerate the full library, hash every asset, rebuild a `[localIdentifier: Set<Checksum>]` cache in `LocalHashStore`, snapshot the current `PHPersistentChangeToken` in `PersistentChangeTokenStore`.
2. **Subsequent wakes** (foreground `requestSync` / `BGAppRefreshTask`): call `fetchPersistentChanges(since: savedToken)`, iterate each `PHPersistentChange`, collect inserted/updated/deleted `localIdentifier`s (via `changeDetails(for: PHObjectType.asset)`). For each **deleted** id, look up its cached checksums and `ConfirmedDeletedStore.union(_:at: now)` — this is the positive signal and it stamps the quarantine clock. For each **inserted/updated** id, re-hash and refresh the cache + `EverSeenStore`; also `ConfirmedDeletedStore.remove(_:)` so re-appeared assets stop being flagged. Save the new token.
3. **Token expired** → fall back to full enumeration (step 1). Token retention is system-controlled; Apple doesn't document a retention window, so always handle this error gracefully.

The LocalHashStore is iOS-specific (PhotoKit's `localIdentifier` is Apple-only). The protocol lives in `CairnCore/LocalHashStore.swift` so a Kotlin port swaps in MediaStore URIs without changing ReconciliationEngine.

### Quarantine window (Wave 4b)

`ConfirmedDeletedStore.snapshot()` returns `[Checksum: Date]` — the confirmation timestamp starts a per-item quarantine clock. `ReconciliationEngine` partitions:
- **in-quarantine:** `confirmedAt + quarantineDays > now` → held for user review
- **past-quarantine:** eligible to trash (subject to strictness)

`CairnSettings.quarantineDays` (range `0...90`, default 14) controls the window. Settings screen surfaces a slider below the strictness picker.

### Strictness modes

`CairnSettings.deletionStrictness` (default `.trusting` — the flip from `.strict` was intentional now that quarantine provides the primary safety):

- `.trusting` — past-quarantine confirmed items trash; in-quarantine items wait; unconfirmed (diff-only, no positive signal) items flow through to trash. Quarantine alone is the safety window.
- `.strict` — past-quarantine confirmed items trash; in-quarantine items wait; unconfirmed items also go to pending review. Paranoid mode; requires both signals.

`ReconciliationOutput` carries three buckets: `deleteCandidates`, `pendingReviewCandidates`, and `heldByQuarantineCandidates` (a subset of pending, distinguished so the UI can render an "eligible in N days" countdown rather than a generic "pending" label).

### Mass-offload banner

If a single `requestSync` confirms ≥ `CairnAppModel.massOffloadThreshold` (50) deletions in one burst, the Pending Review screen surfaces a warn-tone Callout offering a single "Bulk exclude N" action — so a user who just offloaded hundreds of photos to free storage can protect them in one tap rather than reviewing each.

### iCloud-Optimized + Live Photos

iCloud-Optimized assets still appear in `PHAsset.fetchAssets()`; our enumerator downloads on demand via `PHAssetResourceManager` (`isNetworkAccessAllowed = true`). First-sync hashing pays a network cost but no correctness issue. Live Photos produce two checksums per `PHAsset` (still + paired video) which both land in `LocalHashStore[localIdentifier]`; when the id is deleted, both checksums propagate to `ConfirmedDeletedStore`.

Full design history (including the pivot from Recently Deleted to persistent changes, failure modes, Android implications) lives in the plan doc's "Confirmed-deletion signal" section.

## Live Photos and hidden assets

A Live Photo is one `PHAsset` on iOS but **two Immich assets**: still (`visibility: timeline`) + motion video (`visibility: hidden`), linked by the still's `livePhotoVideoId` field. `search/metadata` excludes hidden by default.

**Server does NOT cascade trash** through `livePhotoVideoId` (verified empirically). `TrashOrchestrator.run` explicitly includes linked video UUIDs in every delete batch — `TrashOrchestratorTests.livePhotoVideoIncluded` pins this. `locked` visibility needs an elevated-permissions flow our API key doesn't have; tooling skips it.

## Edit semantics (PhotoKit ↔ Immich asymmetry)

This is the trickiest reasoning in the codebase and the most surprising for users. Read this whole section before touching `EditRetirementStore` or the reconciler's edit-handling paths.

### The asymmetry

When a user edits a photo in Photos.app, PhotoKit advances the asset's `modificationDate` and the rendered bytes change (so does the SHA1). Apple's edit model preserves the original locally — `PHAssetResource` enumeration shows both `.photo` (original bytes) and `.fullSizePhoto` (edited bytes), plus a private `.adjustmentData` blob — but **adjustment data never leaves Photos.app**. Export, AirDrop, or upload-to-Immich all give you flat rendered bytes; the edit history is unrecoverable outside the device's `PHPhotoLibrary`.

The Immich mobile app picks the resource tagged `isCurrent` (the edited bytes — see `mobile/ios/Runner/Sync/PHAssetExtensions.swift`), uploads as a new asset, server gets a separate row keyed by the new SHA1. Net: server now has **two assets per edited photo** (original + edited). Immich never deletes the original on edit; it just accumulates versions.

### What cairn cannot do

- **Apply Apple's adjustment data outside Photos.app.** The `.adjustmentData` blob format is private and Apple has changed it across iOS versions (notably around iOS 13 ML edits and the iOS 16 Adjustment 2.0 work). Even if cairn captured it as a sidecar to Immich, no non-Apple tool could render the edit. The only first-class portable Apple-edits path is iCloud Photos (which syncs adjustment data across iCloud-connected devices) — Immich is not iCloud.
- **Backup edits losslessly.** Practically, an Immich-backed photo that's been edited has both the original and the rendered edited result on the server. Re-importing the original to Photos.app gets you back the original-content image but no editing history.

### What cairn does (as of this writing)

`EditRetirementStore[id_X]` records the **first SHA1 set cairn ever observed** for each `localIdentifier`. The set is first-write-wins (re-observation through full-enum, orphan-sweep, etc. is a no-op). For Live Photos this is naturally a 2-element set (still + paired motion).

While `id_X` is alive in PhotoKit:
- Its current bytes live in `LocalHashStore[id_X]`.
- Its `firstObserved` set is union'd into `currentLocalChecksums` at reconciliation time (see `AppDependencies.performLiveReconciliation`'s `extendedLocal`). The protected SHA1s are exempt from candidate evaluation — they stay safe on Immich.
- Any *intermediate* SHA1 (cache held it transiently between edits, isn't the first observed) goes through `ConfirmedDeletedStore` quarantine on retirement → trashes after 14 days.

When `id_X` is deleted (PhotoKit `deletedLocalIdentifier` *or* the orphan sweep catches a back-channel deletion), the `firstObserved` set is union'd into `removedChecksums` alongside the cache's current bytes. Both flow through `trulyAbsent` filter → `ConfirmedDeletedStore.union` → quarantine clock starts → trashes after 14 days. Then `editRetirement.remove(for: [id_X])` cleans up.

### Worked examples

**Edit → revert → edit again** (`SHA1_O` original, `SHA1_E1`/`SHA1_E2` edits):
- Initial: cache `{SHA1_O}`, firstObserved `{SHA1_O}`. Server `{SHA1_O}`.
- Edit 1: cache `{SHA1_E1}`. retired = `{SHA1_O}` ∈ firstObserved → **protect**. Server gains `SHA1_E1`. cairn flags nothing.
- Revert: cache `{SHA1_O}`. retired = `{SHA1_E1}` ∉ firstObserved → **quarantine**. After 14 days, `SHA1_E1` trashes.
- Edit 2: cache `{SHA1_E2}`. retired = `{SHA1_O}` ∈ firstObserved → **protect**. Server gains `SHA1_E2`.
- Steady state: server `{SHA1_O, SHA1_E2}`. Always exactly one original + one current.

**Edit → edit (no revert)**: same outcome. The intermediate `SHA1_E1` quarantines and trashes; the original stays anchored.

**Delete after multiple edits**: `removedChecksums` includes both current bytes and `firstObserved` set. Both quarantine. After 14 days, both trash on Immich. User intent — "delete on iPhone propagates to Immich" — preserved across the whole edit history.

### Caveats

- **Cairn-installed-after-edit**: `firstObserved` ends up being whatever bytes existed at first observation, not the true pre-cairn original. The pre-cairn original (uploaded by Immich earlier) is invisible to cairn (its SHA1 isn't in EverSeen since cairn never hashed it), so reconciliation never proposes trashing it — it stays safe on Immich by virtue of never being a candidate. Net behavior is fine: any historical Immich asset cairn never observed is permanently safe; cairn's `firstObserved` anchor for what it DOES know about adds an additional protected version.
- **`ConfirmedDeletedStore.union` is first-write-wins on the timestamp.** If a SHA1 is somehow already confirmed (legacy `.distantPast` migration, prior session), a fresh `now` stamp doesn't replace it. For edits this is rarely an issue because intermediate edit SHA1s are typically novel content, but it's the same pattern that bit us during the orphan-sweep regression — when in doubt, Reset Index gives a clean slate.
- **Per-id, not per-photo.** `EditRetirementStore` keys on `localIdentifier`. If two PHAssets share a SHA1 (duplicate import via AirDrop-to-self), they get independent `firstObserved` entries. Deletion of one doesn't propagate the other's protection.

## Hashing

Use `CryptoKit.Insecure.SHA1` on iOS — hardware-accelerated on all modern Apple silicon. "Insecure" refers to cryptographic suitability; for content-addressing it's fine and we have no choice (server only accepts SHA1). PhotoKit file I/O dominates, not the hash. Empirical baseline: ~2.3 GB/s sustained on macOS NVMe (`Hashing` module). Expect ~200–500 MB/s on iPhone NAND.

## SwiftUI/UI conventions in CairnIOSCore

- All colors via `@Environment(\.cairnTokens)`. Components NEVER reach for raw `Color.red` etc. Tokens are derived from `CairnPalette` per `ColorScheme`.
- Apply theme at root: `.cairnTheme(palette)`.
- Microcopy from the prototype is verbatim — see HANDOFF.md "Keep these copies verbatim". Cite source in code comments when copy is load-bearing.
- Each screen has multiple `#Preview` blocks (light, dark, key states) and uses `CairnFixtures` for preview data.
- Use existing primitives (`AppHeader`, `KeylineSection`, `CairnCard`, `KeyValRow`, `ToggleRow`, `Stat`, `Callout`, `CairnTabBar`, `ApiKeyInput`, `ImmichAssetThumb`) — don't re-roll. `MockAssetThumb` still exists as an internal gradient fallback but call sites should use `ImmichAssetThumb` (takes `assetId: String?`; falls back to the same gradient when the id is nil or the environment loader is absent, so previews keep working).
- **Inline "cairn" in prose** uses `Text.cairnWord` (monospace). Defined once in `CairnPrimitives.swift`; screens concat via `Text("... ") + .cairnWord + Text(" ...")`. The standalone hero wordmark (display-size title at onboarding / status header) is styled separately and deliberately doesn't use this helper — that's a logo element, not inline prose.
- **`CairnMark`** renders the SVG at `Sources/CairnIOSCore/Resources/Media.xcassets/CairnMark.imageset` as a vector asset (Xcode converts SVG → vector PDF at build time). Multi-color, so fixed across themes. A monochromatic variant would need `.template` rendering + `.foregroundStyle(t.primary)` to regain theme responsiveness — see the comment in `CairnPrimitives.CairnMark`.
- **Preview-vs-runtime fixture split**: `CairnAppRoot` falls back to `CairnFixtures.candidates` inside the `.dryRun` sheet *only* when `ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"`. At runtime, a nil `model.reconciliation` renders an empty list rather than fake candidates. Don't reintroduce the runtime fallback — it caused the "15 fake assets on first sync" bug.
- **Thumbnail loader environment**: `ImmichAssetThumb` reads `@Environment(\.immichThumbnailLoader)`. `AppDependencies` builds the loader when credentials are available and `CairnApp.swift` threads it via `.environment(\.immichThumbnailLoader, dependencies.thumbnailLoader)`. Nil loader → gradient placeholder; real loader → auth'd fetch + cache.

## iOS app shell (Xcode project)

Lives in `iOS/`. See `iOS/README.md`. Key points for Claude:

- The `.xcodeproj` is **gitignored**; `iOS/project.yml` is the source of truth. Run `make generate` after editing project.yml.
- `iOS/App/CairnApp.swift` is the `@main` App. Owns `BGTaskScheduler.register` for the scheduled Wave-4 scan; injects `ImmichThumbnailLoader` via environment.
- `iOS/App/AppDependencies.swift` wires concrete iOS-side impls (Keychain, SwiftData, PhotoKit, ImmichClient, `PhotoKitPersistentChangeReconciler`, `ImmichThumbnailLoader`) into a `CairnAppActions` bundle the UI consumes. `requestSync` runs the reconciler then reconciliation, populates `model.reconciliation` + `model.library` + `model.lastScanBurstCount` on MainActor. `confirmTrash` / `approvePending` / `excludePending` / `bulkExcludeRecentOffload` all read from that cached reconciliation.
- Onboarding's `verifyServer` persists credentials to Keychain and rebuilds `immichClient` + `thumbnailLoader` on successful verify — a mid-onboarding crash no longer forces a retype, and the "first dry-run" step inherits a working client. Earlier revisions of the app didn't persist here; if you see historical commentary about "credentials not saved," it refers to that now-closed gap.
- Fastlane lanes mirror `ReferenceFrame`'s pattern — App Store Connect API key auth via env vars.

## Open work / known TODOs

In rough priority order:

1. **First on-device test** on a real iPhone to validate PhotoKit enumeration against a real library, `BGAppRefreshTask` scheduling (sim lies about background tasks), and the actual end-to-end deletion flow against the user's Immich. The persistent-change probe confirmed the API works on sim; device behavior is expected to match but hasn't been verified.
2. **Snapshot tests for SwiftUI screens.** None yet. Good candidate is `swift-snapshot-testing` from Point-Free. Priority targets: Setup flow steps, DryRunSheet phases, PendingReviewScreen (empty / populated / mass-offload variants).
3. **First TestFlight build.** Icon is in place; credentials persistence is in place; should be unblocked.
4. **App Store submission.** Metadata + privacy-labels + reviewer notes live in `docs/app-store-*.md`. Screenshot pipeline (`make screenshots`) is in place. Submission itself still requires TestFlight being live and a hosted privacy policy URL.
5. **Privacy policy page.** `PRIVACY.md` is in the repo; needs a rendered URL (GitHub Pages or equivalent) that App Store Connect can link to. The existing `NSPhotoLibraryUsageDescription` is accurate.
6. **Local OS notifications for backlog alerts.** In-app Status banner already exists (gated by `CairnSettings.deletionBacklogAlertThreshold`; bell-badge callout on Status when the backlog crosses the threshold). Next step: fire a local `UNNotificationRequest` from `handleBackgroundRefresh` when a scan causes the backlog to cross the threshold (edge-trigger: pre-scan count < threshold, post-scan ≥ threshold, so we don't re-fire every slot while the user ignores it). Prerequisites: `UNUserNotificationCenter` permission request (add to Settings → Notifications row + a one-shot prompt on first cross), deep-link routing so tapping the notification opens cairn straight to PendingReview, dedup state to avoid double-firing across BG slots. See the existing `notifyOnAbort` setting for the precedent shape.

## Things that are NOT done and probably need a session

- Snapshot tests for SwiftUI screens (see #4 above).
- `BGAppRefreshTask` validation on a real device (simulator lies about background tasks).
- App Store metadata + screenshots.
- Privacy policy page.

## Memory of historical bugs / lessons

- The Immich `/server/ping` endpoint returns `text/html` and 406s if you send `Accept: application/json`. Don't add an Accept header in `ImmichClient`.
- `IMMICH_URL` may or may not include `/api`. `ImmichClient.normalize` handles both.
- `search/metadata` excludes `hidden` visibility by default, which hides Live Photo motion videos. `assetsForTag` iterates all non-locked visibilities to surface them.
- **`PHAssetCollectionSubtype.smartAlbumRecentlyDeleted` does NOT exist as a public case.** Apple ships `smartAlbumRecentlyAdded` (206) but no corresponding `RecentlyDeleted`. The old `PhotoKitPhotoEnumerator.recentlyDeletedChecksums()` that referenced it never compiled on iOS; the pipeline now uses `PHPhotoLibrary.fetchPersistentChanges(since:)`. If you find code or plans referring to "enumerate Recently Deleted," that's the legacy path — don't resurrect it.
- **`PHPhotoLibrary.fetchPersistentChanges(since:)` fires `deletedLocalIdentifiers` at soft-delete time on iOS 26.4**, not deferred to the 30-day purge. Verified empirically with the probe (see git history for `iOS/App/PersistentChangeProbeView.swift` if needed). Retention window for the change log is not documented by Apple — always handle `PHPhotosErrorPersistentChangeTokenExpired` with a full re-enumeration fallback.
- **`CairnAppRoot`'s fixture fallback is preview-only.** Guarded by `ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"` so a nil `model.reconciliation` renders empty at runtime, fixtures in #Previews. Caused the "15 fake assets on first sync" bug before the guard — don't regress.
- **`CairnSettings` Codable has a custom `init(from:)`** that decodes missing keys as defaults. Required because `quarantineDays` was added post-1.0 and legacy payloads would otherwise fail to decode.
- `ConfirmedDeletedStore.union(_:at:)` is first-write-wins on the timestamp — re-confirming a checksum does NOT reset its quarantine clock. Flapping assets (offload/restore/offload) still age out predictably.
- **Edit-bypasses-quarantine was a real regression** (2026-04-25). Earlier code stamped every retired SHA1 from `LocalHashStore.set(_:for:)` into `ConfirmedDeletedStore` on retire — meaning editing a kept photo silently scheduled the original for trash on Immich. Replaced with the `EditRetirementStore` first-observed-anchor model (see "Edit semantics" section). If you see commits or branches referring to "edit-retire-to-quarantine," that's the wrong-semantics path — don't resurrect it.
- **Persistent-change log can return 0 events even when there's drift.** `fetchPersistentChanges(since: token)` is event-relative-to-token, not authoritative for current library state. A deletion that happened before the saved token (rebuild push, prior-sync token-save, etc.) is invisible to the next fetch. The orphan sweep (`reconcileCacheAgainstLibrary`) is the safety net — it must run **unconditionally** every incremental scan, not gated on `hasChanges`. An earlier optimization gated it for relaunch perf; that broke the safety contract.
- **The Immich mobile app uploads the *edited* bytes**, not the original, when an asset has been edited (it picks the `isCurrent` `PHAssetResource` per `mobile/ios/Runner/Sync/PHAssetExtensions.swift`). Confirmed empirically. Affects how cairn reasons about server-side asset cohorts after edits.
- `RunSummary` init takes `durationMs` and `notes` (added in Wave 1) — older callers will fail. Always include them.
- The harness's "is git repository" check is cached at session start; running `git init` mid-session leaves agent worktree isolation permanently disabled until the next session start. (Bug report at `notes/claude-code-bug-worktree-isolation.md`.)

## Memory and other forms of persistence

Memory is one of several persistence mechanisms available. For task-specific information, prefer plans/tasks. For this kind of cross-session project state, this CLAUDE.md is the right home. Don't write project state into Claude memory — it's meant for cross-conversation user/feedback context.
