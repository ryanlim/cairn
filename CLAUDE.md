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

## Live Photos

A Live Photo is one `PHAsset` on iOS but **two Immich assets** linked by `livePhotoVideoId`. Mobile upload path: motion video first to obtain a UUID, then still with `livePhotoVideoId` set (`mobile/lib/services/foreground_upload.service.dart:341–358`).

**Server does NOT cascade trash** through `livePhotoVideoId` (verified empirically 2026-04-21). Deleting only the still leaves the motion video orphaned. `TrashOrchestrator.run` must always include linked video UUIDs in the delete batch — it already does, and tests in `TrashOrchestratorTests.swift` pin that behavior.

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
