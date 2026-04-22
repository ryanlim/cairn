# CLAUDE.md

Guidance for Claude Code sessions working in this repo. Read this whole file before doing anything substantive — the project has a lot of accumulated context that the codebase doesn't fully self-document.

## Project name

The product is **cairn** — rendered all-lowercase in user-facing prose (README, App Store, marketing). Swift identifiers stay conventional PascalCase: package `Cairn`, modules `CairnCore` / `CairnIOSCore` / `CairnCLI`, type `struct Cairn`. Binary (`cairn`), tag prefix (`cairn/v1/run/<id>`), env vars, and file paths are lowercase.

The name does **not** contain "Immich" by design (App Store trademark risk, brand-confusion liability, stewardship). cairn is not affiliated with Immich; compatibility is described in user-facing prose, not in identifiers.

## Repo layout

Root: `/Users/graham/code/cairn/` (was `immich_delete_prototype/` until 2026-04-21; older session contexts may reference the old path).

```
Sources/
  CairnCore/          # Multi-platform pure-logic library. No Apple-only APIs.
  CairnIOSCore/       # iOS-side: SwiftData/Keychain/PhotoKit/UserDefaults impls + SwiftUI screens.
    UI/               # All SwiftUI views (palette, tokens, primitives, 7 screens, root).
  CairnCLI/           # `cairn` command-line tool (verify / dry-run / trash / restore / journal / history / diagnose).
Tests/
  CairnCoreTests/
  CairnIOSCoreTests/
iOS/                  # iOS app target (XcodeGen + Fastlane). See iOS/README.md.
  App/
    CairnApp.swift            # @main App, BGTaskScheduler.register
    AppDependencies.swift     # Concrete wiring (has TODO markers — see "Open work" below)
  fastlane/                   # Adapted from ReferenceFrame's setup
  project.yml                 # XcodeGen config — single source of truth
  Makefile                    # `make help` lists everything
cairn/                # Claude Design prototype (HTML/JSX) + HANDOFF.md. Reference, not shipped.
notes/                # Bug reports + ad-hoc notes to file later
immich-ios-deletion-sync-plan.md   # The master design doc. Read this.
README.md
LICENSE               # MIT
.env.example
```

## Reference: Immich source

A shallow clone of the Immich repo lives at `/Users/graham/code/immich` for reading the mobile app (`mobile/`, Dart/Flutter) and server API (`server/src/`, NestJS + Kysely). Use it to ground any assumption about Immich's current behavior — the project moves fast and training-data knowledge is unreliable. The HEAD when this clone was taken was `be1b9a5`; verify migrations/DTOs against the actual checkout, not against memory.

## Project status (as of 2026-04-21)

**Phase 1 CLI:** complete and validated end-to-end against a real Immich instance.
**Phase 2 iOS:** core packages complete; iOS app shell scaffolded; Xcode project not yet generated on user's Mac (Bundler/Ruby fix pending — see `iOS/README.md`).

Wave-by-wave status:

| Wave | What it added | Status |
|---|---|---|
| Phase 1 | CLI: reconciliation, safety rails, journal, restore, history, diagnose | ✓ done |
| Wave 1 | ExclusionStore, CairnSettings, RunSummary enrichment | ✓ done |
| Wave 2 | Reconciliation+exclusion integration, two-confirm trash, journal events | ✓ done |
| Wave 3A | Add `CairnIOSCore` SPM target; HANDOFF.md API corrections | ✓ done |
| Wave 3B | iOS-side concrete protocol impls (PhotoKit / Keychain / SwiftData / UserDefaults) | ✓ done |
| Wave 3C | SwiftUI port of all 7 prototype screens + foundations + `CairnAppRoot` | ✓ done |
| Wave 4 | Confirmed-deletion signal (Recently Deleted), strictness modes, pending review | ✓ done |
| iOS app shell | XcodeGen `project.yml`, Fastlane lanes, `App/CairnApp.swift`, `App/AppDependencies.swift` | ✓ scaffolded; user setup pending |

