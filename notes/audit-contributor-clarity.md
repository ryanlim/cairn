# Contributor onboarding audit — cairn

Audited 2026-05-23 by a first-impression reviewer pretending to be an Immich self-hoster who clicked through from r/immich. Findings ordered by impact on whether a stranger sticks around.

---

## HIGH: `immich-ios-deletion-sync-plan.md` is dangerously stale, and the README points new contributors at it as "the full design"

**Where:** `README.md:41` calls the plan doc "the full design ... including non-goals, failure modes, and the pivot from Recently-Deleted enumeration to persistent-change events." A reader who clicks that link to learn how cairn works gets a 476-line document that contradicts the shipped code on three core mechanisms.

**Concrete drift:**

1. **The whole "positive signal" architecture is wrong.** `immich-ios-deletion-sync-plan.md:229-277` (the entire "Confirmed-deletion signal (Wave 4)" section) describes a design built on enumerating `PHAssetCollectionSubtype.smartAlbumRecentlyDeleted` on a schedule. `CLAUDE.md:183` says this approach **never compiled** ("Apple never exposed Recently Deleted as a public enumerable subtype") and was replaced by `PHPhotoLibrary.fetchPersistentChanges`. The README points readers at the plan doc as authoritative; the plan doc invents an API that doesn't exist. The recommended user-facing copy at `immich-ios-deletion-sync-plan.md:266-275` ("cairn watches your Photos library and your Recently Deleted album") still ships the broken framing.
2. **The core type was renamed.** Code uses `ObservedStore` / `observedChecksums` / `StoredObservedChecksum` exclusively (see `Sources/CairnCore/ObservedStore.swift`, `Sources/CairnCore/ReconciliationEngine.swift:18`, `Sources/CairnIOSCore/SwiftDataStores.swift:22`). The plan doc uses `EverSeenStore` / `ever-seen` 13 times; CLAUDE.md still uses both interchangeably (`EverSeenStore` 8 times, `ever-seen` mixed in). The README does not name either — fine. But CLAUDE.md's `Repo layout` and `Identity model` sections feed the wrong vocabulary directly into the reader.
3. **Strictness defaults flipped.** `immich-ios-deletion-sync-plan.md:247` recommends `.strict` as the default; code default is `.trusting` (`Sources/CairnCore/CairnSettings.swift:199`, `Sources/CairnCore/ReconciliationEngine.swift:74`). CLAUDE.md:203 acknowledges the flip but the plan doc doesn't.

**Also stale but lower-impact:**
- `immich-ios-deletion-sync-plan.md:419` claims "Rough total: 20-40 hours of focused work to get to something usable and shareable." Code is ~31k LoC. Reading the doc top-down gives the wrong calibration.
- `immich-ios-deletion-sync-plan.md:444-451` is titled "Open questions for Phase 0" with a checklist of items most of which have been resolved long ago. Only #1 is annotated as resolved. The rest just sit there.

**Why it matters:** the plan doc is the document the README sends every new contributor to. It frontloads the reader with broken API knowledge they then have to unlearn against the code. Either the plan doc needs to be deleted/archived (move to `docs/history/`) or substantively rewritten as "design as shipped." The current state is worse than not having it.

---

## HIGH: CLAUDE.md is checked in as "human-readable project context" but reads as a Claude session crib sheet

**Where:** `README.md:109` mentions CLAUDE.md as "captures project conventions and accumulated context — worth reading before touching anything substantial." `CONTRIBUTING.md:38` says "Read CLAUDE.md before anything substantial." So humans are explicitly routed to it.

But CLAUDE.md's opening line is "Guidance for Claude Code sessions working in this repo." The framing through the whole 331-line file:

