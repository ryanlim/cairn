# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project name

The product is **cairn** — rendered all-lowercase in user-facing prose, docs, README, and App Store copy. The metaphor: a cairn is a stone-pile marker left at the site of something gone, which is exactly what each breadcrumb tag is.

Swift identifiers stay conventional PascalCase: Swift package `Cairn`, modules `CairnCore` / `CairnCLI`, type `struct Cairn`. Code-level identifiers follow Swift API Design Guidelines; brand prose follows the stylistic lowercase choice. Binary (`cairn`), tag prefix (`cairn/<run_id>`), env vars, and file paths are already lowercase regardless.

The name does **not** contain "Immich" by design (App Store trademark risk, brand-confusion liability, stewardship). Compatibility with Immich is described in user-facing prose, not in identifiers.

## Project status

Phase 1 CLI is working end-to-end against a real Immich instance. `immich-ios-deletion-sync-plan.md` is the current design; read it first. The goal is a small iOS app (~1–2k lines of Swift) that detects photos deleted from the iOS Photos library and trashes the corresponding server assets on the user's Immich server. Deliberately narrow — see the plan's "Anti-scope" section before proposing any feature growth.

## Reference: Immich source

A shallow clone of the Immich repo lives at `/Users/graham/code/immich` for reading the mobile app (`mobile/`, Dart/Flutter) and server API (`server/src/`, NestJS + Kysely). Use it to ground any assumption about Immich's current behavior — the project moves fast and training-data knowledge is unreliable. The HEAD when this clone was taken was `be1b9a5`; verify migrations/DTOs against the actual checkout, not against memory.

## Identity model (the key thing that was wrong and has been corrected)

Asset identity on the Immich server is **SHA1 of file content**, base64-encoded, exposed as `AssetResponseDto.checksum` (`server/src/dtos/asset-response.dto.ts:112`). The server enforces `sha1` as the only supported algorithm (`server/src/enum.ts:44`, enum `ChecksumAlgorithm { sha1, sha1-path }`).

The older `deviceAssetId` / `deviceId` scheme used by the Immich mobile app was removed from the server schema in Apr 2026 (migration `server/src/schema/migrations/1776263790468-DropDeviceIdAndDeviceAssetId.ts`). Mobile still sends those fields as multipart form data but they are no longer persisted. Do not build reconciliation around `deviceAssetId`.

Our reconciliation design (see plan §Reconciliation engine) uses a client-side **ever-seen SHA1 set** to express "delete on iPhone propagates to Immich" without touching photos that were never on the iPhone. The design intentionally treats the iPhone library as the source of truth for any content it has ever held, including content also uploaded from other devices (those get deduped to one server asset anyway).

## API endpoints that matter

All auth via `x-api-key` header.

- `DELETE /api/assets` with `{ "ids": [...], "force": false }` → trash (not hard-delete). Plural path. Controller: `server/src/controllers/asset.controller.ts:68–78`. `RouteKey.Asset = 'assets'` in `server/src/enum.ts:553`.
- `POST /api/search/metadata` (paginated) → lists assets including `checksum`.
- `POST /api/assets/bulk-upload-check` with `{assets:[{id, checksum}]}` → batch SHA1 presence check. `server/src/controllers/asset-media.controller.ts:180–193`.
- `POST /api/sync/stream` → JSONL change-event stream used by the official mobile app. `server/src/controllers/sync.controller.ts:20–37`. Candidate for steady-state tracking instead of re-pulling metadata.

## Portability contract (Option C — Swift now, Kotlin if/when)

Cairn may eventually need an Android port. The decision is to **stay single-platform Swift for Phase 1 and Phase 2**, then port `CairnCore` to Kotlin directly if Android demand materializes. To keep that future port tractable, honor these constraints now:

- **`CairnCore` stays pure Foundation + CryptoKit.** No PhotoKit, no SwiftData, no Keychain, no UIKit, no SwiftUI, no BackgroundTasks. If a new type requires an Apple-only API, it belongs in the iOS target, not Core.
- **Apple-only APIs live behind protocols defined in Core** (like `ImmichWriter` already does). The Phase 2 iOS target provides the concrete implementation; a future Android port provides a parallel Kotlin implementation of the same protocol shape.
- **The test suite is the conformance spec.** The Kotlin port's first job is to translate `Tests/CairnCoreTests/*` into Kotest/JUnit and make them pass with a Kotlin `CairnCore`. Don't let the test suite atrophy — every new bit of core logic gets a test.
- **Keep interfaces narrow.** If a public type grows an Apple-specific parameter or return type, that's leakage — refactor.
- **Port order when the time comes:** `Types` → `SafetyRails` + `ReconciliationEngine` → `Hashing` → `DeletionJournal` + `JournalReader` → `TagSchema` → `ImmichClient` → `TrashOrchestrator` + `RestoreOrchestrator`. Each has few dependencies on the previous.

