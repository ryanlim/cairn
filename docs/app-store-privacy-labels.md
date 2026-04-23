# App Store privacy labels

Answers to the App Store Connect privacy questionnaire. This file exists so the submission is reproducible and auditable — if someone asks "why does `cairn` claim to collect no data," this is the receipt.

The short version: **`cairn` declares "Data Not Collected"** — no categories apply. No analytics, crash reporting, identifiers, ads, or third-party SDKs are integrated into the app.

## First question — "Do you or your third-party partners collect data from this app?"

**Answer: No, we do not collect data from this app.**

Justification:
- `cairn` does not contact any server other than the user's own Immich instance, authenticated with their own API key.
- There are no analytics libraries linked (no Firebase, Mixpanel, Amplitude, App Center, PostHog, Sentry, Bugsnag, etc.).
- There is no Apple / advertising identifier collection (no `AdSupport.framework`, no `ATTrackingManager` usage).
- iOS's own crash reporting (available to the user in the Settings app, optionally shared with Apple under their system privacy settings) is not something `cairn` opts anyone into or receives.
- Photos bytes are read locally, hashed in memory, and discarded. Hashes (SHA1 base64) are stored locally only — never transmitted anywhere outside the user's Immich server.
- Keychain entries (Immich URL, API key) never leave the device.

This answer unlocks the "Data Not Collected" privacy label in App Store Connect. No further questions in the questionnaire apply.

## If Apple pushes back

Apple's privacy-label review occasionally flags apps even when "Data Not Collected" is accurate. If they do:

- The network-code surface area is deliberately small. See `Sources/CairnCore/ImmichClient.swift` — every request goes to `self.baseURL`, which is the user-supplied Immich URL. There is no other `URLSession` call in the app.
- Thumbnails are fetched via `Sources/CairnIOSCore/ImmichThumbnailLoader.swift`, same baseURL, no third-party CDN.
- Build by cloning the repo, inspecting `Package.swift` and `iOS/project.yml` — there are no analytics-ish dependencies.

## If we ever add something

If any data collection is introduced (even "optional" crash reporting with user opt-in), this file has to be updated in the same PR that adds the dependency, and the App Store label has to be updated in the same submission. Don't let the label drift from reality.

Likely future cases to reconsider here:

- Local OS notifications for the backlog alert (CLAUDE.md TODO #7) — these don't collect data but involve requesting `UNUserNotificationCenter` authorization. Not a data-collection question.
- Support for Immich instances behind authentication other than API key — might involve OAuth flows. Still user→Immich, still no third-party involvement.
- Any kind of opt-in diagnostic upload — _would_ be a data-collection question. If we ever build one, it gates on explicit user consent + a spec in this file + the App Store label update.

## Cross-reference

User-facing privacy policy: [`../PRIVACY.md`](../PRIVACY.md).

If anything in this file contradicts the privacy policy, the privacy policy is authoritative for users; this file is authoritative for App Store Connect. The two should always agree.