- `CLAUDE.md:13` references an absolute path on the maintainer's machine (`/Users/graham/code/cairn/`) and warns "older session contexts may reference the old path" — meaningless to a human reader.
- `CLAUDE.md:39-41` "Reference: Immich source" tells the reader Immich lives at `/Users/graham/code/immich`. A new contributor doesn't have that.
- `CLAUDE.md:43-66` is a "Wave-by-wave status" table that references project history (Wave 1/2/3A/3B/3C/4/4b/5) the reader has no context for. Test counts ("181 passing across 27 suites") read as a status update to a future Claude, not orientation for a human.
- `CLAUDE.md:240-269` ("Open work / known TODOs") + `CLAUDE.md:271-275` ("Things that are NOT done and probably need a session") refer to plans by code-internal name without explaining what they are. "Snapshot tests for SwiftUI screens" lands without saying what tool, who'd benefit, or whether this is welcoming PRs.
- `CLAUDE.md:277-291` ("Memory of historical bugs / lessons") is a list of trivia useful to a future Claude session, not to a stranger trying to land their first PR.
- `CLAUDE.md:293-294` ("Memory and other forms of persistence") is literally Claude-runtime guidance about not writing project state into Claude memory.

The accumulated history is genuinely valuable. But surfacing it through the Claude framing — with absolute paths, Wave numbers, and self-referential session guidance — sends the signal "this codebase is a maintainer's notebook, not a community project." A contributor reading this thinks "oh, this is one person's app that uses AI" and bounces.

Two things could fix this without losing the content: (a) split into `ARCHITECTURE.md` for humans + `CLAUDE.md` for Claude, or (b) rewrite CLAUDE.md's framing as "project conventions and history" with the AI-orientation moved to a single section at the top.

**Why it matters:** every contributor that CONTRIBUTING.md sends here gets the same "this is for AI" impression. Compounds with the previous finding (plan doc is stale) — both authoritative human-facing docs have problems.

---

## HIGH: README's "Why" answers "why does this exist" but skips "is this for me" and "who maintains it"

**Where:** `README.md:21-29`. The "Why" is precise on the technical gap. What's missing:

- **No statement of project maturity / scope of testing.** The README mentions "App Store" and "Current public release" but doesn't say "shipped May 2026, ~1 month old, primary maintainer is solo." A self-hoster considering pointing this at their photo library wants signal on how many people are using it, what data has been lost (none?), what the bus factor is. The absence reads as either "this is a corporate-backed thing" (it's not) or "the author thinks the question is too obvious to answer" (cautious self-hosters specifically need this answered).
- **No "is this safe for me to try" callout up high.** The Safety Model section is at line 66; for a r/immich reader who's primarily worried about losing photos, that's too deep. The single most important reassurance — *trash, not delete; 30-day Immich retention; 14-day quarantine; first-run forced dry-run* — should be in the second paragraph, not the eighth section.
- **No "I want to contribute, but I run Android / non-iOS" landing.** Plan doc + CLAUDE.md spend a lot of words on Kotlin portability, but README never mentions it. An Android Immich user reading the README has no idea this codebase is structured to invite a Kotlin port; CONTRIBUTING.md doesn't either. That's a missed opportunity for inbound contributor energy on r/immich.

**Why it matters:** the launch audience is *cautious self-hosters*. They will not install an app that deletes things until the README has answered (1) who built this, (2) what the failure mode is, and (3) what the safety net is. README answers (3) eventually but punts (1) and (2).

---

## HIGH: `Sources/CairnCore/` is dense and not zoned — a stranger can't tell which files are entry points and which are utility

**Where:** `ls Sources/CairnCore/` shows 30 files in flat layout. From the filename alone, can you tell which of these is the entry point?

```
CairnExportPayload.swift          Hashing.swift                  ReconciliationEngine.swift
CairnSettings.swift               ImmichClient.swift             RestoreOrchestrator.swift
ConfirmedDeletedStore.swift       ImmichThumbnailLoader.swift    SafetyRails.swift
DeferredHashStore.swift           JournalReader.swift            SecretStore.swift
DeletionJournal.swift             LocalAssetMetadataStore.swift  ServerAssetCacheStore.swift
DeletionSourceStore.swift         LocalHashStore.swift           ServerAssetSyncCoordinator.swift
EditRetirementStore.swift         MissedDeletionFinder.swift     StatusSnapshotStore.swift
ExclusionStore.swift              ObservedStore.swift            SyncEntities.swift
                                  OrphanReconciler.swift         TagSchema.swift
                                  PendingTrashIntentStore.swift  TrashOrchestrator.swift
                                  PersistentChangeTokenStore.swift Types.swift
                                  PhotoEnumerator.swift
```