This is not KMP. We're not sharing a compiled binary. We're keeping the reference implementation small enough that a mechanical port is a day of work when the Android audience is real. See the plan doc's "Portability" section for the full rationale.

## Tag schema (v1)

Every trash run writes `cairn/v1/run/<run_id>` as a tag on Immich. One tag per run; every trashed asset (including Live Photo motion videos) attached. `<run_id>` = ISO-8601 timestamp + short device id. Schema-versioned at the path — bump to `v2` for breaking changes, old tools keep reading old tags. Full rationale and what's intentionally excluded is in the plan doc's "Tag schema" section — read that before touching `Sources/CairnCore/TagSchema.swift` or the tag path in `TrashOrchestrator`.

API key scopes: `tag.create` + `tag.asset` to write; `tag.read` additionally to list runs via `cairn history`.

## Confirmed-deletion signal (Wave 4)

The default reconciliation strategy uses a *negative* signal — "checksum is in ever-seen but no longer in current-local → delete candidate." Vulnerable to iCloud sync degradation, account changes, partial library restores, and "Remove from this iPhone" with iCloud Photo Library. Safety rails catch the catastrophic versions; gradual cases can slip through.

Wave 4 introduces a *positive* signal: a `ConfirmedDeletedStore` (parallel to `EverSeenStore`) that accumulates checksums observed in iOS's Recently Deleted album. Scheduled scan (default daily) + reactive `PHPhotoLibraryChangeObserver` keep it current.

A new `CairnSettings.deletionStrictness`:
- `.strict` (recommended) — only confirmed-deleted candidates trash; diff-discovered-but-not-confirmed candidates land in pending-review for manual approval.
- `.trusting` — current behavior.

Append-only semantics (matches ever-seen). The diff's `not in current-local` clause handles user-initiated restores correctly — confirmed-deleted being a stale "yes" doesn't cause harm.

iCloud-Optimized assets are **not** affected by the confirmed-deleted question — they still appear in `PHAsset.fetchAssets()` and our enumerator downloads on demand via `isNetworkAccessAllowed = true`. First-sync hashing pays a network cost; not a correctness issue.

Full design (including UX copy guidance and failure-mode analysis) lives in the plan doc's "Confirmed-deletion signal (Wave 4)" section. Do not implement Wave 4 without re-reading that section — the strictness modes and pending-review state interact with the existing safety rails and journal events in specific ways.

## Live Photos and hidden assets

A Live Photo is one `PHAsset` on iOS but **two Immich assets**: still (`visibility: timeline`) + motion video (`visibility: hidden`), linked by the still's `livePhotoVideoId` field. `search/metadata` excludes hidden by default, so `listAllAssets()` defaults to returning only timeline-visibility assets.

**Server does NOT cascade trash** through `livePhotoVideoId` (verified 2026-04-21). `TrashOrchestrator.run` explicitly includes linked video UUIDs in every delete batch — tests in `TrashOrchestratorTests.swift` (`livePhotoVideoIncluded`) pin this. `locked` visibility needs an elevated-permissions flow our API key doesn't have and 401s; tooling skips it.

Phase 1 vs Phase 2 split on how to handle hidden assets is documented in the plan doc under "Live Photos and hidden assets" — Phase 2 (iOS) will switch to hashing all relevant `PHAssetResource`s and including hidden assets in the server view, which removes the `livePhotoVideoId` special case and makes the pipeline robust to that field being removed. Don't change the exclusion logic in Phase 1 without updating both this note and the plan.

## Hashing

Use `CryptoKit.Insecure.SHA1` on iOS — hardware-accelerated on all modern Apple silicon (ARMv8 crypto extensions). "Insecure" in the Swift API name refers to cryptographic use; for content-addressing it's fine and we have no alternative (server only accepts SHA1). PhotoKit file I/O will dominate, not the hash itself.

## Build / test / run

```
swift build             # compile everything
swift test              # 33+ unit tests across Core modules
swift run cairn --help
```

The CLI reads `.env` from the current directory by default. Required vars: `IMMICH_URL`, `IMMICH_API_KEY`. `.env` is gitignored and is *never* to be echoed in tool output.

Common subcommands:

- `cairn verify` — connectivity + auth check (lists assets for the API key's user).
- `cairn dump-server-checksums --output FILE` — writes base64 SHA1s for all server assets, one per line. Useful for simulating iPhone state in CLI-only validation.
- `cairn dry-run --local-checksums-file FILE` — full reconciliation, no mutation. Seeds/updates `ever-seen.json`.
- `cairn trash --local-checksums-file FILE [--yes]` — destructive path. Refuses to run if `ever-seen.json` is empty (forces `dry-run` first). Creates per-run breadcrumb tag `cairn/<run_id>` on Immich before deleting, writes JSONL to `deletion-journal.jsonl` at every step.

Persistent state (gitignored): `ever-seen.json`, `deletion-journal.jsonl`.
