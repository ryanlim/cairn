# CairnCore engine — code-clarity audit

Audit focus: would an external contributor (or a future Kotlin port author) understand the protocol surface, contracts, error model, and intent of `Sources/CairnCore/*` without reading the iOS implementations?

**Overall verdict:** the engine is in unusually good shape for an open-source project at this stage. Doc-comments consistently explain *why* (with references to Immich source paths, Apple API constraints, and empirical findings) rather than restating the signature. Tests are written as readable spec — `@Test("...")` descriptions document contracts that would otherwise live in prose. The portability contract holds (only `import Foundation` and `import CryptoKit` appear; no PhotoKit/SwiftData/SwiftUI/UIKit leakage). Errors are typed and discriminable. Unused-code, force-unwrap, and `fatalError` hygiene are clean.

The findings below are real friction points but mostly cosmetic / naming / surface-area issues. There are no architectural smells, no protocols whose contract you'd need to read the iOS impl to understand.

Findings are ordered by impact within each section.

---

## High severity

### H1. `ObservedStore` carries two parallel write APIs whose interaction is undocumented at the protocol level
**File:** `Sources/CairnCore/ObservedStore.swift:26–52`
**Severity:** high — direct contract ambiguity for any new impl.

The protocol exposes two write paths:
- `union(_ additions: Set<Checksum>)` — "idempotent-union; existing entries keep their tags" (line 32–33).
- `recordObserved(_ observations: [Checksum: Set<String>])` — "upsert entries with album tags. Replaces tags on existing entries" (line 41–45).

So `union` is no-op on existing rows; `recordObserved` *overwrites* tags on existing rows. A Kotlin port author looking at the protocol would need to read both doc-comments carefully (and the matched JSONFile impl at lines 86–146) to discover this asymmetry. The fact that the *tag* dimension is replace-wins while the *membership* dimension is union-wins is load-bearing for scope changes (see `recomputeScopeTags` in CLAUDE.md) but is not surfaced at the protocol's top-level doc, which describes "idempotent-union" semantics. A port author who reads only the top-level comment would plausibly implement `recordObserved` as also-idempotent-on-tags and silently break scope toggling.

Suggestion area: a brief table at the protocol's top-level doc-comment showing each method's effect on (membership, tags) of (new, existing) rows would resolve this in 10 lines.

### H2. `recordObserved` vs `union` naming gives no hint about the semantic difference
**File:** `Sources/CairnCore/ObservedStore.swift:32, 45`
**Severity:** high — naming should signal contract.

Building on H1: both methods *insert/upsert* entries. The names don't convey that one preserves tags and the other replaces them. `union` is a familiar set-theoretic verb (suggests "merge, don't disturb existing"); `recordObserved` does *not* sound like "replace tags on collision" — it sounds like "log this observation," which would be additive. A port author reading the protocol skim-style will get the wrong mental model.

Worth considering: `union(_:)` and `union(withTags:)` (or `recordObserved(_:replacingTagsOnExisting:)`) would self-document.

### H3. `LocalHashStore` protocol has six overlapping read methods; the rationale for each fallback is in default impl comments rather than at the protocol
**File:** `Sources/CairnCore/LocalHashStore.swift:24–91`
**Severity:** high — surface bloat with no map for which to use when.