The CLAUDE.md "Repo layout" section (`CLAUDE.md:15-37`) names only `CairnCore` at the directory level — doesn't break down what's inside. The README similarly punts. So a new contributor looking for "where does the reconciliation algorithm live" has to:

1. Read CLAUDE.md or the plan doc to learn the type is named `ReconciliationEngine`.
2. Then find `ReconciliationEngine.swift` in the flat list (works, but only because they now know the name).
3. For "where do API calls live," guess `ImmichClient.swift` — fine.
4. For "where does the hash pipeline live," guess `Hashing.swift` for the algorithm + `LocalHashStore.swift` for the cache + `PhotoEnumerator.swift` for the protocol — that's three files for one mental concept, no doc that says so.

Sources/CairnCore contains a mix of: **core algorithms** (`ReconciliationEngine`, `SafetyRails`, `Hashing`), **protocols** (`ObservedStore`, `ExclusionStore`, `ConfirmedDeletedStore`, `EditRetirementStore`, `LocalHashStore`, `PhotoEnumerator`, `SettingsStore`, `SecretStore`, `LocalAssetMetadataStore`, `ServerAssetCacheStore`, `DeferredHashStore`, `DeletionSourceStore`, `PendingTrashIntentStore`, `StatusSnapshotStore`, `PersistentChangeTokenStore`), **orchestrators** (`TrashOrchestrator`, `RestoreOrchestrator`, `OrphanReconciler`, `MissedDeletionFinder`, `ServerAssetSyncCoordinator`), **HTTP / API** (`ImmichClient`, `ImmichThumbnailLoader`, `SyncEntities`, `TagSchema`), **journal / forensics** (`DeletionJournal`, `JournalReader`), and **value types** (`Types`, `CairnSettings`, `CairnExportPayload`).

A new contributor has no way to discover this grouping without reading every file. A `Sources/CairnCore/README.md` (or even a one-line file header comment categorizing each into a group) would do it; alternatively splitting into subdirectories (`Core/`, `Protocols/`, `Orchestrators/`, `API/`, `Journal/`).

Tests/CairnCoreTests has the same flat-layout issue (28 files).

**Why it matters:** the "60-second discoverability" test fails. With README open, a stranger can find `ReconciliationEngine.swift` if and only if they know to grep for that name. The READMEs don't name the file; CONTRIBUTING.md doesn't either.

---

## MEDIUM: Identifiers are PascalCase Swift but the product is "cairn (lowercase)" — and the rationale lives only in CLAUDE.md

**Where:** A contributor looking at `Sources/CairnCore/Types.swift` sees `struct Checksum`, `struct ServerAsset`, `struct RunID`. Looks normal. Then they look at `README.md` and see "cairn" lowercase consistently. Then `CHANGELOG.md` says "cairn ... reconciles". Then they look at `Package.swift` and see `let package = Package(name: "Cairn", ...)`. Confusion.

CLAUDE.md:5-9 explains this (lowercase in prose, PascalCase Swift, `cairn` binary, `cairn/v1/` tag prefix). CONTRIBUTING.md:47 gives a one-line rule. The plan doc has the long version at lines 97-107.

But CONTRIBUTING.md is the natural place. A new contributor opens it, reads two lines about naming, doesn't realize that "cairn lowercase in user-facing prose" is a load-bearing rule that's been litigated in detail (App Store trademark risk, brand confusion, Immich-FAQ stewardship). They paraphrase "Cairn" in a PR's copy and get review feedback they don't understand the weight of.

Compounded by **inconsistent stylization in code comments:** some files have `cairn` lowercase in their doc comments (`Types.swift:7`), some uppercase (`SafetyRails.swift` mixed), some skip the brand entirely. There's no enforcement; the rule lives only in human convention.

**Why it matters:** small but persistent friction in PR reviews. The rule is real and rule-of-thumb compatible; surfacing the *why* (App Store trademark + Immich brand stewardship) in CONTRIBUTING.md would head off the recurring conversation.

