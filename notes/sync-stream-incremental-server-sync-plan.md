# Incremental server-side sync via `POST /api/sync/stream`

Planning document for replacing cairn's current full-rescan-via-paginated-`search/metadata` server-side discovery with an incremental change-data-capture sync against Immich's `sync/stream` endpoint.

Written 2026-05-25. Status: ready to execute.

---

## Goal

When cairn needs to know what assets the user's Immich server currently holds, today it issues paginated `POST /api/search/metadata` requests until the result set is exhausted. For a 100k-asset library that's ~400 requests on every full refresh. We want to replace that with an incremental approach: stream change events from the server since the last acknowledgment, apply them to a local per-(URL, userId) cache of server assets, and feed that cache into the reconciliation engine instead of re-fetching.

Steady-state cost on a healthy big library drops from ~400 requests per sync to ~1 streaming call returning the events since the last ack (typically zero to tens of events for a normal sync interval).

## Background and motivation

This is item #2 from a two-item scaling-concerns conversation. Item #1 (incremental token-expiry fallback) turned out to be already implemented in `PhotoKitPersistentChangeReconciler.runFullEnumeration` — `hashAllCurrentAssets` already classifies assets by `modificationDate` and only re-hashes those whose cached modDate diverged. So token expiry on a large library is already cheap. This is the remaining real work.

Today cairn re-paginates the server's full asset list on every sync. That's:

- ~250 assets per `search/metadata` page (Immich default page size).
- Linear in total server-asset count, regardless of how many assets actually changed.
- Each page is a real HTTP round-trip; on a server at the end of a slow link the latency dominates.

The user reports this is bearable today but will become painful for users with 50k+ asset libraries. The `sync/stream` endpoint exists exactly to solve this — it's what Immich's own mobile app uses for its local-asset-DB maintenance — and we already have a checked-out copy of the server source at `/Users/graham/code/immich` for reading the protocol.

## What we discovered about the Immich API

References (all paths relative to `/Users/graham/code/immich/server/src/`):

- `controllers/sync.controller.ts` — endpoint definitions
- `dtos/sync.dto.ts` — request and event payload schemas
- `services/sync.service.ts` — server-side stream loop logic (not directly relevant to client, but useful for debugging)
- `enum.ts` — `Permission` enum (search for `Sync` to find the new scopes)

### Endpoints

| Method  | Path                | Purpose                                                | Permission required        |
|---------|---------------------|--------------------------------------------------------|----------------------------|
| `POST`  | `/api/sync/stream`  | Stream JSONL change events                             | `sync.stream`              |
| `GET`   | `/api/sync/ack`     | Retrieve current acks (for diagnostics / debugging)    | `sync.checkpoint.read`     |
| `POST`  | `/api/sync/ack`     | Submit a batch of acks (advances the cursor)           | `sync.checkpoint.update`   |
| `DELETE`| `/api/sync/ack`     | Wipe acks (forces re-stream)                           | `sync.checkpoint.delete`   |

All four are stable in API v2 (`HistoryBuilder().added('v1').beta('v1').stable('v2')`).

### Request shape

`POST /api/sync/stream` body (`SyncStreamDto`):
```json
{
  "types": ["AssetV1", "AssetDeleteV1"],
  "reset": false
}
```
- `types` selects which entity-type events to receive. Cairn cares only about `AssetV1` and `AssetDeleteV1` — Immich emits many more (albums, memories, faces, exif, edits, partners) which we filter out at the request level.
- `reset: true` wipes the server-side cursor for this client and re-streams everything from scratch.

`POST /api/sync/ack` body (`SyncAckSetDto`):
```json
{ "acks": ["<ack-id-1>", "<ack-id-2>", ...] }
```
- Max 1000 acks per call. We batch in the streaming consumer.

### Response shape

`sync/stream` returns `Content-Type: application/jsonlines+json` — newline-delimited JSON, one event per line. Each event is `{ type, data, ack }`:

```jsonl
{"type":"AssetV1","data":{"id":"...","ownerId":"...","checksum":"...","livePhotoVideoId":null,"deletedAt":null,...},"ack":"opaque-ack-id-1"}
{"type":"AssetDeleteV1","data":{"assetId":"..."},"ack":"opaque-ack-id-2"}
{"type":"SyncCompleteV1","data":{},"ack":"..."}
```

Stream emits `SyncCompleteV1` for each type at the end of the current batch. Stream closes after that — it's request/response, not long-poll. Client makes a new request to get the next batch.

### Entity types we consume

From `dtos/sync.dto.ts`:

