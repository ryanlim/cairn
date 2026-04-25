# Next steps

What's left between "works end-to-end on my device" and "publicly shipped on GitHub + the App Store." Living checklist — update as items land.

Sections:
1. [GitHub push](#github-push)
2. [App Store submission prep](#app-store-submission-prep)
3. [Post-launch / nice-to-haves](#post-launch--nice-to-haves)

Conventions:
- `[ ]` open, `[x]` done, `[~]` in-progress.
- Items tagged **external** require Apple-side or github.com-UI work, not code.
- Items tagged **code** / **doc** are in-repo.

---

## GitHub push

### Blocking

- [x] **Commit the working tree.** 8 commits landed: core library, iOS impls, SwiftUI screens, app shell, tests, screenshot automation, pre-launch docs, gitignore.
- [x] **`.gitignore` covers the risky paths.** Verified: `.env`, `.dev-secrets`, `Cairn.xcodeproj/`, `vendor/`, `.bundle/`, `fastlane/screenshots/`, `.ipa`, `.dSYM`, etc.
- [x] **Privacy-policy URL.** GitHub Pages deployed at `https://glarue.github.io/cairn/PRIVACY`. Referenced from `docs/app-store-metadata.md`.

### Strongly recommended

- [x] **Embed screenshots in README.** Status, Pending Review, Setup Welcome — inline at 220px.
- [ ] **Repo description + topics.** _external._ On github.com: short description + topics (`immich`, `ios`, `swift`, `swiftui`, `photos`, `photo-management`, `self-hosted`, `photo-sync`, `immich-client`, `apple-photos`). Set via GitHub UI.
- [ ] **Cut `v0.1.0` tag.** _external._ `CHANGELOG.md` already has the 0.1.0 section. One `git tag v0.1.0 && git push --tags` after the full code push lands.

### Nice-to-haves

- [ ] **Branch protection on `main`** — require PR + CI pass. GitHub Settings → Branches. Post-push.
- [ ] **Enable GitHub Security advisories.** `SECURITY.md` already points at the private-advisory flow; the feature needs to be toggled on in the repo's Security tab.

---

## App Store submission prep

Ordered checklist — work through top to bottom.

### 1. Apple Developer account

- [ ] **Paid Apple Developer membership.** _external._ $99/year. Without it, no TestFlight + no App Store. Enroll at [developer.apple.com/enroll](https://developer.apple.com/enroll). Can take up to 48 hours to process.

### 2. App Store Connect setup

- [ ] **Create app record** in App Store Connect with bundle ID `app.cairn.ios`. Watch for name collision — "cairn" may already be claimed or rejected as too generic. Fallback names: `cairn for Immich`, `cairn — Immich sync`, `cairn · Immich`.
- [ ] **Create App Store Connect API key.** Users & Access → Integrations → App Store Connect API. Download the `.p8` file and note the Key ID + Issuer ID. Export as env vars for Fastlane:
  ```sh
  export APP_STORE_CONNECT_API_KEY_KEY_ID="..."
  export APP_STORE_CONNECT_API_KEY_ISSUER_ID="..."
  export APP_STORE_CONNECT_API_KEY_KEY_FILEPATH="~/.appstoreconnect/AuthKey_XXXX.p8"
  ```

### 3. Signing + provisioning

- [ ] **Set `DEVELOPMENT_TEAM` in Xcode.** Open `Cairn.xcodeproj` → Signing & Capabilities → select your team. Persists across `make generate` runs.
- [ ] **Fastlane Match setup** — `make setup-certs`. Creates a private git repo holding encrypted certs. `make sync-certs` is the read-only counterpart for other machines / CI.

### 4. Build + smoke test

- [ ] **First TestFlight build.** `make beta` — builds IPA, uploads to TestFlight.
- [ ] **Smoke test on a real device** via TestFlight. Validate: PhotoKit enumeration against a real library, end-to-end s   ync against your Immich, background refresh scheduling (simulator lies about `BGAppRefreshTask`).

### 5. Reviewer access

- [ ] **Reviewer Immich instance.** `docs/app-store-review-notes.md` has `REPLACE-BEFORE-SUBMISSION` placeholders for URL + API key. Either (a) spin up a dedicated Immich kept live during Apple's review window (~3–7 days), or (b) point reviewers at [demo.immich.app](https://demo.immich.app/) with a note about rate limits. Apple has historically accepted option (b).

### 6. Submit

- [ ] **`make release`** — builds IPA, uploads to App Store Connect.
- [ ] **Paste metadata** from `docs/app-store-metadata.md` (description, keywords, subtitle, support URL, marketing URL).
- [ ] **Set category + age rating.** Photo & Video primary, Utilities secondary, 4+. Answers pre-drafted in `docs/app-store-metadata.md`.
- [ ] **Paste privacy labels** from `docs/app-store-privacy-labels.md`.
- [ ] **Paste review notes** from `docs/app-store-review-notes.md` (with real reviewer credentials filled in).
- [ ] **Privacy policy URL.** `https://glarue.github.io/cairn/PRIVACY`
- [ ] **Upload screenshots** from `iOS/fastlane/screenshots/en-US/`.
- [ ] **Record and attach screen recording.** Full end-to-end flow (setup → index → delete photos → sync → confirm trash → restore). Attach as App Review Attachment.
- [ ] **Submit for review.**

### Already done

- [x] **Fira Code license file.** `LICENSES/FiraCode.OFL.txt` — OFL-1.1 text with correct copyright line.
- [x] **Accessibility pass.** VoiceOver labels on all icon-only buttons, `.accessibilityValue()` on custom controls, `accessibilityReduceMotion` gating on all animations.
- [x] **Version & build numbers.** `CFBundleShortVersionString: "0.1.0"` + `CFBundleVersion: "1"` in `iOS/project.yml`.
- [x] **App icon.** Light + dark variants in place.
- [x] **Screenshot pipeline.** `make screenshots` produces light + dark sets for two device sizes.
- [x] **Privacy policy.** Live at `https://glarue.github.io/cairn/PRIVACY`.

---

## Post-launch / nice-to-haves

Not blockers. Move up the priority list only if a user flags them.

- [ ] **Snapshot tests for SwiftUI screens.** `swift-snapshot-testing` from Point-Free. Priority targets: Setup steps, DryRunSheet phases, PendingReviewScreen variants.
- [ ] **Background task validation on real device.** Simulator lies about `BGAppRefreshTask` scheduling. One overnight charging run on hardware would confirm the real behavior.
- [ ] **Local OS notifications for backlog alerts.** In-app banner exists; next step is `UNUserNotificationCenter` permission + edge-triggered fire from `handleBackgroundRefresh` + deep link.
- [ ] **`cairn/v2` tag schema.** Currently on v1. No pressure to bump; noting the extensibility hook for when a breaking change to run-breadcrumb shape is needed.
- [ ] **Android port.** Deliberately deferred. `CairnCore` stays pure Foundation + CryptoKit so a Kotlin port is tractable. Decision criteria and port order live in the plan doc's "Portability" section.
- [ ] **Push full source to GitHub.** Force-push `main` over the skeleton branch once the app is in review.

---

_Last updated: 2026-04-23. Keep this file honest — either mark items done or remove them when stale._
