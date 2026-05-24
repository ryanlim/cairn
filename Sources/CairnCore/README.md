# CairnCore

The portable engine layer. Pure Foundation + CryptoKit — no PhotoKit,
SwiftData, Keychain, UIKit, SwiftUI, or BackgroundTasks. Apple-only
APIs live behind protocols defined here; concrete implementations live
in `Sources/CairnIOSCore`. A future Kotlin port would re-implement
the same protocols against Android equivalents (MediaStore, Room, the
Android keystore, etc.) without touching this directory.

The files cluster into five rough groups. Listed here so you can
navigate without learning every name first.

## Primitives + settings

The shared vocabulary every other file uses.

- **[`Types.swift`](Types.swift)** — `Checksum`, `ServerAsset`,
  `AssetVisibility`, `RunID`, and the rest of the cross-module value
  types.
- **[`CairnSettings.swift`](CairnSettings.swift)** — user-tunable
  configuration with custom Codable migrations. New fields land here
  with a `decodeIfPresent ?? defaults.X` line so legacy on-disk
  payloads decode cleanly.
- **[`CairnExportPayload.swift`](CairnExportPayload.swift)** — the
  shape of the user-facing export/import bundle.

## State stores (protocols + the CLI's JSON impls)

The persistent state cairn keeps about the local library and the
user's intent. Each file defines a `Sendable` protocol that the iOS
side implements against SwiftData; many also include a
`JSONFile*Store` for the CLI to use directly.

- **[`ObservedStore.swift`](ObservedStore.swift)** — every SHA1 cairn
  has ever observed on this device. The "ever-seen" set that
  distinguishes user-deleted from never-observed. Carries album tags
  for scope-aware indexing — read the protocol's "Write-API decision
  guide" before touching writers.
- **[`ConfirmedDeletedStore.swift`](ConfirmedDeletedStore.swift)** —
  per-checksum confirmation timestamps that start the quarantine clock.
  First-write-wins.
- **[`ExclusionStore.swift`](ExclusionStore.swift)** — user-protected
  checksums. Survives index resets.
- **[`EditRetirementStore.swift`](EditRetirementStore.swift)** —
  first-observed SHA1 anchoring per `localIdentifier`. Critical for
  edit handling; see ARCHITECTURE.md's "Edit semantics" section.
- **[`LocalHashStore.swift`](LocalHashStore.swift)** —
  `[localIdentifier: Set<Checksum>]` cache + modification dates.
  iOS-specific in practice (PhotoKit's `localIdentifier` is
  Apple-only); protocol lives here so a Kotlin port swaps in
  MediaStore URIs without changing the engine.
- **[`DeferredHashStore.swift`](DeferredHashStore.swift)** —
  background-drain queue for large iCloud-Optimized assets that
  exceed the foreground hashing budget.
- **[`DeletionSourceStore.swift`](DeletionSourceStore.swift)** —
  per-checksum mapping back to the `localIdentifier` that surfaced
  it. Powers per-source grouping in Pending Review.
- **[`LocalAssetMetadataStore.swift`](LocalAssetMetadataStore.swift)** —
  filename + creation date snapshot from PhotoKit, captured at
  observe time so the orphan reconciler can identify deleted assets
  after the PHAsset is gone.
- **[`PendingTrashIntentStore.swift`](PendingTrashIntentStore.swift)** —
  persistent retry queue for failed trash runs.
- **[`PersistentChangeTokenStore.swift`](PersistentChangeTokenStore.swift)** —
  the `PHPersistentChangeToken` snapshot used to drive incremental
  PhotoKit change reads.
- **[`StatusSnapshotStore.swift`](StatusSnapshotStore.swift)** —
  cosmetic status persistence so the Status screen has something to
  show on cold launch.
- **[`ServerAssetCacheStore.swift`](ServerAssetCacheStore.swift)** —
  per-(URL, userId) cache of Immich-side assets, populated
  incrementally via the `/sync/stream` coordinator.
