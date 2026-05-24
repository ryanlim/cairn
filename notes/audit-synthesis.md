# cairn — architecture synthesis of three audits

Date: 2026-05-23. Synthesizes contributor-clarity, accessibility, and engine-clarity audits ahead of public Reddit launch.

## Overall state

The engine is in unusually good shape — the engine-clarity audit found zero architectural smells and zero protocol contracts you'd need to read iOS code to understand. The repo's *external surface* is the problem: docs lie about shipped behavior, the README/CLAUDE.md framing reads as a maintainer notebook, and the iOS UI ships with Dynamic Type disabled across every screen. The codebase is structurally launch-ready; the user-and-contributor-facing skin around it is not.

## Cross-cutting themes

**1. Docs encode wrong-but-historically-true reality.** The plan doc still describes `PHAssetCollectionSubtype.smartAlbumRecentlyDeleted` (which never existed) as the architecture. The plan doc names the core store `EverSeenStore`; code calls it `ObservedStore`; CLAUDE.md uses both. Strictness defaults flipped in code but not in the plan. The engine audit caught the same drift internally: `JournalEntry.Event.syncTransitions(confirmedFromPhotoKit:...)` bakes the older mental model into the *wire format*. This is a single problem manifesting at three layers — design doc, project context doc, and persisted schema.

**2. The "missing surface" pattern: things that exist but aren't routed to readers.** Tests-as-spec is excellent (contributor audit M-band, engine audit "What's right") but no document tells a contributor to read them. `notes/sync-*-plan.md` are active design docs ideal for contributor onboarding but filed under "ad-hoc notes." The HelpPopover system is the in-app documentation for every load-bearing setting but is broken for VoiceOver users (accessibility H11). `Sources/CairnCore/` has 30 files in a flat layout with no zoning. Pattern: load-bearing artifacts exist; the affordances that would surface them don't.

**3. Naming carries contract weight that isn't enforced.** The engine audit's H1/H2 (`union` vs `recordObserved` on `ObservedStore`) is the same shape of problem as the contributor audit's MEDIUM on `DeletionStrictness` enum fan-out and the accessibility audit's M3 on `CairnSegmentedPicker`'s empty `accessibilityValue`. In all three cases, the type system or naming conveys less contract than the docs/usage require, and the gap costs a contributor (or a screen-reader user) real interpretation work. The repo leans on conventions that aren't compiler-enforced.

**4. The destructive-workflow surfaces are the weakest accessibility surfaces.** DryRunSheet candidate grid (the moment of authorization), PendingReview row trash button (32×28pt, below 44pt minimum), ApiKeyRow Copy/Reveal buttons (16pt tap area on the most sensitive surface), the "READY TO TRASH" hero number (fails contrast in pending-amber state). The screens where mistakes have the highest cost are the screens with the worst accessibility hygiene.

**5. Multi-place mutation patterns without compiler help.** Adding a `DeletionStrictness` case requires touching 6 files. Adding an `ImmichClientError.Scope` case would require touching the string-array enums (engine M1). Adding a new Callout tone requires light/dark contrast matrix updates. The codebase doesn't punish "I changed one place and forgot the other" — neither at the engine layer nor the UI layer.

**6. The "maintainer notebook" signal cluster.** CLAUDE.md opener ("Guidance for Claude Code sessions"), absolute paths to maintainer's machine, Wave-numbered status table, `notes/claude-code-bug-worktree-isolation.md` checked into a directory the README doesn't mention, `.env_full` at repo root, committed `deletion-journal.jsonl` state file. Individually small; together they tell a Reddit-arriving contributor "this is one person's app." The engine *itself* doesn't carry this signal — it's all in the periphery.

**7. Live-region / progress affordance gaps.** The accessibility audit's H6, H9, M8, M13, M14 (ProgressBar lacks accessibilityValue, sync state changes silent, "Cancelling..." not announced, banner appearances silent) all point at the same architectural absence: cairn has no live-region announcement plumbing. The reconciliation engine is event-driven and stateful; the UI conveys those state transitions visually only. This isn't N findings — it's one missing system.

## Tensions / conflicts

