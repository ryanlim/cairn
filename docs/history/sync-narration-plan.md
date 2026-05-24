# Sync narration: SyncPhase expansion + activity feed + drill-down sheet

**Status:** planned, not yet implemented.
**Context:** sync on a large library appears to hang for ~10s before any
counter ticks; the existing `SyncPhase` enum (`idle / hashing /
fetchingServer / reconciling`) collapses everything into "hashing" before
the actual hash work begins. Perf fixes in `a189a65` and timing logs in
`d0006fd` shrank the wait and made it diagnosable; this plan adds
user-facing observability so the *remaining* wait is no longer opaque.

The phases proposed here mirror the `tick(...)` boundaries already
emitting `[cairn.recon.timing] phase=X took=Yms` lines, so the plan is
grounded in real instrumentation, not invented categories.

---

## Phase 1 — Model

### 1a. Expand `CairnAppModel.SyncPhase`

Replace the four-case enum with six:

```swift
public enum SyncPhase: Sendable, Equatable {
    case idle
    case preparing       // fetchPersistentChanges, cachedLocalIds, discoverUntracked,
                         //   deferredQueue snapshot, scope membership — pre-hash work
    case fetchingServer  // listAllAssets pagination (parallel; non-blocking)
    case hashing         // observeAndFilter + actual SHA1 work (existing progress bar)
    case reconciling     // orphan sweep + engine compute + orphan match
    case finalizing      // journal append + persistSnapshot + refresh helpers
}
```

`fetchingServer` stays as a phase even though it's parallel — the
drill-down can show it as a concurrent track rather than a strict
next-step.

The existing `SyncPhaseChecklist` view in StatusScreen has a fixed
three-row layout. **Decision:** simplify to a one-line current-phase
indicator and push the timeline into the drill-down sheet. Keeps the
Status syncCard quiet; the curious user opens the sheet for the full
breakdown.

### 1b. Add `SyncActivity` + ring buffer

```swift
public struct SyncActivity: Identifiable, Sendable, Equatable {
    public let id: UUID = UUID()
    public let timestamp: Date
    public let kind: Kind
    public let detail: String
    public enum Kind: Sendable, Equatable {
        case phaseStart       // "preparing" / "hashing" — written from phase transitions
        case hashed           // "IMG_4612.HEIC" — throttled ~per-250ms or per-50 assets
        case fetched          // "server page 3 (of 12)"
        case stamped          // "5 confirmed-deleted"
        case note             // generic info ("untracked sweep: 142 ids")
        case warning          // degraded mode ("Limited Photos auth — pending review only")
    }
}

public var syncActivity: [SyncActivity] = []  // capped at 50, newest first
public static let syncActivityCap = 50
```

Append helper that respects the cap:

```swift
@MainActor
public func appendSyncActivity(_ entry: SyncActivity) {
    syncActivity.insert(entry, at: 0)
    if syncActivity.count > Self.syncActivityCap {
        syncActivity.removeLast()
    }
}
```

### 1c. `SyncPhaseTimeline`

Per-phase elapsed plus order:

```swift
public struct PhaseEntry: Sendable, Equatable {
    public let phase: SyncPhase
    public let startedAt: Date
    public let durationMs: Int?  // nil while in-flight
}

public var syncTimeline: [PhaseEntry] = []  // cleared on each sync start, rebuilt as phases advance
```

---

## Phase 2 — Wire the phase transitions

The `tick(...)` closures already mark every boundary in
`runIncremental` / `runFullEnumeration`. Mirror them with
`model.syncPhase = ...` writes plus activity emits.

The reconciler runs detached, so it needs a callback into the main actor.
Add an `onPhaseChange` closure to
`PhotoKitPersistentChangeReconciler.init`:

```swift
public typealias PhaseHandler = @Sendable (_ phase: String) async -> Void
public let onPhaseChange: PhaseHandler?
```

`AppDependencies.persistentChangeReconciler` wires it:

```swift
onPhaseChange: { [weak self] phaseName in
    await MainActor.run {
        self?.appendSyncActivity(.init(timestamp: Date(), kind: .phaseStart, detail: phaseName))
    }
}
```

The existing `tick(...)` closure inside the reconciler also calls
`onPhaseChange` — single source of truth, no duplicate emit sites.

`performLiveReconciliation` writes `model.syncPhase` directly at six
points:

