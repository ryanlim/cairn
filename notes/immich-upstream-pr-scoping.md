---
title: Upstreaming cairn's deletion-propagation to Immich mobile — PR scoping notes
date: 2026-05-29
status: research; no PR opened
---

# Upstreaming cairn to Immich mobile — PR scoping notes

Working notes from a research pass on what it would take to land cairn's
core function (phone-deletion → server-trash propagation) inside the
upstream Immich mobile app, instead of shipping it as a separate
companion.

These notes capture two research agents' findings and the analytical
correction that came out of comparing them. They are scoping notes, not
a design doc; if/when this is pursued, expect to re-verify against
current Immich `main` since the codebase moves fast.

## Why this came up

- Immich has a long-running open issue (#4341) requesting exactly this
  feature; 2.5+ years with no maintainer action.
- Documented public stance from the team has been conservative on
  delete-direction features: "Immich deals with important data and we
  don't want to risk a bug accidentally deleting all of it."
- cairn already implements the safe version of this. Shipping it
  upstream would close the gap for the ~all users who never find cairn.

## The corrected scope conclusion

Two agents returned different scope estimates. Reconciling them:

- **Agent 1** (~450–550 net Dart lines): "Drop the Android-only gate,
  lean on iOS Recently Deleted for a free 30-day quarantine, no custom
  table needed."
- **Agent 2** (~800–1,200 net Dart lines): "Add a dedicated
  `pending_server_trash` Drift table; quarantine state lives in the
  app, not in the platform."

**Agent 1's claim doesn't hold.** iOS Recently Deleted and cairn's
14-day quarantine solve different problems:

- Recently Deleted = local-library undo. After the user taps Delete in
  Photos.app, the phone copy is restorable for 30 days.
- cairn's quarantine = server-side propagation gate. After the app
  *observes* the delete event, it waits 14 days before calling
  `DELETE /api/assets` so the server copy isn't touched if the user
  reverses the phone delete.

Without an app-side quarantine table, the Immich app has to either:

1. Propagate immediately, accepting that an "oops" restore is a
   two-step process (restore from Recently Deleted on phone → separately
   restore from Immich Trash on server), or
2. Re-implement cairn's 14-day gate, which requires the same Drift
   table Agent 2 proposed.

The maintainers' documented caution about delete features strongly
implies they'd want option 2, even if a contributor opened with option
1. So **Agent 2's scope is the realistic minimum**, and the PR should
volunteer the quarantine table from the start rather than have it asked
for in review.

## Proposed PR shape (Agent 2's version)

Total scope: **~800–1,200 net lines**, with **~830 hand-written Dart**
and the rest Drift-generated (`*.g.dart`).

### New files

- `lib/domain/models/pending_server_trash.model.dart` — domain model for
  a queued server-trash propagation: `(localId, remoteId, checksum,
  observedAt, eligibleAt)`.
- `lib/infrastructure/repositories/pending_server_trash.repository.dart`
  — Drift-backed CRUD on the new table; `enqueue`, `dequeueEligible`,
  `cancelByLocalId` (the "user restored from Recently Deleted" path).
- `lib/domain/services/server_trash_propagation.service.dart` — the
  reconciler: watches PhotoKit `deletedLocalIdentifier` events on iOS,
  enqueues entries with `eligibleAt = now + quarantine`, and on a
  periodic tick calls `DELETE /api/assets` for entries past `eligibleAt`.
- `lib/providers/server_trash_propagation.provider.dart` — Riverpod
  wiring.
- Drift table definition (likely co-located in
  `lib/infrastructure/repositories/db.dart` alongside existing tables).

### Modified files

- `lib/services/background.service.dart` — register a recurring tick
  that invokes the propagation service (analog of cairn's background
  refresh).
- `lib/services/cleanup.service.dart` — currently the
  *Android-only* delete-propagation path. Add the iOS branch through
  the new service rather than `PhotoManager.editor.deleteWithIds`
  directly.
- Settings UI — add a single toggle "Propagate iPhone deletions to
  server (with 14-day delay)", off by default.
- Localization files (`.arb`) — strings for the toggle, the quarantine
  countdown, the restore-from-Recently-Deleted cancellation.
- Drift schema version bump + migration step (empty new table; no data
  migration needed).

### What stays out of scope for the first PR

- No equivalent of cairn's "viewed-photo bypass quarantine" — a v2
  feature.
- No mass-delete safety rail (percent-threshold abort) — a v2 feature.
- No dedicated "Pending review" screen — first PR just shows the
  pending count in Settings; full review UX is a follow-up.
- No re-implementation of cairn's identity model (SHA1 fallback, modDate
  re-hash suppression). Immich already has hashing infrastructure;
  reuse it.

### Reviewability

Both agents agreed the PR is **eyeballable end-to-end by a non-Dart
reader**. The Drift-generated code is mechanical; the hand-written
~830 lines are small enough for a single review pass. The service
file (~200 lines) carries the safety story.

## Social-friction estimate

- Best case: maintainer accepts the design in principle, asks for
  scope cuts and an opt-in flag. Merge in 2–3 review rounds.
- Likely case: maintainer asks for a design discussion in Discord
  before the PR. The 14-day default, the toggle copy, and the
  background-tick cadence become bikeshed surfaces.
- Worst case: maintainer declines on principle (the documented
  position is unchanged in 2.5 years). PR closes, but the design
  doc lives on as a reference for the next person who asks.

The Discord-first path is probably the right opener — drops the cost
of a "no" from a wasted PR to a wasted message.

## Re-verification checklist (if/when pursued)

These were correct at the time of research but Immich's codebase
moves; verify before committing:

- [ ] `CleanupService.deleteLocalAssets` still exists and is the
      Android-only entry point.
- [ ] `PhotoManager` (the `photo_manager` package) still exposes
      `addImageChangeObserver` / equivalent for iOS PhotoKit change
      events.
- [ ] Drift migration story hasn't changed (schema version + step
      function).
- [ ] Riverpod is still the DI/state-management story (no migration
      to a different framework underway).
- [ ] The asset table's `(localId, remoteId, checksum)` tuple is still
      the identity model — the propagation service needs all three.
- [ ] Issue #4341 hasn't been closed or superseded.

## Related: fast initial scan via `deviceAssetId`

A separate cairn-side optimization came out of this research: trust
Immich's checksums for assets where `phone.localId ==
server.deviceAssetId`, instead of re-hashing locally during initial
scan. Full design in
[`docs/active-design/fast-initial-scan-plan.md`](../docs/active-design/fast-initial-scan-plan.md).
Not specific to upstreaming — applies to cairn as it ships today.

## Open design questions for the Discord conversation

1. **Default quarantine window**: cairn ships 14 days. Is that the
   right default for upstream, or do maintainers want 30 (matching
   iOS Recently Deleted, simpler mental model)?
2. **Opt-in vs opt-out**: cairn is opt-in by virtue of being a
   separate app. Upstream needs a deliberate "off by default" with a
   prominent first-run prompt; design that flow before writing code.
3. **Where the pending count surfaces**: cairn has a dedicated
   PendingReviewScreen. Upstream's first version probably folds into
   the existing "Manage storage" or settings area; full UX is a
   follow-up.
4. **Identity model edge cases**: cairn's iCloud-Optimized-Photos
   distinction (don't propagate evictions, only user-initiated
   deletes) needs to be implemented at the PhotoKit-event-handling
   layer. Verify Immich's existing PhotoKit integration exposes the
   distinction or that we can fetch it directly.