The protocol exposes `snapshot()`, `indexedCount()`, `allLocalIdentifiers()`, `allChecksums()`, `summary()`, `entries(forIdentifiers:)`, plus the per-id `checksums(for:)` / `modificationDate(for:)`. Each has a doc-comment explaining that it's "cheaper than snapshot()" for some use case. A Kotlin port author has to decide which ones to actually optimize on the storage backend, vs leave with the default fallback. The protocol doesn't surface a "minimum useful implementation" set vs "performance-critical extras," so the port author either over-implements (six aggregate queries when one would do) or under-implements (everything falls back to `snapshot()` and the iOS impl's per-method optimizations are lost).

The default-impl extensions at lines 93–143 *do* note "concrete stores should override" but a contributor looking at the protocol-level for guidance gets only "implement these eight methods" with no priority order.

### H4. `ImmichClient` is publicly a `struct` but conforms to `ImmichWriter` via empty extension; the protocol/concrete relationship is unobvious
**File:** `Sources/CairnCore/TrashOrchestrator.swift:7–32, 50`; `Sources/CairnCore/ImmichClient.swift:57`
**Severity:** medium-high — surface organization confusion.

`ImmichWriter` is declared in `TrashOrchestrator.swift` with the empty conformance `extension ImmichClient: ImmichWriter {}` immediately below. The split rationale is good (orchestrators get the narrow surface; tests substitute fakes), but two things make this confusing for a new reader:

1. `ImmichWriter` includes `fetchAssets` (line 31), which is a *read* operation — the protocol name is misleading. `RestoreOrchestrator` reads `fetchAssets` for post-restore verification (`RestoreOrchestrator.swift:168`). So the protocol is really "the API surface orchestrators need," not "the writes."
2. The protocol lives in `TrashOrchestrator.swift`, but `RestoreOrchestrator` also depends on it. New contributors looking for "where does the orchestrator API contract live?" search by name, find the writer in a trash-themed file, and have to decide whether moving it is structural drift or intentional.

### H5. `JournalEntry.Event.syncTransitions(confirmedFromPhotoKit:...)` bakes an Apple platform name into the portable journal schema
**File:** `Sources/CairnCore/DeletionJournal.swift:260–265`
**Severity:** medium-high — wire format leaks platform.

The journal is a long-lived persisted format. The field name `confirmedFromPhotoKit` is platform-specific terminology that surfaces in any Kotlin port's journal (compatibility would force the Android port to either emit `confirmedFromPhotoKit` despite using MediaStore, rename and break round-trip with iOS journals, or fork the schema). The companion field `confirmedFromOrphanSweep` is platform-neutral and good.

Renaming pre-1.0 is cheap; once shipped this becomes a backward-compatibility burden. Suggestion area: `confirmedFromChangeLog` or `confirmedFromPlatformDeletionEvent` would describe the *signal source* rather than the *iOS API*.

---

## Medium severity

### M1. `ImmichClientError.missingScope` lists scope names as `[String]` rather than a strongly-typed enum
**File:** `Sources/CairnCore/ImmichClient.swift:10–16, 525–528`
**Severity:** medium.

`ImmichClient` declares `static let syncStreamRequiredScopes = ["sync.stream"]` and friends (lines 524–527) as string arrays. The error carries the same string array. Result: callers wanting to programmatically respond ("did the sync.stream scope fail? then disable incremental sync") string-match. The comment on `missingScope` even directs callers to "route this to the actionable 'regenerate your API key with these scopes' UI" — which is exactly the case where typed scopes would prevent typo regressions.

A `Scope` enum (with raw string for wire compat) would let the UI code switch over a known set.

### M2. `ImmichWriter.fetchAssets`'s "missing IDs (404) silently dropped" contract is documented on the protocol but the silence-vs-throw boundary is subtle
**File:** `Sources/CairnCore/TrashOrchestrator.swift:24–31`; `Sources/CairnCore/ImmichClient.swift:473–497`
**Severity:** medium.

Documented at both sites — but the contract is "404 silently drops; other non-2xx throws." The caller (`RestoreOrchestrator`) builds verification logic on this: "asset absent from result ⇒ still trashed, conservative read" (RestoreOrchestrator.swift:158–171). A new ImmichWriter impl (test fake, mock for a port) that throws on 404 instead would silently change the meaning of "stillTrashed" in restore verification — failure mode is non-obvious. The protocol comment is the only place this is normative; the test fakes should pin the behavior.

### M3. `assetStatistics(includeTrashed:)` parameter name doesn't match its query semantics
**File:** `Sources/CairnCore/ImmichClient.swift:320`
**Severity:** medium — parameter-vs-effect mismatch.

The method takes `includeTrashed: Bool = false` and sends `isTrashed=false` (line 328). When the user passes `includeTrashed: false` (the default), the API sends `isTrashed=false`, i.e., "give me only non-trashed assets." When they pass `includeTrashed: true`, the API sends `isTrashed=true`, i.e., "give me only TRASHED assets" — *not* "give me all assets including trashed." This is a misleading API: the parameter name suggests an *inclusive* toggle but the implementation is a *filter*.

The companion `listAllAssets(includeTrashed:)` (line 252) properly maps to `withDeleted` which IS inclusive. The two methods take the same-named parameter but have different effects.

### M4. `SettingsStore.load()` is declared `throws` but its doc says "fresh install gets `.defaults`, not a thrown error"
**File:** `Sources/CairnCore/CairnSettings.swift:477–479`
**Severity:** medium — contract ambiguity in throws conditions.

The protocol declares `func load() async throws -> CairnSettings` (line 478) with the doc saying "`load()` never errors on 'nothing saved yet' — a fresh install gets `.defaults`." So what does it throw for? Disk read failure? Decode failure on corruption? Both? The concrete `JSONFileSettingsStore.load()` (line 497) decodes via `JSONDecoder().decode(...)` and propagates the throw, so corrupted JSON crashes the caller. A new impl might reasonably read this contract as "never throws" and silently return defaults on corruption.

Either tighten the contract ("throws only on disk-read I/O failure"; corrupted JSON returns defaults), or document the throw conditions explicitly.

### M5. `gatedForReview()` on `ReconciliationOutput` is a pure transform that doesn't belong on the output type
**File:** `Sources/CairnCore/ReconciliationEngine.swift:150–168`
**Severity:** medium.

The method moves every `deleteCandidate` into `pendingReviewCandidates` for the "platform-side reconciler signaled it lost prior state" case. It's pure-data, and the only caller is the iOS reconciler. Putting it on the value type couples the otherwise-pure data DTO to a workflow concept. Two issues:

1. A port author reading `ReconciliationOutput` sees a method that "promotes candidates to pending review" and may infer this is a state machine on the output rather than a one-shot recovery transform.
2. The method's contract ("any candidate this pass arrived without a quarantine clock") is correct but applies *only* in the post-token-expiry case; a caller could apply it inappropriately and get a permanent stuck-in-review pipeline.

Could live as a free function `static func gateForReview(_:)` in `ReconciliationEngine` to signal "this is a recovery operation," not "an output method."

### M6. `MissedDeletionFinder.find` has 9 parameters with subtle mode-switching behavior
**File:** `Sources/CairnCore/MissedDeletionFinder.swift:59–69`
**Severity:** medium.

`find(serverAssets:observed:excluded:liveLocalFilenames:minCreatedAt:maxCreatedAt:confirmedDeletedFilenames:now:daysWindow:)` has two modes:
- Auto-scan: `confirmedDeletedFilenames == nil`, applies iPhone filename grammar, uses `daysWindow` fallback.
- Confirmed mode: `confirmedDeletedFilenames != nil`, skips grammar, uses user evidence as bound.

The mode flag is the *presence* of one argument, not an enum case. A reader has to follow ~50 lines of inline `if useConfirmedMode` branches to track mode interaction. The body (lines 70–148) does explain itself, but the function signature alone gives no hint that the two modes exist.

A `Mode` enum or two separate methods (`findAutoScan(...)` / `findWithEvidence(...)`) would make the surface intent-clear.

### M7. `JournalReader.summarizeRun` is internal but its event-handling is the only spec for status transitions
**File:** `Sources/CairnCore/JournalReader.swift:171–321`
**Severity:** medium — load-bearing logic hidden in `private static`.

The status-derivation block (lines 261–270) is the canonical "given these journal events, what's the run's status" decision tree. A future Android port has to reimplement it; finding this requires reading through a 150-line private function. Pulling the status decision into a separately-named (`private static func deriveStatus(_:) -> RunSummary.Status`) function would surface it as the spec it actually is, and make it possible for tests to pin status transitions directly without going through the full journal-summary path.

### M8. `ConfirmedDeletedStore.snapshot()` has an unreachable `return [:]` and a 7-line comment explaining why
**File:** `Sources/CairnCore/ConfirmedDeletedStore.swift:78–88`
**Severity:** low-medium.

The block at lines 78–88 includes a deliberately-unreachable return after a re-thrown decode. The comment is honest and self-aware ("Swift's exhaustiveness check doesn't know that, so the return is present to satisfy the type system"). This works but adds 11 lines for what could be one `throw` from the explicit decoder. The legacy-vs-current branching could equally be expressed as a `do { try v2 } catch { try v1 }` pattern that pushes the error trace through naturally.

---

## Low severity

### L1. `ImmichClient.swift` mixes the public client, private DTOs, and the `parseISO8601` helper at file scope
**File:** `Sources/CairnCore/ImmichClient.swift:700–768`
**Severity:** low — file structure.

The internal `SearchResponseDTO`, `TagDTO`, `AssetItemDTO` are at file scope (not inside `ImmichClient`). They have a `parseISO8601` helper duplicated in `TagDTO` (722–728) and `AssetItemDTO` (744–751) and *again* in `SyncWireDecoder` (204–211). The duplication is acknowledged by an inline comment at SyncWireDecoder.swift:201–203 ("we deliberately don't share the helper because that one is fileprivate"). Three identical 8-line `ISO8601DateFormatter` blocks isn't terrible, but a single internal `enum DateParsing { static func iso8601(_:) -> Date? }` would resolve it.

### L2. `clearSyncAcks(types:)` takes `[SyncEntityType]?` but `syncStream(types:)` takes `[SyncRequestType]` — different enums, similar names
**File:** `Sources/CairnCore/ImmichClient.swift:550, 638`; `Sources/CairnCore/SyncEntities.swift:11, 25`
**Severity:** low.

The distinction (server distinguishes request types from entity types) is documented at SyncEntities.swift:3–10. But at the call site, two methods both take "types" and a reader has to remember which one wants which. The `SyncEntityType` for clear is correct (matches the server's per-entity cursor), and `SyncRequestType` for stream is correct (the request body). Documented in passing but easy to swap by mistake; the compiler will catch the swap, but the parameter labels don't help disambiguate.

### L3. `DeletionJournal.append(_:)` is `throws` (not `async throws`) but `lastEntries` / `readAll` / `readRawLines` / `appendRawLines` are all called via `await` because they're on an actor
**File:** `Sources/CairnCore/DeletionJournal.swift:10, 35, 55, 64, 95, 106`
**Severity:** low — actor-isolation invisible at sig level.

All these methods are on `public actor DeletionJournal`. None are `async`, but all callers must `await` due to actor isolation. The signatures are syntactically `throws -> [JournalEntry]`, not `async throws`. A reader scanning the method list sees no async marker and may not realize the actor hop. This is standard Swift, but worth noting — explicit `async throws` on the actor methods would make the asynchronicity visible at the call site.

### L4. `EnvFileLoader` lives inside `SecretStore.swift` despite being entirely independent of the protocol
**File:** `Sources/CairnCore/SecretStore.swift:87–107`
**Severity:** low — file organization.

`EnvFileLoader.load(fromPath:)` parses `.env` files into process environment. It's used by the CLI to seed env-backed secrets, but the loader itself isn't tied to `SecretStore` (you could populate any env-reading code with it). Slotting it into its own file (e.g., `EnvFileLoader.swift`) would clarify that the CLI's `.env` mechanism is independent of the secret-store contract.

### L5. `TagSchema.runTagValue(runId:)` builds the tag value but `TagSchema.runId(fromTagValue:)` returns the *parsed* runId — the round-trip pair has asymmetric naming
**File:** `Sources/CairnCore/TagSchema.swift:28, 39`
**Severity:** low.

`runTagValue(runId:)` and `runId(fromTagValue:)` are inverses but read at the call site as unrelated. Reading `runTagValue` calls "make a tag value from a runId," reading `runId(fromTagValue:)` calls "extract a runId from a tag value." A pair like `encode(runId:)` / `decode(_:)` or `tag(forRunId:)` / `runId(from:)` would signal the inverse relationship.

### L6. `ImmichThumbnailLoader`'s eviction is documented as "naive" but contains no warning that the cache can serialize concurrent fetches behind itself
**File:** `Sources/CairnCore/ImmichThumbnailLoader.swift:16, 56–70`
**Severity:** low.

The actor serializes every `load(assetId:)` call (since the actor isolates `cache`/`inFlight`). Most cache hits return instantly so it doesn't matter, but the doc says it "de-duplicates concurrent requests for the same asset" — correct — without noting that *different-asset* concurrent requests also serialize through the actor. For a wall of thumbnails on first scroll this means N actor hops before bytes start flowing. Probably fine for current scale (200 thumbnails × actor hop ≪ 200 × network); worth noting if profiling ever surfaces UI judder.

### L7. `CairnSettings` Codable `init(from:)` does decodeIfPresent for *every* field, but a few fields have published `Range`s on the type itself that the decoder doesn't clamp against
**File:** `Sources/CairnCore/CairnSettings.swift:249–268`
**Severity:** low — comment says ranges are "tolerated on decode; UI surfaces should clamp on write."

Quarantine, iCloud limits, backlog threshold all have `static let xRange: ClosedRange<Int>` declared at the type level. The decoder tolerates out-of-range values; the doc-comments on each field document this. But there's no central note at the Codable boundary saying "all numeric ranges are advisory at the persistence layer." A new contributor reading the field doc and seeing the range may assume the decoder enforces it.

### L8. `RuntimeError` does not appear in `CairnCore` (only in CLI). The audit-prompt mentioned it — worth noting it's CLI-specific.
**File:** `Sources/CairnCLI/Cairn.swift`, `Sources/CairnCLI/HistoryCommands.swift`
**Severity:** info, not a finding.

`RuntimeError` is CLI-specific. CairnCore uses typed errors (`ImmichClientError`, `RestoreError`, `SecretStoreError`, `CairnExportPayload.ExportError`) consistently. Good.

---

## What's right (briefly)

- **Doc-comments are load-bearing throughout.** They explain *why* (Apple API constraints, Immich server file paths cited by line number, empirical findings). Spot-check: `Hashing.swift:13` (why Insecure.SHA1), `Types.swift:21–24` (why server doesn't cascade Live Photo trash), `ConfirmedDeletedStore.swift:14–16` (first-write-wins semantics + rationale), `EditRetirementStore.swift:1–69` (the whole-protocol header is a mini design doc).
- **Tests-as-spec works.** `@Test("...")` descriptions are full sentences that read as contracts. `ReconciliationEngineTests`, `EditRetirementStoreTests`, `ConfirmedDeletedStoreTests`, `SafetyRailsTests` could be read top-to-bottom as the engine's behavioral contract without opening source files.
- **Portability assertion holds.** Only `import Foundation` and `import CryptoKit` are present in every CairnCore file. Every reference to PhotoKit / PHAsset / etc. is in *comments* explaining the iOS-side context. The platform-specific types (e.g., `LocalAssetMetadata.localIdentifier: String`) are opaque-string-typed.
- **Error model is consistently typed.** `ImmichClientError`, `RestoreError`, `SecretStoreError`, `CairnExportPayload.ExportError` all carry actionable payload (URLs, status codes, descriptions ready-to-display). The `ImmichClientError.httpStatusCode` accessor and `ImmichClientError.httpStatus(from:)` static helper give callers a programmatic path to discriminate transport-vs-HTTP failures without string-matching.
- **No `fatalError` / `preconditionFailure` in CairnCore.** Two `precondition()` calls; both are guards on internal helpers (`JournalReader.summarizeRun`'s `!entries.isEmpty`, `chunked(into:)`'s `size > 0`) with explicit messages. No force-unwraps in production paths except two in `JournalReader.summarizeRun` that are guarded by the `precondition` above.
- **`#if DEBUG`-gated logging is minimal and labeled.** One block in `ImmichClient.trashAssets` (line 363–367) with explicit "production builds don't stream per-call logs" rationale.
- **Codable on-disk shapes are explicitly versioned and tolerate forward/backward drift** (`CairnSettings.init(from:)` defaults missing keys, `ObservedStore` legacy `[String]` → `{base64: [tags]}` migration, `ConfirmedDeletedStore` legacy array decodes as `.distantPast`, `JournalEntry.TrashTarget` decodes pre-extension rows with nil).