- `.preparing` at top of function
- `.fetchingServer` when `serverAssetsTask` actually starts (currently
  set after the scan, which is wrong; move to before)
- `.hashing` when reconciler enters its hashing batch (the existing
  `onHashProgress` callback already fires; on first hash event flip to
  `.hashing`)
- `.reconciling` after scan returns
- `.finalizing` after engine + orphan match
- `.idle` at the end

---

## Phase 3 — Activity feed production

### 3a. Hashing throttle

`onHashProgress` fires on every asset (~500/sec on Apple silicon).
Unthrottled SwiftUI rerender cost would be unacceptable. Add to
`AppDependencies`:

```swift
private var lastHashActivityAt: Date = .distantPast
private static let hashActivityThrottleMs: Int = 250

func emitHashActivity(filename: String) {
    let now = Date()
    let elapsed = Int(now.timeIntervalSince(lastHashActivityAt) * 1000)
    guard elapsed >= Self.hashActivityThrottleMs else { return }
    lastHashActivityAt = now
    Task { @MainActor in
        self.model.appendSyncActivity(.init(timestamp: now, kind: .hashed, detail: filename))
    }
}
```

The reconciler's `onHashProgress` callback is the natural place to call
this. `filename` comes from `LocalAssetMetadataStore` lookup or the
`originalFileName` already inside the hash batch.

### 3b. Server fetch pagination

`ImmichClient.listAllAssets` already paginates internally. Add an
`onPage:` closure:

```swift
public func listAllAssets(onPage: ((_ page: Int, _ assets: Int) -> Void)? = nil) async throws -> [ServerAsset]
```

`AppDependencies` wires it to emit `.fetched` activity per page. ~10-20
entries for a typical Immich.

### 3c. Phase boundaries + notable events

Every `tick(...)` call in the reconciler emits a `.phaseStart` activity
via `onPhaseChange`. Plus discrete notable events as `.note` /
`.warning`:

- "Untracked sweep: 142 ids" (existing log line, mirror to feed)
- "Skipped 6 stale-modDate updates" (existing)
- "Limited Photos: missed deletes will route to pending review" (existing
  toast — also surface here)

---

## Phase 4 — `SyncDetailSheet`

New file `Sources/CairnIOSCore/UI/SyncDetailSheet.swift`. Layout:

```
┌─────────────────────────────────┐
│ ← Sync detail                  ✕│  ← title bar with cancel
├─────────────────────────────────┤
│ ● Hashing — 12.4s               │  ← current phase + elapsed
│ ░░░░░░░░░░░ 1,247 / 6,512       │  ← progress bar when applicable
├─────────────────────────────────┤
│ Phase timeline                  │  ← KeylineSection
│ ✓ Preparing       820ms         │
│ ✓ Fetching server 3.2s          │
│ ● Hashing         12.4s ← live  │
│ — Reconciling                   │
│ — Finalizing                    │
├─────────────────────────────────┤
│ Activity                        │  ← KeylineSection, monospace
│ 12:34:18  hashed  IMG_4612.HEIC │
│ 12:34:18  hashed  IMG_4611.HEIC │
│ 12:34:17  fetched server page 4│
│ ...                              │
├─────────────────────────────────┤
│ [Cancel sync]                   │  ← mirrors existing onCancelSync
└─────────────────────────────────┘
```

Reuses existing primitives (`AppHeader`, `KeylineSection`, `CairnCard`,
tokens). Activity rows are one line each with monospace digits for
timestamps.

Props:

```swift
SyncDetailSheet(
    phase: SyncPhase,
    syncStartedAt: Date?,
    progress: (hashed: Int, total: Int)?,
    timeline: [PhaseEntry],
    activity: [SyncActivity],
    onCancel: () -> Void,
    onClose: () -> Void
)
```

Uses `TimelineView(.periodic(by: 0.5))` for the elapsed-time refresh —
half-second tick gives smooth-enough "12.4s" updates without 60Hz
redraws.

---

## Phase 5 — Two entry points

### 5a. StatusScreen syncCard

Add a "Show details" button below the existing checklist when
`isSyncing == true`:

```swift
if isSyncing {
    Button("Show details") { onOpenSyncDetail() }
        .buttonStyle(.plain)
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(t.accent)
}
```

Plumbs `onOpenSyncDetail` through StatusScreen's init → CairnAppRoot
wires to `model.presentedSheet = .syncDetail`.