**Test count: 155 passing across 25 suites.**

## Build / test / run

### Swift package (CairnCore + CairnIOSCore + CairnCLI)

```sh
swift build                  # compile all targets
swift test                   # 155 tests
swift run cairn --help       # CLI
```

CLI reads `.env` from CWD. Required vars: `IMMICH_URL`, `IMMICH_API_KEY`. **Never echo `.env` contents to tool output.** Common subcommands:

- `cairn verify` — connectivity + auth check.
- `cairn dump-server-checksums --output FILE` — write base64 SHA1s for all server assets, one per line.
- `cairn dry-run --local-checksums-file FILE` — full reconciliation, no mutation.
- `cairn trash --local-checksums-file FILE [--yes]` — destructive. Refuses on first run; forces dry-run first.
- `cairn restore --run-id X [--asset-id ...] [--file-name-matches REGEX]` — undo a run, optionally per-asset or by filename pattern.
- `cairn journal show [--run-id X | --last]` / `cairn journal list` — local audit log.
- `cairn history list [--detailed]` / `cairn history show --run-id X` — server-side reconstruction (requires `tag.read` on API key).
- `cairn diagnose` — visibility-class breakdown, Live Photo integrity check.

Persistent state (gitignored): `ever-seen.json`, `deletion-journal.jsonl`, `exclusions.json`, `confirmed-deleted.json`, `cairn-settings.json`.

### iOS app

See `iOS/README.md` for the full setup walkthrough. Short version:

```sh
cd iOS
make install       # brew install xcodegen + bundle install (see "Known gotchas" below)
make generate      # produces Cairn.xcodeproj from project.yml
open Cairn.xcodeproj
# In Xcode: select Cairn target → Signing & Capabilities → set Team
# Then: Cmd-R to build to simulator
```

After that:

```sh
make test          # swift test
make beta          # bump build, build IPA, upload to TestFlight
make release       # bump build, build IPA, upload to App Store
```

## Identity model (the key thing that was wrong and has been corrected)

Asset identity on the Immich server is **SHA1 of file content**, base64-encoded, exposed as `AssetResponseDto.checksum` (`server/src/dtos/asset-response.dto.ts:112`). The server enforces `sha1` as the only supported algorithm (`server/src/enum.ts:44`).

The older `deviceAssetId` / `deviceId` scheme used by the Immich mobile app was removed from the server schema in Apr 2026 (migration `1776263790468-DropDeviceIdAndDeviceAssetId.ts`). Mobile still sends those fields but they aren't persisted. Do not build reconciliation around them.

Our reconciliation uses a client-side **ever-seen SHA1 set** to express "delete on iPhone propagates to Immich" without touching photos that were never on the iPhone.

## API endpoints that matter

All auth via `x-api-key` header.

- `DELETE /api/assets` with `{ ids:[...], force: false }` → trash (not hard-delete). Plural path.
- `POST /api/search/metadata` (paginated) → lists assets including `checksum`. Default visibility excludes `hidden`; pass `visibility` to filter explicitly. To get all visibilities, iterate.
- `POST /api/trash/restore/assets` with `{ ids:[...] }` → restore.
- `POST /api/tags` → upsert tag by name.
- `PUT /api/tags/assets` → bulk-tag assets.
- `GET /api/tags` → list tags (needs `tag.read`).
- `POST /api/sync/stream` → JSONL change-event stream (used by official mobile app; not currently consumed by cairn).

## Portability contract (Option C — Swift now, Kotlin if/when)

Decision: stay single-platform Swift for Phase 1 and Phase 2. Port `CairnCore` to Kotlin directly if Android demand materializes. Not KMP, not a Rust core.

Rules to keep that future port viable:

