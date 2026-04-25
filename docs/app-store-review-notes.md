# App Store review notes

The text we submit to Apple's review team alongside each build. Goes in App Store Connect → App Information → App Review Information → Notes.

The reviewer needs context to evaluate `cairn`: the app is non-functional without an Immich server, and the primary flow is destructive-looking (it moves photos to "Trash" on a remote server). Without the context below, a reviewer may reasonably wonder what the app actually does and whether the flow is safe.

## Draft notes (paste into App Store Connect)

```
What cairn does
cairn syncs iPhone photo deletions to an Immich server (immich.app). Delete a photo on iPhone, cairn moves the matching server asset to Immich's Trash. Nothing is permanently deleted — Immich retains trashed assets for 30 days and every action is reversible. cairn is not affiliated with Immich.

How to evaluate
Server URL:  https://REPLACE-BEFORE-SUBMISSION
API key:     REPLACE-BEFORE-SUBMISSION

This is a dedicated review instance. cairn matches photos by SHA1 checksum, so the same file bytes must exist on both the phone and the server.

Setup:
1. Install the Immich app (free, App Store) on the review device.
2. Open Immich, log in to the server above (email: admin@cairn-review.local, password provided separately).
3. Upload 5-10 photos from the Camera Roll to the server via the Immich app.

Flow:
1. Open cairn. Complete the Setup wizard — paste the URL and API key above, grant Full Photos access, accept defaults, tap "Finish setup."
2. Tap "Start indexing" on the Initial Scan screen. Takes a few seconds.
3. Status tab shows matched counts. 0 candidates because nothing is deleted yet.
4. In the Photos app, delete 2-3 of the photos you uploaded. Return to cairn, pull to refresh.
5. Candidates appear. Tap "Review & sync" to see the list. Nothing touches the server until you confirm.
6. After confirming, the Runs tab shows the run. Tap a run, select an asset, tap "Restore" to reverse it.

A screen recording of this flow is attached.

FAQ
— "Permanently deleted?" No. Trash only. 30-day retention on Immich.
— "Why Full Photos access?" cairn must see the full library to distinguish deletions from photos that were never on this device. Limited access would flag unselected photos as deleted.
— "Data collected?" None. No analytics, crash reporting, or third-party SDKs. Traffic goes only to the user's Immich server.
— "Works without Immich?" No. cairn is an Immich client.

Contact: egrahamlarue@gmail.com
```

## Per-submission checklist

Before pasting this into App Store Connect:

- [ ] Replace `REPLACE-BEFORE-SUBMISSION` placeholders with the live reviewer URL + API key.
- [ ] Rotate the API key from the previous submission (don't reuse).
- [ ] Clear any leftover data on the reviewer Immich instance so past review runs don't appear.
- [ ] Confirm the app version and build number match what's being submitted.
- [ ] Update contact email.
- [ ] Record a screen recording showing the full end-to-end flow (setup → index → delete photos → sync → review candidates → confirm trash → restore). Attach as App Review Attachment in App Store Connect.

## If we don't want to stand up a reviewer instance

Alternative: flag that `cairn` needs a third-party service and that Apple's reviewer can use the [Immich demo server](https://demo.immich.app/) (assuming one is available and allows external API keys at review time). Historically Apple accepts "requires third-party service + provides demo credentials" with minimal friction as long as the demo works. If the Immich demo doesn't allow external API access, we have to provide our own reviewer instance — not worth skipping.
