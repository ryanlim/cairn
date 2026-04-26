# Refactor backlog

Findings from code review rounds that aren't worth fixing immediately but deserve a record. Intentionally deferred — each entry includes why.

Conventions:
- **Impact:** rough estimate of value if fixed (high / medium / low).
- **Cost:** rough estimate of work required.
- Cite file:line where useful so a future session can jump straight in.
- Mark items `[done]` and link to commit when addressed; don't delete.

---

## Cache coverage gap

### `[done]` Untracked assets — visible in PhotoKit but not in cache and not in deferred queue
**Impact:** medium — silently ignored assets won't be candidates for trash even when the user deletes them. UX-confusing because the Status banner shows `indexed < total` without a clear explanation.
**Cost:** low–medium — one new sweep at sync time.

Empirical case (2026-04-26): user reports `7158 visible, 6713 indexed, 215 above cap, 0 queued`. That leaves `7158 - 6713 - 215 = 230` assets that are in PhotoKit but neither in `LocalHashStore` nor in `DeferredHashStore`. cairn has no record of them.

Possible causes: a stale `CAIRN_ASSET_CAP` debug env var, an interrupted full enum that never reached the tail, race conditions where a PhotoKit insert event was dropped, or assets created via paths the change observer missed.

The orphan sweep catches the inverse direction (cache id no longer in library). We need a sibling sweep for "library id not in cache and not in deferred-queue" that adds the unknowns to `DeferredHashStore` (or directly schedules them for hashing) so they enter the normal pipeline. File: `Sources/CairnIOSCore/PhotoKitPersistentChangeReconciler.swift` `reconcileCacheAgainstLibrary` already does the cache→library diff; mirror it for the library→cache direction.

Status banner now distinguishes the three buckets (`queued / above cap / not yet processed`) so the user can at least *see* the gap, but auto-recovery is the proper fix.

**Resolved 2026-04-27**: `discoverUntrackedAssets` runs at the top of `runIncremental`, computing `liveIds.subtracting(cacheIds).subtracting(deferredIds)` and folding the result into `insertedIds` so the existing hash + ever-seen + metadata pipeline picks them up. Soft-limit / hard-ceiling / timeout behavior is preserved (large items still defer correctly). `Result.untrackedDiscovered` surfaces the count for diagnostic logging. Pure set logic factored as `untrackedFromLibrary(liveIds:cacheIds:deferredIds:)` and unit-tested.

---

## Edit-retirement metadata coverage

### PhotoKit edited-resource filename consistency
**Impact:** medium — when divergent, OrphanReconciler can't match an edited-then-deleted-fast asset against its server counterpart.
**Cost:** low — investigation + a normalization pass in `OrphanReconciler.match`.

cairn's `selectPrimaryResource` prefers `.fullSizePhoto` over `.photo` for edited assets — same as Immich's mobile pick (`isCurrent`). The recorded `originalFileName` in `LocalAssetMetadataStore` should therefore equal the `originalFileName` that lands in `ServerAsset` from Immich's upload metadata.

But: PhotoKit's `.fullSizePhoto.originalFilename` can be `"FullSizeRender.HEIC"` (a synthesized name) on some iOS versions, while Immich's mobile app passes `dto.filename` from a different source that may resolve to the original `IMG_NNNN.HEIC`. Empirically observed (2026-04-26): a user's two server copies of the same edited photo both showed `IMG_3787.heic` via Immich's API — but cairn's eager observer-time recording used `selectPrimaryResource`, which on this device produced the same name (presumably PhotoKit preserved the filename here). Other devices/iOS versions may differ.

Fix when encountered: add filename normalization to `OrphanReconciler.match` — strip known synthesized prefixes (`FullSizeRender`, `IMG_E*`, etc.) before comparing, OR record BOTH the `.photo` and `.fullSizePhoto` filenames in `LocalAssetMetadata` and try each. Wait until a real on-device case fails so the normalization is data-driven rather than speculative. File `Sources/CairnCore/OrphanReconciler.swift` (the case-insensitive filename match at lines 70–73 and 82) is the exact spot.