### 5b. InitialScanScreen

**Decision:** skip the drill-down entry point on InitialScanScreen.
The screen already IS the detail view for first-run hashing — adding a
"Show details" button on top of an existing progress display is
redundant. Only StatusScreen gets the drill-down.

### 5c. PresentedSheet enum

Add `.syncDetail` case to `CairnAppModel.PresentedSheet` and route in
`CairnAppRoot.sheetContent(for:)`.

---

## Phase 6 — Throttling and tests

### Throttling rules

- **Hashing**: 250ms minimum between activity emits.
- **Phase transitions**: always emit (low N — ~10 per sync).
- **Server fetch**: per-page (low N).
- **Notes/warnings**: always.
- **Activity buffer cap**: 50 entries, newest first.

### Tests

```swift
@Suite("SyncActivity")
struct SyncActivityTests {
    @Test("appendSyncActivity respects the cap and orders newest-first")
    @Test("phase transitions emit one activity per change")
    @Test("hash activity throttled — three rapid emits within 250ms produce one entry")
}

@Suite("SyncPhase rendering")
struct SyncPhaseTests {
    @Test("display label for each case")
    @Test("timeline preserves phase order across transitions")
}
```

UI snapshot tests for the sheet are deferred — no snapshot harness yet.

---

## Files touched

```
Sources/CairnIOSCore/
  PhotoKitPersistentChangeReconciler.swift  +30 LoC (onPhaseChange callback + emits)
  UI/
    CairnAppModel.swift                     +60 LoC (SyncPhase expand, SyncActivity, timeline)
    CairnAppRoot.swift                      +20 LoC (sheet routing, prop plumbing)
    StatusScreen.swift                      +15 LoC ("Show details" affordance)
    InitialScanScreen.swift                 (no change — see decision 2)
    SyncDetailSheet.swift                   +200 LoC (new file)
iOS/App/AppDependencies.swift               +60 LoC (phase writes, throttle helper, wiring)
Tests/CairnIOSCoreTests/
  SyncActivityTests.swift                   +50 LoC (new file)
```

**Estimate: ~450 LoC total, three logical commits.**

### Commit boundaries

1. **Model: SyncPhase expansion + SyncActivity buffer.** Pure model
   surface, no UI consumers yet. Tests included. Backwards-compatible —
   old switches over SyncPhase get default cases.
2. **Reconciler + AppDependencies: phase writes + activity emits.**
   Wires production. No UI yet; activity buffer fills correctly but no
   view reads it.
3. **SyncDetailSheet + Status entry point.** Adds the sheet, plumbs the
   entry, ships.

Each commit independently builds + tests. If commit 3 has issues,
commits 1 and 2 are still valuable (better Console output, model state
for future use).

---

## Decisions

1. **`SyncPhaseChecklist` shape.** Simplify to a one-line current-phase
   indicator on Status' syncCard. The full timeline lives in the
   drill-down sheet. Status stays quiet for the steady-state user; the
   curious user opens the sheet.
2. **InitialScanScreen drill-down entry.** Skip. The screen already IS
   the detail view for first-run hashing; bolting a "Show details"
   button onto an existing progress display is redundant. Only
   StatusScreen gets the drill-down.
3. **Activity feed forensic depth.** 50-entry ring buffer is the v1.
   Throttled at 250ms during hashing, that surfaces ~12s of recent
   history on a long sync. Sufficient for "is anything happening"
   confidence; not a full forensic timeline. Deeper history (tee to the
   journal) is deferred — stretch goal if real-world reports show 12s
   isn't enough.
4. **SwiftUI re-render cost.** `@Observable` + array prepend triggers
   re-render of every view that reads any property on the model. Only
   `SyncDetailSheet` reads `syncActivity` directly; Status'
   `syncCard` MUST NOT read `model.syncActivity.count` or any derivative
   — doing so would re-render Status on every activity emit (potentially
   4×/sec during hashing). Pin this constraint in code review.

---

## Predecessors

- `a189a65` — perf: collapsed pre-hash full-table fetches (4 → 1)
- `d0006fd` — recon: per-phase timing logs (`[cairn.recon.timing]`)

This plan builds on those. The timing logs already give Console-level
narration; this plan adds the equivalent in-app narration plus a
drill-down for the curious user.