**Engine audit praises doc-comments; contributor audit says docs are stale.** The conflict resolves cleanly: *engine-internal* doc-comments are good (file headers, `why we chose SHA1`, Apple-API rationale). *Repo-external* docs (plan doc, CLAUDE.md framing, README's "is this for me" gap) are stale or misframed. Different document classes, both true.

**Contributor audit wants CairnCore split into subdirectories; engine audit notes `EnvFileLoader` and `ImmichWriter` are already misfiled.** These reinforce each other but the *granularity* differs. The contributor wants directory zoning by *role* (core/protocols/orchestrators/api); the engine wants `ImmichWriter` moved out of `TrashOrchestrator.swift` because it's used by `RestoreOrchestrator` too. Doing the directory zoning first surfaces these mis-filings naturally.

**Accessibility wants Dynamic Type via `Font.system(size:relativeTo:)`; contributor audit notes the UI is already monolithic 2596-line files.** Globally swapping ~373 font calls in those monoliths is the kind of change that breaks design-review for sighted users while fixing a11y. These pull against each other on review velocity. Likely needs a tokens-layer fix (introduce `CairnTypography.body / .title / .caption` in `CairnPrimitives.swift`, route all sites through it) rather than 373 individual edits.

**Engine wants `gatedForReview()` moved off `ReconciliationOutput`; contributor audit wants more cross-file affordances for understanding the engine.** Moving the method makes the type cleaner for port authors but adds one more "where does this live" question for new contributors. Resolution: the method *should* move, and the engine docstring should point at it. The conflict is illusory if movement comes with a pointer.

**Accessibility H7 (decorative wordmark announced twice) and the cairn lowercase rule.** The brand wants "cairn" rendered carefully everywhere; VoiceOver users hear it three times on the onboarding welcome. Brand stewardship pulls against repetition reduction. Reasonable compromise: `accessibilityHidden(true)` on the decorative hero `CairnMark`, keep the inline `.cairnWord` in prose.

## Prioritized action table

The two personas: **C** = cold-arriving Reddit contributor; **U** = VoiceOver user with cairn installed.

| # | Action | Persona | Impact | Effort | Quadrant |
|---|---|---|---|---|---|
| 1 | Route fonts through a `CairnTypography` token layer (`.body/.title/.caption` semantic + `Font.system(size:relativeTo:)`) and apply to ~373 sites; fixes Dynamic Type globally | U | high | high | high-high (do anyway) |
| 2 | Archive `immich-ios-deletion-sync-plan.md` to `docs/history/` and remove the README link; rewrite README "Why" to include who-maintains, what's-shipped, what's-safe in the first 200 words | C | high | low | high-low (do first) |
| 3 | Reframe CLAUDE.md: split into `ARCHITECTURE.md` (human-facing, project history + conventions) + lean `CLAUDE.md` (AI session crib); both can quote each other | C | high | low | high-low (do first) |
| 4 | Add live-region announcements: `AccessibilityNotification.Announcement.post` for sync phase transitions, "Cancelling…", banner appearances, mass-offload detection. One helper in `CairnPrimitives` consumed by 4-6 sites | U | high | medium | high-mid |
| 5 | Resolve `EverSeenStore` ↔ `ObservedStore` ↔ `ever-seen` terminology drift: pick one (likely `ObservedStore` — code wins), update CLAUDE.md + remaining docs + the wire-format field `confirmedFromPhotoKit` → `confirmedFromChangeLog` before public release locks the journal schema | C+(port) | high | low | high-low (do first) |
| 6 | Tap-target audit: enforce 44×44pt on PendingReview row buttons, DryRun close, ApiKeyRow Reveal/Copy, RunDetail close. Single-file change in most cases | U | high | low | high-low (do first) |
| 7 | Add ToggleRow + ProgressBar + CairnSegmentedPicker + CairnRadioList accessibility labels/values/traits to the shared primitives. Fixes propagate to every screen for free | U | high | low | high-low (do first) |
| 8 | Fix muted/hint text contrast in light mode: darken `textMuted` to clear AA (≥4.5:1) and `textHint` to ≥3:1. Single-token change touches every screen | U | high | low | high-low (do first) |
| 9 | Add `Sources/CairnCore/README.md` zoning the 30 files into core/protocols/orchestrators/api/journal groups; or move into subdirs. Test dir gets the same treatment | C | medium | low-med | mid-low |
| 10 | Document `ObservedStore`'s two-write-API asymmetry at the protocol header (10-line table); rename `recordObserved` → `union(withTags:)` or add `Mode` enum to `MissedDeletionFinder.find` | C+port | medium | low | mid-low |
| 11 | Move `notes/sync-*-plan.md` to `docs/active-design/`, add CONTRIBUTING.md "Active design work" section linking them as starter-issue scaffolds. Remove `notes/claude-code-bug-worktree-isolation.md` from repo | C | medium | trivial | mid-low |
| 12 | Add `.github/PULL_REQUEST_TEMPLATE.md` and `CODE_OF_CONDUCT.md`; trigger GitHub Community Standards green check before Reddit launch | C | medium | trivial | mid-low |
| 13 | Sweep `.env_full` / committed state files (`deletion-journal.jsonl`, `ever-seen.json`) from working tree; verify `.gitignore`; rotate any secrets that hit the index | C | high (trust signal) | trivial | high-low (do first) |
| 14 | Modal a11y on zoom-overlay (DryRunSheet, PendingReviewScreen): add `accessibilityAddTraits([.isModal])` and `.accessibilityHidden(true)` on the underlying ScrollView | U | medium | trivial | mid-low |
| 15 | Add a tests/README that names the spec-quality test files; add one sentence to top-level README routing contributors to the test names | C | medium | trivial | mid-low |

Quadrant summary: items 2, 3, 5, 6, 7, 8, 13 are high-impact-low-effort and should ship before the Reddit launch. Item 1 (Dynamic Type) is the largest accessibility lift and probably can't ship before launch — but blocks an honest "accessible app" claim. Item 4 (live regions) is the second-largest a11y lift.

## What the agents missed

**The journal wire format is about to lock.** Engine audit's H5 caught `confirmedFromPhotoKit`, but the broader concern is that public release of cairn freezes the persisted journal schema for backward compatibility forever. Pre-launch is the *only* moment to rename `EverSeenStore` → `ObservedStore` in *persisted data* (right now there's one production user — the maintainer). The contributor audit and engine audit independently flagged the rename for their own reasons; nobody noted that the launch is the deadline.

