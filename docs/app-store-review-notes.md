# App Store review notes

The text we submit to Apple's review team alongside each build. Goes
in App Store Connect → App Information → App Review Information →
Notes.

The reviewer needs context to evaluate `cairn`: the app's primary
flow is destructive-looking (it moves photos to "Trash" on a remote
server). Without the context below, a reviewer may reasonably wonder
what the app actually does and whether the flow is safe.

cairn ships a **review mode** — a fixture-only state activated by
typing a specific URL in the onboarding screen. The reviewer doesn't
need to stand up an Immich instance, doesn't need to upload photos
from the device, doesn't need to authenticate against any backend.
They just type the URL + any non-empty API key and the app populates
itself with a representative state: realistic library counts, recent
runs, journal entries, pending review candidates. They can tap
through every screen and see how cairn presents the deletion-
propagation flow.

## Draft notes (paste into App Store Connect)

```
What cairn does
cairn syncs iPhone photo deletions to an Immich server
(immich.app). Delete a photo on iPhone, cairn moves the matching
server asset to Immich's Trash. Nothing is permanently deleted —
Immich retains trashed assets for 30 days and every action is
reversible from cairn's Runs tab or directly on the server.
cairn is not affiliated with Immich.

How to evaluate
cairn ships a fixture-driven review mode that doesn't require an
Immich server, network access, or photo uploads. To activate:

1. Install cairn from TestFlight (or the submitted build).
2. Open the app. Tap "Get started" on the welcome screen.
3. On the Server URL screen, enter:
     URL:     https://review.cairn.invalid
     API key: review
   The app verifies and lands on the Photos permission step.
4. Grant any Photos access option (or deny — review mode doesn't
   read photos, the prompt is for the post-onboarding state).
5. Skip Background App Refresh. Finish setup.

The Status tab will populate with sample library counts, a recent
run, and a journal of past actions. The big "ready to trash"
number on Status opens a dry-run sheet listing items eligible to
trash now (past the quarantine window). The "in quarantine" line
opens the Pending Review screen showing items still inside the
14-day quarantine window, where you can approve, exclude, or
dismiss them. The Runs tab shows historical runs with drill-down
detail. Settings shows the connection as "review.cairn.invalid"
to confirm review mode is active.

In review mode no network requests are made. Tapping "Sync"
re-seeds the fixture state on each round (so the trash / approve /
dismiss flows can be exercised repeatedly without rebuilding the
app); this is expected and not a defect.

To exit review mode: Settings → Advanced → Danger zone → Sign
out. Onboarding will restart for normal use.

FAQ
— "Permanently deleted?" No. Trash only. 30-day retention on
  Immich. Every cairn action is reversible from the Runs tab or
  directly from the Immich web UI.
— "Why Photos access?" In normal use cairn must see the full
  library to distinguish deletions from photos that were never
  on this device. Review mode bypasses this entirely.
— "Data collected?" None. No analytics, crash reporting, or
  third-party SDKs. In normal use traffic goes only to the user's
  Immich server. In review mode there is no traffic at all.
— "Works without Immich?" No, cairn is an Immich client. Review
  mode is the only path that works without an Immich server.

Contact: egrahamlarue@gmail.com
```

## Per-submission checklist

Before pasting this into App Store Connect:

- [ ] Confirm the app version and build number match what's being
      submitted.
- [ ] Update contact email if needed.
- [ ] Verify on a clean install that typing the magic URL produces
      a populated Status tab. (`make beta` then install the
      TestFlight build on a device with no prior cairn data.)
- [ ] **Optional:** record a 60-90s walkthrough if the review-mode
      flow ever grows complex enough to be ambiguous from the
      written notes. Today the flow is short enough (type URL,
      tap through tabs, sign out) that the notes carry all the
      information; a video adds capture-and-edit friction without
      adding clarity.

## How review mode works (technical)

Implementation lives in `iOS/App/AppDependencies.swift`:

- `reviewModeMagicURL` constant: `https://review.cairn.invalid`.
  The `.invalid` TLD is reserved by RFC 6761, so it can never
  resolve in production DNS — a normal user typing a real URL
  (immich.example.com, etc.) has no path to land here.
- `verifyServer` action checks the typed URL against the magic
  string before any network probe. On match, persists a flag in
  UserDefaults (`cairn.review.modeActive`) and seeds fixtures via
  `seedReviewMode(into:)`.
- `bootstrap()` reads the flag at launch and re-seeds fixtures so
  the reviewer can backgrounded/re-foreground the app without
  losing state.
- `signOut` clears the flag, returning the app to normal
  onboarding.

The fixture state is the same `CairnFixtures.medium` used by the
App Store screenshot pipeline — so what the reviewer sees matches
what's shown on the App Store listing.

## If review mode is rejected

Apple has historically accepted hidden demo modes when documented
in review notes; the magic-URL approach is a common pattern. If a
reviewer rejects on grounds of "hidden mode," fall back to
provisioning a sandbox Immich instance:

- Stand up a dedicated Immich server (small VPS or Tailscale-
  exposed home instance with throwaway credentials).
- Pre-populate with 10-20 royalty-free fixture photos.
- Provide URL + API key in the review notes (rotate per
  submission).
- Reviewer follows: install Immich app, log in, upload some of the
  same photos from the review device's Camera Roll, then exercise
  cairn against that state.

That fallback path is more friction for the reviewer but the
narrowest legal definition of "demo credentials" Apple supports.
