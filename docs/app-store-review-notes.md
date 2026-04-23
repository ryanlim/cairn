# App Store review notes

The text we submit to Apple's review team alongside each build. Goes in App Store Connect → App Information → App Review Information → Notes.

The reviewer needs context to evaluate `cairn`: the app is non-functional without an Immich server, and the primary flow is destructive-looking (it moves photos to "Trash" on a remote server). Without the context below, a reviewer may reasonably wonder what the app actually does and whether the flow is safe.

## Draft notes (paste into App Store Connect)

```
What cairn is
—————————————
cairn reconciles the reviewer's iPhone photo library against an Immich server (immich.app) — a self-hosted photo backup app that the reviewer must provide. When a photo is deleted on the iPhone, cairn moves the matching photo on the Immich server to that server's Trash folder.

cairn is not affiliated with the Immich project. It uses Immich's public HTTP API.

cairn never permanently deletes anything. It only calls Immich's "move to Trash" API (DELETE /api/assets {force: false}). Immich retains trashed assets for 30 days, and every action is reversible through cairn's restore flow or Immich's own UI.


How to evaluate
———————————————
cairn requires an Immich server and an API key. We've provided:

  Immich URL:        https://REPLACE-BEFORE-SUBMISSION
  Reviewer API key:  REPLACE-BEFORE-SUBMISSION

This is a dedicated review instance with a pre-seeded library of ~200 placeholder photos. The API key is scoped only to this reviewer instance and will be rotated after review.

Flow:

  1. Open cairn. Step through the Setup wizard.
     — Paste the URL and API key above when prompted.
     — Grant Full Photos access. cairn needs this to enumerate the library.
     — Background App Refresh is optional; you can skip it.
     — Accept the default safety thresholds.
     — Pick "Trusting" strictness (the default).
     — Tap "Finish setup."

  2. The app lands on the "Initial scan" screen. Tap "Start indexing."
     — cairn hashes the simulator's photo library. This takes 30–60 seconds.
     — Progress updates live.

  3. When indexing finishes, the app moves to the Status tab.
     — "On iPhone: N · Indexed: N · On server: N" should all match.
     — There will be 0 pending candidates on a fresh simulator, because nothing has been deleted yet.

  4. To exercise the destructive path: delete a few photos from the simulator's Photos app, then return to cairn and pull-to-refresh on the Status tab.
     — Candidates appear. Tap "Review & sync" to see the candidate list.
     — The sheet shows exactly what would move to Immich's Trash.
     — Nothing happens on the server until you tap "Move N to Trash" and confirm.
     — After confirming, the Runs tab shows the run and the affected assets.

  5. To test restore: tap the run in the Runs tab, select an asset, tap "Restore." It moves back out of Immich's Trash into the active library.


Things reviewers sometimes ask
——————————————————————————————
— "Is anything permanently deleted?" No. cairn calls Immich's "move to Trash" endpoint only. Assets remain recoverable in Immich's Trash for 30 days.

— "Why Full Photos access?" cairn must enumerate the entire library to distinguish a deletion ("checksum was here, isn't now") from an asset that was never there ("checksum never observed"). Limited access would cause cairn to flag every photo outside the user's selection as "deleted," which would be dangerous. A banner in the app explains this if Limited access is detected.

— "What data does cairn collect?" None. No analytics, no crash reporting, no third-party SDKs. Network traffic goes to the user's Immich server only. See the privacy label questionnaire.

— "Does this work without an Immich server?" No. cairn is an Immich client. The "Why" section of the App Store description makes this explicit.

— "Is the Immich trademark licensed?" The Immich name is referenced in nominative fair-use contexts ("for Immich," "compatible with Immich"). cairn does not use Immich's logo or brand assets. The App Store description includes a non-affiliation disclaimer.


Contact
———————
For review-related questions: [developer contact email]

We're happy to spin up a second reviewer instance, walk through the flow on a screen-share, or answer any specific concerns about the destructive-action path.
```

## Per-submission checklist

Before pasting this into App Store Connect:

- [ ] Replace `REPLACE-BEFORE-SUBMISSION` placeholders with the live reviewer URL + API key.
- [ ] Rotate the API key from the previous submission (don't reuse).
- [ ] Seed the reviewer Immich instance with a fresh library so past review runs don't appear in the Runs tab.
- [ ] Confirm the app version and build number match what's being submitted.
- [ ] Update contact email.

## If we don't want to stand up a reviewer instance

Alternative: flag that `cairn` needs a third-party service and that Apple's reviewer can use the [Immich demo server](https://demo.immich.app/) (assuming one is available and allows external API keys at review time). Historically Apple accepts "requires third-party service + provides demo credentials" with minimal friction as long as the demo works. If the Immich demo doesn't allow external API access, we have to provide our own reviewer instance — not worth skipping.
