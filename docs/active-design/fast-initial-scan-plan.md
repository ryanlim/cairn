# Fast initial scan via Immich `deviceAssetId`

Planning document for short-circuiting cairn's initial-hash pass when
the local asset was uploaded to Immich from this same phone.

Written 2026-05-29. Status: design; ready to execute.

## Architectural prerequisites — verified

1. **`ReconciliationEngine` tolerates a partial `LocalHashStore`**. The
   engine takes `currentLocalChecksums: Set<Checksum>` derived from the
   live phone library; uncached assets simply don't appear, which is
   treated as "not yet hashed," not as "deleted." Missing entries on a
   phone-delete event yield empty `removedChecksums` (PhotoKitPersistent-
   ChangeReconciler.swift:614-623). Orphan sweep runs unconditionally
   and re-stamps recoverable checksums. Conclusion: phase-1 imputed
   checksums become operative immediately; phase-2 residue completes
   incrementally without false-delete risk.
2. **`CairnAppModel.SyncPhase` already supports multi-stage narration**
   (`.preparing` → `.fetchingServer` → `.hashing` → `.reconciling` →
   `.finalizing`). Add a `.imputingFromServer` phase between
   `.fetchingServer` and `.hashing`. `transitionSyncPhase(to:at:)`
   already wires phase changes through the activity feed.
3. **`InitialScanScreen` is the rendering surface**. It already shows
   `hashed/total/indexed/deferredQueueCount`. We add a separate counter
   for imputed assets (visually distinct from the locally-hashed
   counter) and adapt the progress bar to either stack the two sources
   or show two adjacent bars.

## UX principle

Honestly surface what was done via which method and what is left.
Both paths (fast-imputed and locally-hashed) get visual + textual
indication; the user can always tell which subset is which. The
toggle in onboarding explains both paths so users opt in (or out)
deliberately.

---

## Goal

When cairn runs its first scan against a server, it currently hashes
every local asset on the device to build the `localId → SHA1`
mapping that `LocalHashStore` needs. For users with iCloud Optimized
Photos, every uncached asset triggers an original download. A 5,000-
asset library can take hours.

We want a shortcut path: for assets that Immich already has and was
uploaded from this phone, trust the server's checksum instead of
recomputing it. Only hash the residue.

## Background and motivation

