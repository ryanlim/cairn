# Next steps

What's left between "works end-to-end on my device" and "publicly shipped on GitHub + the App Store." Living checklist — update as items land.

Sections:
1. [GitHub push](#github-push)
2. [App Store submission](#app-store-submission)
3. [Post-launch / nice-to-haves](#post-launch--nice-to-haves)

Conventions:
- `[ ]` open, `[x]` done, `[~]` in-progress.
- Items tagged **external** require Apple-side or github.com-UI work, not code.
- Items tagged **code** / **doc** are in-repo.

---

## GitHub push

### Blocking

- [ ] **Commit the working tree.** _code._ ~50 modified files from recent sessions (docs, copy tweaks, docstring pass, test additions, wordmark asset). Nothing broken; just needs sensible commits. Suggested grouping: (a) docstring pass + tests, (b) docs + PRIVACY/SECURITY/CONTRIBUTING/CHANGELOG + `.github/`, (c) copy polish + fixture mode + screenshot pipeline, (d) wordmark export + brand assets.
- [x] **`.gitignore` covers the risky paths.** Verified: `.env`, `.dev-secrets`, `Cairn.xcodeproj/`, `vendor/`, `.bundle/`, `fastlane/screenshots/`, `.ipa`, `.dSYM`, etc.
- [ ] **Decide on privacy-policy URL.** _external / trivial._ `docs/app-store-metadata.md` currently points at `https://github.com/glarue/cairn/blob/main/PRIVACY.md`. Apple accepts raw-GitHub URLs but prefers a rendered page. Enable GitHub Pages → Settings → Pages → Source: `main` / folder: `/docs`. Five minutes, post-push.

### Strongly recommended

- [ ] **Embed screenshots in README.** _code._ `<!-- TODO: screenshots -->` still sits there. `make screenshots` produces them; inline 2–3 (Status + Pending Review + Setup Welcome) for first-impression.
- [ ] **Repo description + topics.** _external._ On github.com: short description + topics (`immich`, `ios`, `photos`, `self-hosted`, `swift`, `photo-management`). Drives discovery. Set via GitHub UI after push.
- [ ] **Cut `v0.1.0` tag.** _external._ `CHANGELOG.md` already has the 0.1.0 section. One `git tag v0.1.0 && git push --tags` after the initial push lands.

### Nice-to-haves

- [ ] **Branch protection on `main`** — require PR + CI pass. GitHub Settings → Branches. Post-push.
- [ ] **Enable GitHub Security advisories.** `SECURITY.md` already points at the private-advisory flow; the feature needs to be toggled on in the repo's Security tab.

---

## App Store submission

### Hard prerequisites (external — not code)

- [ ] **Paid Apple Developer membership.** _external._ $99/year. Without it, no TestFlight + no App Store. Free-tier provisioning only works on personally-owned test devices.
- [ ] **App Store Connect app record** with bundle ID `app.cairn.ios`. **Watch for a name collision** — App Store doesn't preserve casing, and "cairn" may already be claimed or rejected as too generic. Fallback names: `cairn for Immich`, `cairn — Immich sync`, `cairn · Immich`. The trademark-safety language in `app-store-metadata.md` already uses the "for Immich" framing where nominative fair-use applies.
- [ ] **App Store Connect API key.** _external._ Set up under Users & Access → Keys in App Store Connect. Export the three env vars Fastlane reads:
  - `APP_STORE_CONNECT_API_KEY_KEY_ID`
  - `APP_STORE_CONNECT_API_KEY_ISSUER_ID`
  - `APP_STORE_CONNECT_API_KEY_KEY_FILEPATH`
  Drop them in a shell rc file (not in the repo). `make beta` and `make release` depend on these.
- [ ] **Fastlane Match setup** — `make setup-certs` once. Creates a private git repo (or S3 bucket) holding encrypted certs. `make sync-certs` is the read-only counterpart for other machines / CI.
- [ ] **Set `DEVELOPMENT_TEAM` once in Xcode.** `project.yml` leaves it blank on purpose; Xcode writes it into the regenerated `.xcodeproj` on first build. Persists across `make generate` runs via XcodeGen's `attributes:` block.
- [ ] **Hosted privacy-policy URL.** Same as "Decide on privacy-policy URL" above — GitHub Pages or external host.

### In-repo work remaining

- [ ] **Reviewer Immich instance.** _doc._ `docs/app-store-review-notes.md` has `REPLACE-BEFORE-SUBMISSION` placeholders for URL + API key. Either (a) spin up a dedicated Immich for review (kept live during Apple's review window, ~3–7 days), or (b) point reviewers at [demo.immich.app](https://demo.immich.app/) with a note about rate limits. Apple has historically accepted option (b).
- [ ] **Version & build numbers.** `CFBundleShortVersionString: "0.1.0"` + `CFBundleVersion: "1"` in `iOS/project.yml`. Fine for first submission. `make beta` auto-increments build number from TestFlight after that.
- [ ] **Category + age rating in App Store Connect.** Answers pre-drafted in `docs/app-store-metadata.md` (Photo & Video primary, Utilities secondary, 4+). Paste during submission flow.
- [ ] **Fira Code license file.** _code._ The app bundles Fira Code via `CairnFonts.registerBundledFonts()`. Fira Code is OFL-1.1, which requires the license text be distributed with derivatives. Add `LICENSES/FiraCode.OFL.txt` to the repo. Tiny but technically required.
- [ ] **Accessibility pass.** _code._ No audit done yet for VoiceOver labels, Dynamic Type scaling, reduced-motion handling. Not a hard Apple-review blocker, but worth an hour before shipping — the audience cares about craft. Targets: all button accessibility labels, custom gesture handlers, the custom primitives (`CairnChip`, `CairnSegmentedPicker`, `CairnRadioList`, `RowIconButton`).

### Submission flow once prerequisites are met

```
make setup-certs     # once per team
make beta            # builds + uploads to TestFlight
   → wait for processing (10–30 min)
   → smoke-test via TestFlight on a real device
make release         # builds + uploads to App Store Connect
   → paste metadata from docs/app-store-metadata.md
   → paste review notes from docs/app-store-review-notes.md
   → paste privacy labels from docs/app-store-privacy-labels.md
   → upload screenshots from fastlane/screenshots/en-US/
   → submit for review
```

---

## Post-launch / nice-to-haves

Not blockers. Move up the priority list only if a user flags them.

- [ ] **Snapshot tests for SwiftUI screens.** `swift-snapshot-testing` from Point-Free. Priority targets: Setup steps, DryRunSheet phases, PendingReviewScreen variants. See CLAUDE.md TODO #2.
- [ ] **Background task validation on real device.** Simulator lies about `BGAppRefreshTask` scheduling. One overnight charging run on hardware would confirm the real behavior. See CLAUDE.md TODO #1.
- [ ] **Local OS notifications for backlog alerts.** In-app banner exists; full implementation sketch in CLAUDE.md TODO #6 (`UNUserNotificationCenter` permission + edge-triggered fire from `handleBackgroundRefresh` + deep link).
- [ ] **`cairn/v2` tag schema.** Currently on v1. No pressure to bump; noting the extensibility hook for when a breaking change to run-breadcrumb shape is needed.
- [ ] **Android port.** Deliberately deferred. `CairnCore` stays pure Foundation + CryptoKit so a Kotlin port is tractable. Decision criteria and port order live in the plan doc's "Portability" section.

---

_Last updated: 2026-04-23. Keep this file honest — either mark items done or remove them when stale._