**`SyncAssetV1`**:
```ts
{
  id: string                              // server-side UUID
  ownerId: string
  originalFileName: string
  thumbhash: string | null
  checksum: string                        // base64 SHA1 — our join key
  fileCreatedAt: Date | null
  fileModifiedAt: Date | null
  localDateTime: Date | null
  duration: string | null
  type: AssetType                         // image|video|audio|other
  deletedAt: Date | null
  isFavorite: boolean
  visibility: AssetVisibility             // timeline|hidden|archive|locked
  livePhotoVideoId: string | null         // links still ↔ paired motion
  stackId: string | null
  libraryId: string | null
  width: number | null
  height: number | null
  isEdited: boolean
}
```

**`SyncAssetDeleteV1`**:
```ts
{ assetId: string }
```

We also need to recognize `SyncCompleteV1` (zero-payload sentinel that ends a batch). Other types (`SyncResetV1`, `SyncAckV1`, album/memory/face/exif/etc.) we skip silently — the `types` request filter should keep them off the wire, but defensive ignore in the parser is cheap.

### Permission scope additions

Per `enum.ts`, the `Permission` enum gates each endpoint. We currently require `asset.read`, `asset.view`, `asset.download`, `asset.delete`, `tag.create`, `tag.asset` (plus `tag.read` for history/restore). The new scopes:

- `sync.stream`
- `sync.checkpoint.read`
- `sync.checkpoint.update`
- `sync.checkpoint.delete`

A user upgrading from a pre-sync-stream cairn install will have an API key without those scopes. We need to:

1. Update the README's required-scopes list (and `Sources/CairnIOSCore/UI/SetupScreen.swift` onboarding copy).
2. Detect 403 on the `sync/stream` call distinctly from other auth errors so we can surface "regenerate your API key with `sync.*` scopes" rather than the generic "API key rejected" message.
3. Fall back gracefully to the existing paginated path when the scope is missing — degraded mode rather than hard failure.

## Current cairn architecture

Server-side discovery today (relevant call sites):

- `ImmichClient.listAllAssets()` and `ImmichClient.searchAllAssets()` in `Sources/CairnCore/ImmichClient.swift` paginate `POST /api/search/metadata` until exhaustion. They run inside `performLiveReconciliation` (in `iOS/App/AppDependencies.swift`) on every sync.
- The result is a `[ServerAsset]` collection fed into `ReconciliationEngine.Input.serverAssets`.
- There is no client-side cache of server state — each sync re-fetches.

No SwiftData store exists for server assets. We'll need to add one.

## Target architecture

```
                ┌─────────────────────────────────────┐
                │  Immich server                       │
                │   POST /api/sync/stream → JSONL      │
                └─────────────────────────────────────┘
                              │
                              ▼
   ┌────────────────────────────────────────────────────────┐
   │ ImmichClient.syncStream(types:reset:) →                 │
   │   AsyncThrowingStream<SyncEvent, Error>                 │
   └────────────────────────────────────────────────────────┘
                              │
                              ▼
   ┌────────────────────────────────────────────────────────┐
   │ ServerAssetSyncCoordinator (new)                        │
   │  - consumes stream                                       │
   │  - applies events to ServerAssetCacheStore               │
   │  - batches acks, POSTs to /api/sync/ack                  │
   │  - persists cursor (most-recent-ack per entity type)     │
   └────────────────────────────────────────────────────────┘
                              │
                              ▼
   ┌────────────────────────────────────────────────────────┐
   │ ServerAssetCacheStore (new, SwiftData, per-partition)   │
   │   Schema: [checksum -> SyncAssetV1]                      │
   │   plus secondary index by serverAssetId                  │
   └────────────────────────────────────────────────────────┘
                              │
                              ▼
   ┌────────────────────────────────────────────────────────┐
   │ ReconciliationEngine consumes from cache, not API        │
   └────────────────────────────────────────────────────────┘
```

Bootstrap behavior: empty cache → run existing `searchAllAssets()` once to seed, then switch to streaming. Avoids needing a server-side reset request in the common upgrade path.

Cursor behavior: we don't store a single cursor — we store per-entity-type acks the way the server does. `SyncAckV1` payloads come with per-event-type ack IDs; the next stream request resumes from wherever the acks left off.

## Implementation steps

Order matters. Each step is independently mergeable and testable. Land them in separate commits.

### Step 1 — Documentation + onboarding-copy update (~0.5d)