Immich's mobile uploader stamps `deviceAssetId =
PHAsset.localIdentifier` on every upload, exposed on the asset API.
For a user who has been backing up this phone to this Immich server,
the intersection `{phone.localId} ∩ {server.deviceAssetId}` is large
— often "almost everything."

The server already computed SHA1 for those uploads. If we trust those
checksums, the initial scan collapses to:

1. Pull the server's asset list (already done by the discovery layer).
2. Join `phone.localId == server.deviceAssetId` for non-trashed rows.
3. Record `(localId, server.checksum)` in `LocalHashStore` with an
   `unverified` flag.
4. Hash only the residue (phone localIds with no server match, or
   ambiguous matches).

For a typical user, this drops initial scan from "hours, pulling from
iCloud" to "seconds for the residue."

## What we trust and what we don't

**The checksum we cache from the server is only used as a lookup
key.** When the user later deletes a phone asset, cairn does:

1. Phone-delete event for `localId = ABC`.
2. Look up cached `ABC → SHA1 = X`.
3. Find server row(s) with `checksum = X`.
4. Call `DELETE /api/assets` on the match.

If the cached checksum is wrong (server-side hash never matched what
the phone currently stores), the lookup at step 3 might:

- Find no server row → false miss, asset persists on server (safe; the
  user can delete via Immich UI).
- Find the wrong server row → cairn deletes a different asset than
  intended. That asset goes to Immich Trash (30-day undo). Recoverable.

Worst case is recoverable but ugly. We mitigate with:

- **Unambiguity requirement** at join time (below).
- **Edit-driven automatic re-hash**: the existing modDate-skip path in
  `hashAllCurrentAssets` re-hashes any asset whose `modificationDate`
  advances. If the user edits a photo (changes pixel bytes) on the
  phone, the cached imputed entry is replaced with a freshly-computed
  checksum and the imputed flag is cleared. This catches the most
  important class of mismatch automatically.
- **Background verifier** *(future)*: periodic pass that re-hashes a
  sample of imputed entries each run (throttled, opportunistic).
  Converts imputed → verified over weeks for assets that never get
  edited. Implementation deferred — adds telemetry now, verifier later.
- **Deletion-time verification is impossible**: by the time a
  phone-delete event fires, the asset is already gone from PhotoKit —
  no resource to re-hash. The cached checksum (imputed or verified)
  is what we have. Telemetry logs the imputed-deletion count so
  problematic patterns surface in support bundles, but there is no
  pre-trash verify gate.

## Unambiguity requirement

Immich's schema has a unique constraint on `(ownerId, deviceId,
deviceAssetId)`, so dupes are guaranteed not to exist *within a single
device's uploads*. But:

- `deviceId` rotates when the Immich app is reinstalled. A user who
  reinstalled and re-uploaded has multiple non-trashed rows with the
  same `deviceAssetId` and different `deviceId`. cairn can't tell
  which is "current."
- Trashed/restored sequences can also leave duplicate `deviceAssetId`
  values across rows.

**Rule**: the join must produce exactly one non-trashed server row
for a given `phone.localId`. If 0 or >1 rows match, fall back to
hashing that localId. The check is one line and catches the reinstall
case cleanly.

## Near-zero-hit fallback

A phone restored from a backup gets fresh `localIdentifier` values for
every asset. If the join hits ~0% of a non-empty library, the whole
optimization is moot and would produce thousands of false misses.

**Rule**: after the join, if `hits / total_phone_assets < threshold`
(suggested: 5%) on a library of more than ~100 assets, disable the
fast path for this run and fall back to full hashing. The cost is one
join attempt; the upside is a clean degradation when the user is in a
fresh-phone state.

## Surfacing

- **Default**: off. The optimization is a meaningful tradeoff (much
  faster setup vs. every checksum computed by cairn itself); the user
  picks at onboarding rather than getting it silently. The onboarding
  step presents both paths neutrally so the choice is informed.
- **Diagnostics screen**: show counts for `trusted` vs `hashed` vs
  `verified` entries in `LocalHashStore`. Power users can audit.
- **Settings action**: "Verify cached checksums" to force a full
  re-hash pass. Useful after a major library change.
- **Telemetry-grade log**: emit a one-line summary at end of initial
  scan — `(N matched, M hashed, K ambiguous, T fallback)` — so users
  reporting weird behavior have something concrete to share.

## Implementation sketch

Touchpoints, in rough order:

1. **`LocalHashStore`** — add `unverified: Bool` to the stored
   entry shape. SwiftData lightweight migration (defaulted field).
2. **`InitialScanCoordinator`** (or wherever the first-scan path
   lives) — before hashing, fetch the server's asset list, build a
   `[phone.localId: server.checksum]` map respecting the
   unambiguity + non-trashed filters, and seed `LocalHashStore` with
   `unverified = true` for hits.
3. **Hashing pass** — runs only over the residue (phone assets not in
   the trust map).
4. **`PhotoKitPersistentChangeReconciler`** — after resolving
   deleted localIds → checksums, log the count of deletions that
   came through imputed entries. This is a telemetry signal, not a
   gate; the existing flow still proceeds.
5. **Background re-hash pass** *(future)* — opportunistic,
   batch-throttled (say N per minute when foregrounded, M per
   scheduled refresh when backgrounded). Re-hashes imputed entries
   for assets still alive in PhotoKit, calls `set` on match (clears
   imputed flag), logs + overwrites on mismatch. Deferred — the
   edit-driven path catches the most important class of mismatch
   automatically.
6. **Settings screen** — add "Verify cached checksums" row and a
   diagnostics-section counter.
7. **Telemetry/log line** — at end of initial scan.

## Open questions

- **Mismatch policy on background re-hash**. If we discover a
  trust-matched entry whose real SHA1 doesn't match the server's, what
  do we do? Options: (a) overwrite cache with the correct hash and
  move on (the trust was wrong, the new value is right), (b) flag the
  asset for user review (the divergence is suspicious), (c) drop the
  cached entry and let normal flow re-discover. (a) is simplest; (b)
  is safest if we suspect Immich bugs. Default to (a) and add a
  counter to the diagnostics screen.
- **Should the toggle be exposed in Settings?** Off-by-default would
  preserve the "always hashes locally" mental model for users who
  prefer it. On-by-default is the actual UX win. Lean on-by-default
  with the Settings toggle as an escape hatch.
- **First-scan-only vs ongoing**. The optimization is described for
  initial scan, but the same trust path could apply when a brand-new
  localId appears after the first scan (newly added phone asset that
  was also uploaded). Probably yes — same safety story — but verify
  the reconciler flow doesn't assume "new localId always needs
  hashing" before relying on it.
- **What about photos the phone never uploaded?** A photo on phone
  that exists nowhere on the server: must be hashed (no trust
  shortcut). The residue case. Cost is unchanged from today; this
  optimization is purely additive for the matched subset.

## Out of scope for v1

- Filename + timestamp heuristic matching for the residue. Discussed
  and rejected: filenames collide (`IMG_0001.HEIC` across devices and
  years), timestamps collide in bursts. `deviceAssetId` is the only
  precise signal.
- Trusting checksums from non-Immich sources (e.g., if cairn ever
  supports other backup targets). Not in scope.