- **[`SecretStore.swift`](SecretStore.swift)** — narrow protocol over
  the credentials cairn needs (server URL, API key, session token).
  iOS uses Keychain; CLI reads environment variables.

## The reconciliation engine

The pure-logic core: input goes in, the candidate breakdown comes
out, nothing about disks or APIs.

- **[`ReconciliationEngine.swift`](ReconciliationEngine.swift)** —
  the join. Takes ever-seen, current-local, server, confirmed-deleted,
  exclusions, and (optional) scope tags; emits the three candidate
  buckets (delete / pending-review / held-by-quarantine).
- **[`SafetyRails.swift`](SafetyRails.swift)** — the percent-cap +
  minimum-floor + empty-library guards that abort runs before they
  touch the server.
- **[`MissedDeletionFinder.swift`](MissedDeletionFinder.swift)** —
  server-side recovery scan: looks for assets that look like prior
  iPhone uploads cairn never observed.
- **[`OrphanReconciler.swift`](OrphanReconciler.swift)** — the safety
  net for back-channel deletions the persistent-change log missed.
- **[`Hashing.swift`](Hashing.swift)** — `CryptoKit.Insecure.SHA1`
  wrapper. SHA1 is mandatory because Immich's identity model accepts
  no other algorithm.

## API client + journal

The Immich-facing surface, plus the on-disk forensic trail.

- **[`ImmichClient.swift`](ImmichClient.swift)** — every Immich
  endpoint cairn touches. Single struct; per-method docstrings cite
  the server-side controller path.
- **[`ImmichThumbnailLoader.swift`](ImmichThumbnailLoader.swift)** —
  authenticated fetch + on-disk cache for asset thumbnails.
- **[`SyncEntities.swift`](SyncEntities.swift)** — Codable mirrors of
  Immich's `/sync/stream` wire types (`SyncAssetV1`,
  `SyncAssetDeleteV1`, the envelope decoder).
- **[`ServerAssetSyncCoordinator.swift`](ServerAssetSyncCoordinator.swift)** —
  drives the streaming sync loop: bootstrap vs incremental
  classification, batched apply + ack, per-batch logging.
- **[`TagSchema.swift`](TagSchema.swift)** — the `cairn/v1/run/<id>`
  breadcrumb tag shape + history-decoding helpers.
- **[`DeletionJournal.swift`](DeletionJournal.swift)** — append-only
  JSONL audit log. Wire-format details (including the
  `confirmedFromPhotoKit` → `confirmedFromChangeLog` Swift-rename-
  with-wire-stability pattern) are pinned in tests.
- **[`JournalReader.swift`](JournalReader.swift)** — reconstructs
  runs from journal entries for display.
- **[`PhotoEnumerator.swift`](PhotoEnumerator.swift)** — protocol the
  iOS side fills in (PhotoKit-backed) and the CLI's filesystem-based
  enumerator implements directly.

## Orchestrators

The mutation paths. Each is a single class that takes a destination
client + a context and runs the operation end-to-end, journalling
every step.

- **[`TrashOrchestrator.swift`](TrashOrchestrator.swift)** — the
  destructive path. Trash-not-hard-delete (`force: false`), tag every
  affected asset with `cairn/v1/run/<id>`, include Live Photo paired
  videos explicitly (the server doesn't cascade-trash through
  `livePhotoVideoId`).
- **[`RestoreOrchestrator.swift`](RestoreOrchestrator.swift)** — the
  undo path. Selects assets by run id (or asset id or filename regex)
  and calls `POST /api/trash/restore/assets`.

## Conventions

- Every public type is `Sendable` unless there's a documented reason
  it can't be (and there isn't, currently).
- Stores are actors when they own mutable state; value-type structs
  otherwise.
- Per-method docstrings explain *why* a choice is the way it is
  (Apple API quirks, Immich server constraints, historical
  regressions) — not *what* the signature already says.
- New behavior gets a test in `Tests/CairnCoreTests/` that names the
  contract being pinned. See `Tests/README.md` for the guided tour.