Files:
- `README.md` — add `sync.stream`, `sync.checkpoint.read`, `sync.checkpoint.update`, `sync.checkpoint.delete` to the "API key scopes needed" sentence.
- `iOS/fastlane/metadata/en-US/description.txt` — same scope list update (if it ships in the App Store metadata).
- `Sources/CairnIOSCore/UI/SetupScreen.swift` — the onboarding screen that shows the user which scopes to grant. Find the existing scope list, add the four `sync.*` scopes.
- `CLAUDE.md` — "Tag schema (v1)" section already enumerates scopes. Update to mention the new ones and explain why (incremental sync).

No code changes yet. Commit message focused on "preparing for sync/stream — declaring the new scopes we'll need."

### Step 2 — Swift type mirrors (~0.5d)

New file: `Sources/CairnCore/SyncEntities.swift`

Define the Codable structs that mirror the Immich types we consume:

```swift
public enum SyncEntityType: String, Sendable, Codable {
    case assetV1 = "AssetV1"
    case assetDeleteV1 = "AssetDeleteV1"
    case syncCompleteV1 = "SyncCompleteV1"
    case syncResetV1 = "SyncResetV1"  // defensive ignore
    case syncAckV1 = "SyncAckV1"      // defensive ignore
    // intentionally omitting: AlbumV1, MemoryV1, PersonV1, AssetFaceV1, ... —
    // cairn never requests these via the `types` filter.
}

public struct SyncAssetV1: Sendable, Codable, Equatable {
    public let id: String
    public let ownerId: String
    public let originalFileName: String
    public let checksum: String                   // base64 SHA1 — join key
    public let livePhotoVideoId: String?
    public let deletedAt: Date?
    public let visibility: String                 // raw — we filter via the legacy enum
    public let isFavorite: Bool
    public let type: String                       // image|video|audio|other
    public let fileCreatedAt: Date?
    public let fileModifiedAt: Date?
    public let width: Int?
    public let height: Int?
    // Fields we don't store: thumbhash, exif, stackId, libraryId, localDateTime,
    //                       duration, isEdited — not needed for reconciliation.
}

public struct SyncAssetDeleteV1: Sendable, Codable, Equatable {
    public let assetId: String
}

public enum SyncEvent: Sendable, Equatable {
    case asset(SyncAssetV1, ack: String)
    case assetDeleted(SyncAssetDeleteV1, ack: String)
    case complete(type: SyncEntityType, ack: String)
    case ignored(type: String, ack: String?)
}
```

Plus a custom Decoder for the wire envelope `{ type: String, data: AnyJSON, ack: String }` that switches on `type` to decode the right payload. Unknown types decode as `.ignored` (forward-compatible against server changes).

Tests in `Tests/CairnCoreTests/SyncEntitiesTests.swift`:
- Each known event type round-trips through Codable.
- Unknown `type` strings decode as `.ignored` without throwing.
- Missing optional fields decode as nil.

### Step 3 — `ImmichClient` streaming + ack methods (~1d)

Modify `Sources/CairnCore/ImmichClient.swift`. Add:

```swift
public func syncStream(
    types: [SyncEntityType],
    reset: Bool = false
) -> AsyncThrowingStream<SyncEvent, Error>

public func ackSync(_ ackIds: [String]) async throws

public func currentSyncAcks() async throws -> [(type: SyncEntityType, ack: String)]
```

Implementation notes:
- Use `URLSession.bytes(for:)` (returns `(URLSession.AsyncBytes, URLResponse)`) and split on `\n` to get JSONL lines.
- Per-line, JSONDecoder a `SyncEvent`. Skip empty lines.
- The stream terminates when the underlying response body ends. Yield-and-finish gracefully.
- On 401 → throw `ImmichClientError.httpStatus(401, body)` (existing handling kicks in).
- On 403 → throw a new `ImmichClientError.missingScope([requiredScope])` variant so the caller can route to the actionable "regenerate API key" error. This case is new; add it to the enum.
- Ack batching: caller is responsible for assembling ack arrays and calling `ackSync(_:)`. The streaming method itself doesn't ack — separating those concerns lets the cache layer ack only after successfully applying the events to disk.

Tests in `Tests/CairnCoreTests/ImmichClientSyncStreamTests.swift` (mock URLSession via the existing test harness pattern):
- Successful stream with multiple AssetV1 + AssetDeleteV1 events terminates cleanly with the expected event sequence.
- Stream with a `SyncCompleteV1` followed by close terminates without losing the last event.
- 403 from the stream endpoint surfaces as `.missingScope`.
- Malformed JSONL line in the middle of a stream: the stream throws on the bad line (don't try to recover; the cache won't be in an inconsistent state because we only ack after successful application).