**The audits don't address the trust gap of "what happens when something goes wrong in production."** Cairn is destructive software. The Reddit launch will produce a user reporting a perceived data loss — that's not pessimism, it's table stakes for the category. Three concrete absences nobody flagged: (a) no in-app "send diagnostic bundle" affordance (the user has to find their journal file on a sandbox path), (b) no public incident-response process documented in SECURITY.md or elsewhere, (c) the safety-net story ("trash not delete, 30-day Immich retention, 14-day quarantine") lives in section 8 of the README and *nowhere* in the app at the trash-confirmation moment. The accessibility audit notes the confirmation surfaces are opaque to VoiceOver; the trust-during-failure surfaces don't exist at all.

**The portability contract is praised but never tested.** Engine audit confirms only `Foundation`+`CryptoKit` imports in CairnCore. Good. But there's no CI step that *enforces* this — a future contributor adding `import PhotoKit` to a CairnCore file would build fine on iOS and silently break the Kotlin port intent. A `Tests/CairnCorePortabilityTests` that greps for forbidden imports would lock the contract in.

**App Store review interaction with accessibility.** The accessibility audit treats VoiceOver/Dynamic Type as a user-experience concern. But Apple has been *failing* App Store submissions for severe accessibility regressions (no Dynamic Type, no VoiceOver labels on critical controls). Pinning a TestFlight build's a11y baseline before submitting an update is now a release-blocker concern, not a polish concern.

**No agent looked at the Sources/CairnCLI surface.** All three audits scoped CairnCore + CairnIOSCore. The CLI is the entry point for Linux-side power users (a real Immich user demographic on r/selfhosted) and is the only `cairn` surface that runs on macOS today. Its contributor experience and accessibility profile are unaudited.

## Recommended top-3 next moves

**1. Pre-launch documentation sweep (1 day).** Archive the plan doc, split CLAUDE.md into ARCHITECTURE.md + AI-thin CLAUDE.md, add the README "is this for me" hero paragraph, route contributors to the test names, add a PR template, sweep `.env_full` and committed state. This is the cheapest, highest-impact bundle and it ships before Reddit traffic arrives. None of it requires touching production code.

**2. Pre-launch schema rename (half day).** Rename `confirmedFromPhotoKit` → `confirmedFromChangeLog` in the journal wire format with a one-version legacy-decode tolerance; resolve the `EverSeenStore`/`ObservedStore` doc drift in favor of code. This is the last chance before backward compatibility locks in. Engine audit's H5 plus the contributor audit's MEDIUM converge on this being a now-or-never decision.

**3. Accessibility floor for destructive surfaces (2-3 days).** Don't fix Dynamic Type globally yet (item 1 above is too large pre-launch). Do fix the destructive workflow specifically: 44pt tap targets on PendingReview rows and ApiKeyRow, accessibility labels on ToggleRow and ProgressBar primitives (propagates everywhere), modal traits on zoom overlay, live-region announcement helper wired into sync phase transitions, contrast token adjustment for `textMuted`/`textHint`. A VoiceOver user installing cairn from the App Store should be able to complete a trash batch with audible confirmation at every step. Everything else can iterate post-launch.

The fourth move, if there's appetite: introduce `CairnTypography` token layer and migrate fonts (Dynamic Type fix). This is the biggest impact-times-population item but doesn't fit in the launch window.