- `CairnCore` stays pure Foundation + CryptoKit. No PhotoKit, SwiftData, Keychain, UIKit, SwiftUI, BackgroundTasks.
- Apple-only APIs live behind protocols defined in Core. iOS provides concrete impls in `CairnIOSCore`.
- The test suite is the conformance spec.
- Port order: Types → SafetyRails + ReconciliationEngine → Hashing → DeletionJournal + JournalReader → TagSchema → ImmichClient → TrashOrchestrator + RestoreOrchestrator.

LoC reality check (post-Wave 4): we're at ~7,000 LoC of iOS-bound code (impls + UI), well above the original "1,000–2,000" plan estimate. Half is feature additions beyond the original plan; half is design polish driven by the prototype. Worth knowing if Android ever becomes serious — see plan doc "Portability".

## Tag schema (v1)

Every trash run writes `cairn/v1/run/<run_id>` as a tag on Immich. One tag per run; every trashed asset (including Live Photo motion videos) attached. `<run_id>` = ISO-8601 timestamp + short device id. Schema-versioned at the path — bump to `v2` for breaking changes; old tools keep reading old tags.

API key scopes: `asset.read`, `asset.delete`, `tag.create`, `tag.asset` for normal operation; `tag.read` additionally for `cairn history` and `--file-name-matches`.

## Confirmed-deletion signal (Wave 4)

The default reconciliation strategy is a *negative* signal — "checksum is in ever-seen but no longer in current-local → delete candidate." Vulnerable to gradual library loss (iCloud sync degradation, partial restores, "Remove from this iPhone").

Wave 4 introduces a *positive* signal: `ConfirmedDeletedStore` accumulates checksums observed in iOS's Recently Deleted album. Scheduled scan (default daily via `BGAppRefreshTask`) plus reactive `PHPhotoLibraryChangeObserver` keep it current.

`CairnSettings.deletionStrictness`:
- `.strict` (default) — only confirmed-deleted candidates trash; rest go to pending review for manual approval.
- `.trusting` — any diff candidate eligible. Faster, less safe.

iCloud-Optimized assets are **not** affected — they still appear in `PHAsset.fetchAssets()` and our enumerator downloads on demand. First-sync hashing pays a network cost but no correctness issue.

Full design (failure modes, UX copy seeds, Android implications) lives in the plan doc's "Confirmed-deletion signal (Wave 4)" section.

## Live Photos and hidden assets

A Live Photo is one `PHAsset` on iOS but **two Immich assets**: still (`visibility: timeline`) + motion video (`visibility: hidden`), linked by the still's `livePhotoVideoId` field. `search/metadata` excludes hidden by default.

**Server does NOT cascade trash** through `livePhotoVideoId` (verified empirically). `TrashOrchestrator.run` explicitly includes linked video UUIDs in every delete batch — `TrashOrchestratorTests.livePhotoVideoIncluded` pins this. `locked` visibility needs an elevated-permissions flow our API key doesn't have; tooling skips it.

## Hashing

Use `CryptoKit.Insecure.SHA1` on iOS — hardware-accelerated on all modern Apple silicon. "Insecure" refers to cryptographic suitability; for content-addressing it's fine and we have no choice (server only accepts SHA1). PhotoKit file I/O dominates, not the hash. Empirical baseline: ~2.3 GB/s sustained on macOS NVMe (`Hashing` module). Expect ~200–500 MB/s on iPhone NAND.

## SwiftUI/UI conventions in CairnIOSCore

- All colors via `@Environment(\.cairnTokens)`. Components NEVER reach for raw `Color.red` etc. Tokens are derived from `CairnPalette` per `ColorScheme`.
- Apply theme at root: `.cairnTheme(palette)`.
- Microcopy from the prototype is verbatim — see HANDOFF.md "Keep these copies verbatim". Cite source in code comments when copy is load-bearing.
- Each screen has multiple `#Preview` blocks (light, dark, key states) and uses `CairnFixtures` for preview data.
- Use existing primitives (`AppHeader`, `KeylineSection`, `CairnCard`, `KeyValRow`, `ToggleRow`, `Stat`, `Callout`, `MockAssetThumb`, `CairnTabBar`) — don't re-roll.