### Step 4 — `ServerAssetCacheStore` + cursor persistence (~1d)

Two new SwiftData stores in `Sources/CairnIOSCore/SwiftDataStores.swift`:

```swift
@Model
final class StoredServerAsset {
    @Attribute(.unique) var checksumBase64: String
    var serverAssetId: String                  // for delete lookups
    var originalFileName: String
    var livePhotoVideoId: String?
    var deletedAt: Date?
    var visibility: String
    var isFavorite: Bool
    var type: String
    var fileCreatedAt: Date?
    var fileModifiedAt: Date?
    var width: Int?
    var height: Int?
    var lastUpdatedAt: Date
}

@Model
final class StoredSyncAck {
    @Attribute(.unique) var entityType: String  // SyncEntityType.rawValue
    var ack: String
    var savedAt: Date
}
```

Both go in the per-server (per-(URL, userId)) SwiftData container. The asset cache scales with server-asset count; the ack store is bounded (one row per entity type, ~5 rows max for cairn).

New protocols in `Sources/CairnCore/` (so the engine can consume from either source):
- `ServerAssetSnapshotStore` — `func snapshot() async throws -> [Checksum: ServerAsset]`, `func size() async throws -> Int`
- `SyncAckStore` — `func ack(for: SyncEntityType) async throws -> String?`, `func setAck(_:for:)`, `func clearAll()`

iOS impls in `Sources/CairnIOSCore/SwiftDataStores.swift`. Tests for both in `Tests/CairnIOSCoreTests/SwiftDataStoresTests.swift`:
- Bulk upsert of N assets, snapshot returns them.
- Delete by serverAssetId removes the row.
- Ack round-trip per entity type, multiple types coexist.

Helper on `ServerAssetCacheStore`: `applyEvents(_ events: [SyncEvent]) -> AppliedSummary` that translates the event list into upserts/deletes in one transaction. Returns counts for journaling.

### Step 5 — `ServerAssetSyncCoordinator` and reconciler integration (~1–1.5d)

New file: `iOS/App/ServerAssetSyncCoordinator.swift`

Responsibility:
1. Decide whether to bootstrap (cache empty) or stream-only.
2. On bootstrap: call existing `client.searchAllAssets()`, write all into cache, then immediately request a `sync/stream` to capture anything that happened during seeding. No `reset: true` — we just want the cursor to start moving forward.
3. On steady-state: call `client.syncStream(types: [.assetV1, .assetDeleteV1])`, accumulate events, apply to cache in batches of ~100, ack the batch via `client.ackSync(_:)`. Loop until the stream emits `SyncCompleteV1` for both requested types.
4. On `missingScope` error: log + bail. Caller falls back to legacy `searchAllAssets()` path.

Modify `iOS/App/AppDependencies.swift`'s `performLiveReconciliation`:
- Before calling the engine, call `coordinator.syncToCache()`.
- If sync succeeds: feed `serverAssetCacheStore.snapshot()` into the engine.
- If sync fails with missing-scope or stream error: fall back to current `searchAllAssets()` path and log.

The fallback is the safety net during rollout; we keep it for at least one release after `sync/stream` lands so users who haven't regenerated their API key keep working.

Feature flag (initial): a `CairnSettings` field `useIncrementalServerSync: Bool = true` (default on after one release of soak-testing). Settings → Advanced → toggle to opt out during the trial period.

### Step 6 — Tests (~1d)

In addition to the per-step unit tests above:

- `Tests/CairnIOSCoreTests/ServerAssetSyncCoordinatorTests.swift` (new) — using a fake `ImmichClient` that returns a scripted stream:
  - Empty cache + scripted stream of 50 AssetV1 events → cache has 50 entries, acks recorded per entity type.
  - Pre-seeded cache + scripted stream with 5 inserts + 3 deletes → final cache reflects the deltas, acks advance.
  - Stream interrupted mid-batch → partially applied events stay, last-good ack is what we'd resume from (idempotency property).
  - Missing-scope 403 → coordinator throws `.missingScope`, doesn't corrupt cache.
- One integration test (run manually for now) against a local Immich: bootstrap, modify some assets server-side via the API, sync again, verify the cache reflects the changes.

## Risks and open questions

1. **Stream timeout on huge initial bootstrap.** A first-time stream against a 200k-asset library could keep the HTTP connection open for minutes. URLSession's default timeout is generous but not unlimited; we may need to pass a request with `timeoutInterval = 60*30` or use `URLSessionConfiguration.timeoutIntervalForResource`. To check empirically before merging — the bootstrap path is the painful case but only runs once per partition.

