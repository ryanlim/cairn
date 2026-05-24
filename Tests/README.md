# Tests

The cairn test suite doubles as the conformance spec for `CairnCore`:
any behavior change to a protocol there should land alongside a
test that pins the new contract, so a future Kotlin/Android port has
something concrete to match. The suite runs against macOS + Linux via
`swift test` (no Apple-only test types here — those live in
`CairnIOSCoreTests`).

## Where to look first

If you're trying to understand a piece of cairn's behavior without
reading every line of the implementation, these tests are the highest
signal-to-noise:

### Engine semantics

- **[`ReconciliationEngineTests.swift`](CairnCoreTests/ReconciliationEngineTests.swift)** —
  How cairn decides what to trash. Strictness modes, quarantine
  windows, exclusion handling, edit-retirement protection.
- **[`SafetyRailsTests.swift`](CairnCoreTests/SafetyRailsTests.swift)** —
  The percent-cap + minimum-floor logic that aborts runs touching too
  much of the library. The first-run-dry-run guard.
- **[`MissedDeletionFinderTests.swift`](CairnCoreTests/MissedDeletionFinderTests.swift)** —
  Server-side recovery scan: which assets look like prior iPhone
  uploads cairn never observed.
- **[`OrphanReconcilerTests.swift`](CairnCoreTests/OrphanReconcilerTests.swift)** —
  The safety-net path that catches back-channel deletions the
  persistent-change log missed.

### State stores (the protocols a Kotlin port would re-implement)

- **[`ObservedStoreTests.swift`](CairnCoreTests/ObservedStoreTests.swift)** —
  The "ever-seen" SHA1 set that distinguishes "user deleted this
  from iPhone" from "this was never on iPhone."
- **[`ConfirmedDeletedStoreTests.swift`](CairnCoreTests/ConfirmedDeletedStoreTests.swift)** —
  Per-checksum confirmation timestamps that drive the quarantine
  clock. First-write-wins on timestamps; the rationale is in the
  test names.
- **[`EditRetirementStoreTests.swift`](CairnCoreTests/EditRetirementStoreTests.swift)** —
  First-observed SHA1 anchoring per `localIdentifier`. Critical for
  edit-handling correctness; the "edit → revert → edit again" worked
  scenario is pinned here.
- **[`ExclusionStoreTests.swift`](CairnCoreTests/ExclusionStoreTests.swift)** —
  User-protected checksums. Survives index resets.

### API + journal

- **[`ImmichClientHTTPTests.swift`](CairnCoreTests/ImmichClientHTTPTests.swift)** —
  Every Immich endpoint cairn touches, with mocked responses
  exercising the auth header, pagination, retry behavior.
- **[`ImmichClientSyncStreamTests.swift`](CairnCoreTests/ImmichClientSyncStreamTests.swift)** —
  The CDC `/sync/stream` + session-auth (Bearer) path.
- **[`DeletionJournalTests.swift`](CairnCoreTests/DeletionJournalTests.swift)** —
  Append-only JSONL journal: wire format pinning tests, legacy-row
  decode, the `confirmedFromPhotoKit` → `confirmedFromChangeLog`
  Swift-rename-with-wire-stability pattern.
- **[`JournalReaderTests.swift`](CairnCoreTests/JournalReaderTests.swift)** —
  How runs are reconstructed from the journal for display.
- **[`RestoreOrchestratorTests.swift`](CairnCoreTests/RestoreOrchestratorTests.swift)** —
  Undo path: how cairn finds and unwinds a prior run.

### iOS-specific impls

`Tests/CairnIOSCoreTests/` mirrors `CairnIOSCoreTests`. Highlights:

- **[`SwiftDataStoresTests.swift`](CairnIOSCoreTests/SwiftDataStoresTests.swift)** —
  Every SwiftData-backed `*Store` actor, including the
  scope-aware tag round-trip and the server-asset cache filter
  semantics.
- **[`PhotoKitPersistentChangeReconcilerTests.swift`](CairnIOSCoreTests/PhotoKitPersistentChangeReconcilerTests.swift)** —
  The PhotoKit-side pipeline (incremental change events, full-enum
  fallback, orphan sweep).
- **[`JournalTailEntryTests.swift`](CairnIOSCoreTests/JournalTailEntryTests.swift)** —
  How journal rows render in the in-app feed (compact severity,
  message format).

## Conventions

- Tests use Swift Testing (`@Test`, `@Suite`, `#expect`), not XCTest.
- Test names describe the *contract being pinned*, not the
  implementation strategy ("first-write-wins on timestamp" rather
  than "test confirmed-deleted union with overlapping checksums").
  Read them like a spec.
- Suites that share global state (like `MockURLProtocol.handler`)
  are marked `.serialized` so parallel execution doesn't race them.
- `CairnFixtures` (in `Sources/CairnIOSCore/UI/CairnFixtures.swift`)
  is the canonical source of preview / test data — reuse rather
  than re-rolling fake assets per test file.

## Running

```sh
swift test                              # full suite, both modules
swift test --filter ReconciliationEngine # one suite
swift test --filter "first-write-wins"   # by test-name pattern
```

iOS-app integration testing (against the simulator) is the
`make test` lane in `iOS/Makefile`; it currently wraps the same
SPM suite. Snapshot tests for the SwiftUI screens are planned but
not yet present.