---

## Error handling

### `[done]` Surface partial failures in destructive operations
**Impact:** medium — silent inconsistency between in-memory model state and on-disk stores.
**Cost:** medium — needs a "warnings" surface (banner or toast) and a logger plumbed through several actions.

`signOut`, `resetIndex`, `clearJournal`, `startOverInitialScan`, `rescanLibrary` all use `try?` for every store clear. If one of N store clears fails, the model is reset but the persistent store still has data — next sync rebuilds against the leftover data and the user has no indication anything went wrong. Touches `iOS/App/AppDependencies.swift` lines ~1279, 1303, 1313, 1374-1378.

**Resolved 2026-04-27** (commit `c6cfe64`): new `aggregateClears` + `summarizeClearFailures` helpers; per-site `do/catch` around the throwing operation; `model.lastError` set with a labeled summary on partial failure. Success toast suppressed when failures occur. `clearJournal` treats ENOENT as success (file simply wasn't there).

---

## Test coverage gaps

Most are flagged in the code review reports under `docs/` (none committed yet — paste from session if needed). Highlights:

### `[done]` Orchestrator error paths
**Impact:** high (destructive paths) but **likelihood:** low.
**Cost:** medium — needs additional `MockHTTP` fixtures.

**Resolved 2026-04-27** (commit `031f295`): +13 tests across `TrashOrchestratorTests` + `RestoreOrchestratorTests`. Pinned journal sequencing under each failure ordering. Surfaced three real bugs as TODOs (not fixed): RestoreOrchestrator over-claims success on `POST /api/trash/restore/assets` 204 for nonexistent IDs; empty `explicitIds` set silently succeeds; `bulkTagAssets` 500 leaves an orphan `cairn/v1/run/<id>` tag on the server.

### `[done]` `ImmichClient` HTTP error mapping
**Impact:** medium — affects how user-facing alerts are categorized.
**Cost:** low — `MockHTTP` infrastructure exists, just needs additional fixtures.

**Resolved 2026-04-27** (commit `031f295`): +6 tests covering 401/403/500/503 plus pagination retry (success-after-failure and exhaustion). `describeSyncError` lives in the iOS app target so couldn't be exercised from `CairnCoreTests`; status-code → user-message mapping is documented in test names instead.

### `[done]` `CairnExportPayload` round-trip
**Impact:** medium — silent corruption on import is hard to detect.
**Cost:** low.

**Resolved 2026-04-27** (commit `031f295`): +9 tests in new `CairnExportPayloadTests`. Round-trips full + minimal payloads, future-version rejection, optional-field decoding, unknown-field forward-compat. Added `Equatable` conformance (auto-synthesized) for direct struct comparison in tests.

### `[done]` `apiKeyInfo()` + `assetStatistics()`
**Impact:** medium — these silently fail today (`try?`) so a regression goes unnoticed.
**Cost:** low — straightforward HTTP mock fixtures.

**Resolved 2026-04-27** (commit `031f295`): +13 tests covering both endpoints' success/auth-failure/server-error/malformed-JSON paths, plus the `isTrashed` query-param flow on `assetStatistics`. The `x-api-key` header path on `assetStatistics` is pinned separately because it builds `URLRequest` directly rather than via `makeRequest`.

### `JournalReader` edge cases
**Impact:** low — display artifacts only.
**Cost:** low.

Malformed `runId`, zero timestamps, wholly-corrupt rows. The reader is forgiving by design; tests should pin the forgiveness.

---

## API surface and naming

These are subjective; collect them and address as a single sweep when they accumulate enough mass to justify the churn.

### Vocabulary inconsistency: insert vs union vs record vs set
**Impact:** low — code is readable as-is.
**Cost:** medium — rename touches every store call site.

`ExclusionStore.insert`, `EverSeenStore.union`, `LocalAssetMetadataStore.record`, `LocalHashStore.set` all do "merge additions." A unified vocabulary (probably `upsert` or `merge`) would reduce cognitive overhead. Defer until more stores ship or the protocols stabilize.

### Plurality inconsistency in parameter names
**Impact:** low.
**Cost:** medium — touches many call sites.

`assetIds` (abbreviated) vs `localIdentifiers` (full word) vs `checksums` (full word) vs `filenames` (full word). Pick one (probably full words) and rename. Would touch most action signatures.

### `record(_:)` singular/plural overload risk
**Impact:** low — could become medium if a future caller picks the wrong one in a tight loop.
**Cost:** low — one rename.

`LocalAssetMetadataStore.record(_ entry:)` and `record(_ entries:)` are easy to confuse. If a caller passes a single entry to the bulk overload it's fine, but the reverse (looping `record(entry)` per item) defeats the batching. Rename the bulk version to `recordBatch(_:)` or rely on the Sequence overload.

### Default protocol impl warnings buried in protocol-level docstrings
**Impact:** low — informational.
**Cost:** trivial.

`LocalHashStore.indexedCount()`, `allLocalIdentifiers()`, `allChecksums()` all have default impls that materialize the full snapshot. The "should override" warning is in the protocol's umbrella comment; future implementers reading just the method's docstring won't see the perf caveat. Move the warning to each method's docstring.

---

## Code structure

### `CairnAppActions` boilerplate proliferation
**Impact:** medium for maintainability, low for users.
**Cost:** medium — would change the action wiring pattern.

Action closures repeat `[weak self] / await MainActor.run { } / try await ... / await MainActor.run { … }` 15+ times. Extracting a small `withSelf<T>(_ body: @MainActor (Self) async throws -> T) -> T` helper or making each action an instance method on `AppDependencies` would cut the boilerplate. The risk: less explicit threading than the current pattern. Defer until a real bug lands here.

### Action callback proliferation on screens
**Impact:** low.
**Cost:** medium.

`StatusScreen.init` takes ~25 closure parameters. Some clusters could be folded into a single "actions" struct passed by the host (similar to `CairnAppActions` but per-screen). Defer until it becomes visibly painful to thread a new closure through.

### `unconfirmedByRestoration` field unused
**Impact:** low.
**Cost:** low — but it's part of a public Result struct, so removing it is a breaking change.

`PhotoKitPersistentChangeReconciler.Result.unconfirmedByRestoration` is computed and returned but never read by callers. Either wire it to inform deferred-queue cleanup (skip re-hashing items that just came back from Recently Deleted) or remove and bump the type's visibility/version.

---

## Performance

### `confirmed.snapshot()` for `quarantineCount`
**Impact:** low — `ConfirmedDeletedStore` is small (tens to hundreds of entries).
**Cost:** low.

`refreshQuarantineCount` materializes the full snapshot just to filter by date and count. A `count(within: TimeInterval)` aggregate query would be cheaper, but the store is small enough that the perf difference is negligible. File: `iOS/App/AppDependencies.swift` lines ~665-674.

### `exclusion.snapshot().keys` for membership checks
**Impact:** low — `ExclusionStore` is typically tens of entries.
**Cost:** low.

Several call sites read `try await exclusions.snapshot()` and only consume `.keys`. A `checksums()` keys-only method would skip materializing the metadata, but the performance gap is negligible.

### `DeferredQueueSheet` sequential thumbnail requests
**Impact:** low — list is typically small (queue is bounded).
**Cost:** medium — needs `PHCachingImageManager` plumbing.

The sheet fetches thumbnails one at a time via `PHImageManager.default()`. For a queue of 50+ items the perceived latency is real, but most users will see <10. Defer.

### Sort + cap pattern in full enumeration
**Impact:** low.
**Cost:** trivial.

`runFullEnumeration` sorts the asset array then takes the first N (testing cap). Cap before sort would save sort work on the discarded tail. Trivial fix; deferred because the testing cap path is dev-only.