## iOS app shell (Xcode project)

Lives in `iOS/`. See `iOS/README.md`. Key points for Claude:

- The `.xcodeproj` is **gitignored**; `iOS/project.yml` is the source of truth. Run `make generate` after editing project.yml.
- `iOS/App/CairnApp.swift` is the `@main` App. Owns `BGTaskScheduler.register` for the daily Wave-4 scan.
- `iOS/App/AppDependencies.swift` wires concrete iOS-side impls (Keychain, SwiftData, PhotoKit, ImmichClient) into a `CairnAppActions` bundle the UI consumes. **Has explicit `TODO:` markers** for the cached-reconciliation flow that still needs finishing — see "Open work" below.
- Fastlane lanes mirror `ReferenceFrame`'s pattern — App Store Connect API key auth via env vars.

## Open work / known TODOs

In rough priority order:

1. **Resolve `iOS/` Bundler version mismatch** (running 4.0.6 vs spec 4.0.8). Fix in `iOS/README.md` "Known gotchas". Then `make install` should complete.
2. **Generate the Xcode project** (`make generate`), set the Signing Team in Xcode UI once, build to simulator.
3. **Wire cached-reconciliation flow** in `iOS/App/AppDependencies.swift`. The `requestSync` closure currently computes the result but doesn't stash it on the model — `DryRunSheet` still renders against fixtures. Needs:
   - A new property on `CairnAppModel` to hold the most recent `ReconciliationOutput` (delete candidates + pending review).
   - `requestSync` writes that property; `confirmTrash` reads it and calls `TrashOrchestrator.run`.
   - `presentRunDetail` queries the journal + server for that run's tagged assets, populates real data instead of fixture candidates.
4. **Filename → checksum lookup in `exclude` action.** Currently the AppDependencies `exclude` closure constructs `Checksum(base64: filename)` which is wrong; needs to look up the actual checksum via the cached candidates.
5. **Real Immich thumbnail loading.** `MockAssetThumb` is a placeholder gradient. Replace with `AsyncImage` keyed off the Immich thumbnail endpoint (`/api/assets/<id>/thumbnail`).
6. **App icon.** Drop a 1024×1024 PNG into `iOS/App/Assets.xcassets/AppIcon.appiconset/` (Xcode complains at archive time without it).
7. **First on-device test** to validate PhotoKit enumeration, BGAppRefreshTask scheduling, and the actual end-to-end deletion flow against the user's Immich.
8. **First TestFlight build.**

## Things that are NOT done and probably need a session

- Snapshot tests for SwiftUI screens.
- Real Immich thumbnail loading in `MockAssetThumb`'s slot.
- BGAppRefreshTask validation on a real device (simulator lies about background tasks).
- App Store metadata + screenshots.
- Privacy policy page.

## Memory of historical bugs / lessons

- The Immich `/server/ping` endpoint returns `text/html` and 406s if you send `Accept: application/json`. Don't add an Accept header in `ImmichClient`.
- `IMMICH_URL` may or may not include `/api`. `ImmichClient.normalize` handles both.
- `search/metadata` excludes `hidden` visibility by default, which hides Live Photo motion videos. `assetsForTag` iterates all non-locked visibilities to surface them.
- `smartAlbumRecentlyDeleted` is iOS-only. PhotoKitPhotoEnumerator's `recentlyDeletedChecksums` returns empty on macOS for graceful degradation.
- `RunSummary` init takes `durationMs` and `notes` (added in Wave 1) — older callers will fail. Always include them.
- The harness's "is git repository" check is cached at session start; running `git init` mid-session leaves agent worktree isolation permanently disabled until the next session start. (Bug report at `notes/claude-code-bug-worktree-isolation.md`.)

## Memory and other forms of persistence

Memory is one of several persistence mechanisms available. For task-specific information, prefer plans/tasks. For this kind of cross-session project state, this CLAUDE.md is the right home. Don't write project state into Claude memory — it's meant for cross-conversation user/feedback context.