---

## MEDIUM: No PR template, no CODE_OF_CONDUCT, no ARCHITECTURE — issue templates exist but nothing scaffolds a PR

**Where:**
- `.github/ISSUE_TEMPLATE/bug_report.yml` — solid, asks for cairn version, iOS version, Immich version, journal entries. Well-thought-out.
- `.github/ISSUE_TEMPLATE/feature_request.yml` — also solid, leads with the "cairn is deliberately narrow" framing.
- `.github/ISSUE_TEMPLATE/config.yml` — points security issues to private advisory. Correct.
- `.github/PULL_REQUEST_TEMPLATE.md` — **missing.**
- `CODE_OF_CONDUCT.md` — missing (the only matches were in vendor checkouts).
- `ARCHITECTURE.md` / `DEVELOPING.md` — missing. CLAUDE.md was meant to fill the gap; see the "CLAUDE.md framing" finding above for why it half-doesn't.

The PR template absence isn't catastrophic, but Reddit-driven contributors are explicitly the audience and tend to be the kind of self-host community member who reads the templates. Without a PR template, every first-time PR has the chance to skip:
- linking to a discussion issue (CONTRIBUTING.md says "open an issue first" for non-trivial changes — a PR template field forces the link to be visible)
- the test-pass checkbox
- the `CHANGELOG.md` reminder (`CONTRIBUTING.md:53` mentions it; a PR template would surface at submit time)

CODE_OF_CONDUCT being absent is mostly cosmetic for a project this size but GitHub's "Community Standards" health check will flag it; for a project being publicized on Reddit, a 30-second CoC reduces a vector of inbound friction.

**Why it matters:** issue templates being this thoughtful sets the expectation that PR onboarding will be too. Hitting "Create pull request" and getting a blank textarea drops that expectation.

---

## MEDIUM: The "plausible small contribution" trace — adding a new `DeletionStrictness` mode requires touching 6 files with no doc to guide it

**Where:** Imagine a contributor wants to add a `.paranoid` mode (everything goes to pending review, no auto-trash ever). They need to edit:

1. `Sources/CairnCore/CairnSettings.swift:466` — add the case to `enum DeletionStrictness`.
2. `Sources/CairnCore/ReconciliationEngine.swift:275-288` — extend the `switch input.strictness` block. Currently no `@unknown default` so the compiler flags this; the contributor finds it, but only after building.
3. `Sources/CairnCLI/Cairn.swift:65-67` — update the CLI flag's help text to mention the new mode (no compile failure; easy to miss).
4. `Sources/CairnIOSCore/UI/SettingsScreen.swift` — add the new option to the strictness picker (no compile failure if the picker iterates `DeletionStrictness.allCases`; need to check copy).
5. `Sources/CairnIOSCore/UI/SetupScreen.swift` — same, for the onboarding flow.
6. `Sources/CairnIOSCore/UI/CairnPrimitives.swift` — `DeletionStrictness` reference suggests there's a display-name helper; needs the new case mapped.
7. Tests — `Tests/CairnCoreTests/ReconciliationEngineTests.swift` should pin the new behavior. Existing tests for `.strict` and `.trusting` give a clear pattern.

**The friction:**
- No doc lists this fanout. CONTRIBUTING.md doesn't say "user-facing enums need updates in N places."
- No script or test that enforces "every `DeletionStrictness` case has a `displayName` mapping" — the contributor can ship a PR that compiles, passes existing tests, and silently shows the new case with an ugly raw-value label in the UI.
- The picker copy and the CLI help text drift independently (no shared "DeletionStrictness.userVisibleDescription" property).

For "fix a typo in a UI string" the trace is much friendlier — `grep -r "the typo'd phrase" Sources/CairnIOSCore/UI/` finds it, edit, done. The microcopy convention (`CONTRIBUTING.md:46`, `Sources/CairnIOSCore/UI/StatusScreen.swift:24-25` "Microcopy is verbatim from the prototype") might trip the contributor since multiple files cite HANDOFF.md as a source of truth for copy — a typo-fix PR could get pushback ("does the prototype say this?") that the contributor wasn't warned about. The prototype lives at `cairn/HANDOFF.md` per `CLAUDE.md:32` ("Reference, not shipped"), but a typo-fixing contributor reading CONTRIBUTING.md alone won't know to consult it.