2. **What happens if the stream closes mid-batch?** Per the design, we ack only after successful disk write. So a partial stream leaves the cache consistent with the acks we did write. Next call resumes from the last-good ack. Verify by interrupting the integration test and observing recovery.

3. **API key scope migration.** Existing users will not have `sync.*` scopes. The fallback to `searchAllAssets()` makes this a soft failure (slower sync, same correctness). Surface a one-shot "your API key is missing scopes — regenerate to get faster syncs" banner on Status when we detect the missing-scope case. Don't force the upgrade.

4. **`SyncAssetV1.checksum` encoding.** Need to verify whether the streamed checksum is base64 (matches `AssetResponseDto.checksum`) or hex. Reading `services/sync.service.ts` should answer this. If it's a different encoding from what the engine expects, the cache adapter normalizes.

5. **Visibility filtering.** `SyncAssetV1.visibility` is one of `timeline|hidden|archive|locked`. The existing `searchAllAssets` iterator includes all non-locked visibilities. Mirror that in the cache adapter — don't filter at write time, filter at read time when feeding the engine, so a visibility change (e.g., user marks an asset hidden) doesn't require a delete-then-re-insert in the cache.

6. **`isEdited` and the edit-handling story.** The existing reconciler treats edits via `EditRetirementStore` first-observed semantics on the iOS side. The stream gives us per-asset `isEdited` and `fileModifiedAt` from the server. Verify these don't unintentionally feed the iOS-side edit-protect logic in a way that double-counts. Cross-reference with the "Edit semantics" section in CLAUDE.md before wiring.

7. **Server schema drift.** The plan assumes the v2 schema is stable. Recent Immich releases churned through breaking changes; pin the cairn implementation to a specific server min-version. We already have a checked-out copy of the server source at `/Users/graham/code/immich` (HEAD `be1b9a5` when last refreshed per `CLAUDE.md`) — verify all referenced symbols still exist at HEAD before merging.

## Acceptance criteria

- A fresh `cairn` install on a 5k-asset Immich instance bootstraps via `searchAllAssets` once, populates the cache, and subsequent syncs only stream (verified via Console logs showing one `[cairn.sync] /api/sync/stream` call per sync vs. ~20 `/api/search/metadata` calls in the prior path).
- A user whose API key is missing `sync.*` scopes can still sync — the legacy path takes over silently, and a one-shot Status banner explains how to upgrade.
- The reconciliation engine produces identical candidate sets whether fed from `searchAllAssets` or `serverAssetCache.snapshot()` (correctness test via direct comparison on a fixture library).
- The cache survives app relaunches (SwiftData persistence works; ack store survives too).
- `swift test` passes; all new unit tests pass.

## Out of scope (for this work)

- Album / face / memory / exif sync. Cairn doesn't need them. The `types` filter keeps them off the wire.
- Conflict resolution between local and server state. The stream is server → client only; we don't push.
- Multi-device cache coherence. Each device runs its own coordinator with its own acks.
- Server-side reset UI. Users who want to force a re-stream can toggle the feature flag off and back on (which calls `DELETE /api/sync/ack` internally).

## File-by-file change summary

New files:
- `Sources/CairnCore/SyncEntities.swift`
- `iOS/App/ServerAssetSyncCoordinator.swift`
- `Tests/CairnCoreTests/SyncEntitiesTests.swift`
- `Tests/CairnCoreTests/ImmichClientSyncStreamTests.swift`
- `Tests/CairnIOSCoreTests/ServerAssetSyncCoordinatorTests.swift`

Modified files:
- `Sources/CairnCore/ImmichClient.swift` — stream + ack methods, new error case.
- `Sources/CairnCore/CairnSettings.swift` — `useIncrementalServerSync` feature flag.
- `Sources/CairnIOSCore/SwiftDataStores.swift` — `StoredServerAsset`, `StoredSyncAck`, impl actors.
- `iOS/App/AppDependencies.swift` — wire coordinator into `performLiveReconciliation`.
- `Sources/CairnIOSCore/UI/SetupScreen.swift` — onboarding scope copy.
- `Sources/CairnIOSCore/UI/SettingsScreen.swift` — Advanced section feature-flag toggle.
- `README.md` — scopes list.
- `iOS/fastlane/metadata/en-US/description.txt` — if it carries the scopes list.
- `CLAUDE.md` — "Tag schema (v1)" section update.
- `Tests/CairnIOSCoreTests/SwiftDataStoresTests.swift` — new store tests.

Approximate touched-LOC estimate: ~600–900 net new lines including tests.