**Why it matters:** the small-PR happy path is fine. The medium-PR happy path is the boundary where contributors abandon — they make a change, six files change, the CI passes, but a reviewer says "you missed X, Y, Z." Without docs that scaffold the multi-file change pattern, this churn falls on the maintainer.

---

## MEDIUM: Test files are excellent spec material but unsearchable for stranger-readers

**Where:** `Tests/CairnCoreTests/ReconciliationEngineTests.swift` is genuinely a readable spec. Test names like `"never deletes a server asset whose checksum was never on the iPhone — Mac-only uploads are safe"` (`:35`), `"first run with empty observed set produces no deletions and seeds observed with all current checksums"` (`:46`), `"empty local library with populated observed would flag everything — engine emits it; safety rails must catch"` (`:57`). These are model behavior statements in plain English. Same quality in `SafetyRailsTests`, `TrashOrchestratorTests`, etc.

**Three places the contributor experience drops:**

1. **Discovery.** Nobody is told this. CONTRIBUTING.md:42 mentions "Tests are the conformance spec" — true but contextless. README doesn't reference it. A stranger looking for "how does cairn handle the edge case where I edit a photo then delete it" doesn't think "let me grep the test names"; they grep the source. The maintainer wrote good specs; nobody is being routed to them.

2. **Cross-file context.** `TestFakes.swift` defines `FakeWriter` (`:6`) but nothing in `ReconciliationEngineTests.swift` actually uses it — the engine tests use locally-defined helpers. The grouping isn't intuitive. A `Tests/README.md` listing "if you want to understand X, read Y_test" would do a lot.

3. **`MockURLProtocol.swift` is duplicated** in `Tests/CairnCoreTests/MockURLProtocol.swift` and `Tests/CairnIOSCoreTests/MockURLProtocol.swift`. Both files have substantially similar content. A new contributor adding a test might add to one and not realize the other exists; would-be cross-file refactors are gated on noticing this.

**Why it matters:** the tests are one of the best contributor onboarding artifacts in the repo. They're invisible. Adding a single sentence to README — *"the test names in `Tests/CairnCoreTests/` are the conformance spec for the reconciliation algorithm; start there"* — would surface them.

---

## MEDIUM: `notes/` is partially internal, partially planning, partially session-state — all checked in, none explained

**Where:** Top-level `notes/` directory contains three files:

- `notes/claude-code-bug-worktree-isolation.md` — a bug report for the Claude Code harness. Not relevant to cairn contributors at all.
- `notes/sync-narration-plan.md` (13kb) — a design plan for a feature.
- `notes/sync-stream-incremental-server-sync-plan.md` (24kb, updated 2026-05-23) — a design plan for the incremental sync work (`CLAUDE.md:173` references it as documentation).

The CLAUDE.md description (`:33`) says "notes/ — Bug reports + ad-hoc notes to file later." Nothing in the README or CONTRIBUTING.md mentions this directory.

A contributor stumbles into `notes/`:
- Sees the Claude-Code bug report and gets the same "this is an AI-maintained project" signal as the CLAUDE.md framing problem.
- The two sync plans are *active* design docs for unshipped/in-progress work. A would-be contributor on incremental sync (a great onboarding wedge — solo dev needs help, contributor reads the plan and lands a PR) has no way to know this is actually a starter doc rather than "internal scratch space."

**Why it matters:** the sync plans are valuable contributor-onboarding artifacts. Currently they're filed under a directory CLAUDE.md describes as "ad-hoc notes to file later" — undersells them. Moving `notes/sync-*-plan.md` into `docs/` and adding a "Active design work" section to CONTRIBUTING.md that links them would convert internal notebook content into contributor invitation.

---

## LOW: Repo root has 7 markdown files at top level — clutter

**Where:** Root: `README.md`, `CHANGELOG.md`, `CLAUDE.md`, `CONTRIBUTING.md`, `LICENSE`, `PRIVACY.md`, `SECURITY.md`, `immich-ios-deletion-sync-plan.md`. Plus `Package.swift`, `Package.resolved`, `.env`, `.env_full`, `.env.example`, `deletion-journal.jsonl`, `ever-seen.json`, `.gitignore`, etc.

The mixed-purpose root is hard to scan. `immich-ios-deletion-sync-plan.md` should be in `docs/` (it's a planning doc, not a top-level project root concern). `PRIVACY.md` and `SECURITY.md` at root are fine (GitHub Community Standards expects these placements).

Also: `deletion-journal.jsonl` and `ever-seen.json` appear to be committed *state files* at root rather than gitignored runtime output. CLAUDE.md:89 says these should be gitignored. Let me check — those files exist at the root and weren't ignored. Either they're intentional fixtures (label them as such) or they're an oversight; either way, contributors will be confused.

**Why it matters:** noisy root surface reduces signal-to-noise. The mid-priority finding is "rename / relocate the plan doc"; the leftover state files are a nit but worth a sweep.

---

## LOW: `.env` and `.env_full` exist at repo root

**Where:** `ls -la /Users/graham/code/cairn/` shows `.env` (102 bytes) and `.env_full` (102 bytes). `.gitignore` lists `.env` per the README + CLAUDE.md security guidance. Did the maintainer remember to gitignore `.env_full`? Worth a quick check; either way, the surface area for "I cloned and noticed the maintainer's `.env`" is undesirable.

(This is a maintainer-hygiene finding, not a contributor-experience finding — but it's the kind of thing a security-conscious self-hoster will notice within seconds of cloning.)

**Why it matters:** trust signal for a project whose pitch is "you trust this with your photo library."

---

## LOW: SwiftUI screen files are very large (StatusScreen 2596 lines, SettingsScreen 1924, PendingReviewScreen 1518)

**Where:** `wc -l Sources/CairnIOSCore/UI/*.swift` shows StatusScreen.swift at 2596 lines, SettingsScreen at 1924, PendingReviewScreen at 1518, CairnPrimitives at 1778, CairnAppModel at 1169. CairnFixtures at 915.

This is mostly a code-architecture finding (out of scope per task brief). The contributor-experience angle: a contributor wanting to add or modify any UI element opens a 2596-line Swift file and has to scroll/search to find the section they want. Section comments are present (`// MARK: -` blocks are used), but the UI-screen-as-monolith pattern means even small changes require holding a lot of context.

For comparison, the design prototype at `cairn/` is structured screen-per-file with cleaner separation. The SwiftUI port collapsed each screen back into a single Swift file. This will burn contributor time on every iOS PR.

**Why it matters:** mostly small but it interacts with finding #6 (multi-file fan-out): once a contributor finds the file, they then have to navigate within it. Twice the friction per PR.

---

# Summary of impact-ordered fixes the maintainer could consider

1. **Resolve plan doc vs reality drift** — either archive `immich-ios-deletion-sync-plan.md` to `docs/history/` and remove the README link, or rewrite as "design as shipped" (high impact, medium effort).
2. **Reframe CLAUDE.md for human readers** — either split into `ARCHITECTURE.md` (human) + `CLAUDE.md` (AI), or rewrite the opener (high impact, low–medium effort).
3. **Add a "is this safe for me to try" hero answer to README** — second paragraph, before the technical pitch (high impact, low effort).
4. **Add a `Sources/CairnCore/README.md`** or zone into subdirectories (high impact, low–medium effort).
5. **Add `.github/PULL_REQUEST_TEMPLATE.md`** and possibly `CODE_OF_CONDUCT.md` (medium impact, low effort).
6. **Resolve the `EverSeenStore` ↔ `ObservedStore` terminology drift** — pick one, update docs (medium impact, low effort).
7. **Route contributors to the test names as spec** — sentence in README, optional Tests/README.md (medium impact, low effort).
8. **Move `notes/sync-*-plan.md` into `docs/`** and surface them as active contributor invitations (medium impact, low effort).
9. **Remove `.env_full` from working tree; verify `.gitignore` covers it** (low impact, trivial effort).
