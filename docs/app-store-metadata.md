# App Store metadata

Source of truth for the text fields in App Store Connect. Paste from here; keep this file updated when the copy changes. Character limits below reflect App Store Connect's constraints as of 2026-04.

## App name

_30 characters max. Appears under the icon on the home screen and at the top of the App Store listing._

```
cairn — Immich sync
```

(Working title disambiguates from other "cairn" projects already on the App Store. 19 chars, well under the limit.)

## Subtitle

_30 characters max. One line under the app name on the App Store listing. Clarifies what the app does in a phrase._

```
Sync photo deletions to Immich
```

(30 chars — at the limit. Action-verb-first framing matches the description's opening sentence. Alts: `Photo deletion sync for Immich` (30), `Deletion sync for Immich` (24, less specific).)

## Promotional text

_170 characters max. Shown above the description, editable without a new app version submission._

```
When you delete a photo on your iPhone, cairn moves the matching photo on your Immich server to Trash. Every run is a preview — nothing moves until you confirm.
```

## Description

_4000 characters max. Aim for readable, not maximum-density._

```
cairn reconciles your iPhone photo library against your own Immich server. When you delete a photo on your phone, cairn moves the matching photo on Immich to Trash.

That's the whole job. cairn doesn't upload photos, show albums, edit metadata, or run AI — the Immich app already does those things. cairn closes the one loop the Immich app doesn't: photos that live on the server after you've deleted them from your phone.

HOW IT WORKS
— Content identity is SHA1 (the same identifier Immich uses server-side).
— cairn subscribes to iOS's deletion log, so it sees soft-deletes as you make them.
— A configurable quarantine window holds confirmed deletions before anything moves, so an accidental mass-offload has time to be caught.
— Every run shows you the candidate list first. Nothing happens on the server until you confirm.

SAFETY MODEL
— Trash, not delete. cairn moves assets into your Immich Trash — Immich retains them for 30 days, and restore is one tap.
— Percent cap + floor. If a single run would move more than a threshold of your matched photos to Trash, it aborts without touching the server.
— Breadcrumbs. Every run is tagged on Immich (cairn/v1/run/<id>) so you can find it server-side.
— Forensic journal. Local append-only log records every step — planned, tagged, trashed, restored, failed.
— Exclusions. Protect specific photos from ever being flagged.

PRIVACY
— No analytics, no telemetry, no crash reporting, no ads.
— No cairn backend. Your iPhone talks directly to your Immich server using your API key.
— Credentials stay in the iOS Keychain. Nothing leaves your device besides requests you configured.

REQUIREMENTS
— An Immich server you run or control.
— An Immich API key. cairn requests these scopes: asset.read, asset.view, asset.download, asset.delete, tag.create, tag.asset, tag.read. The Setup screen lists them when you paste your key.

cairn is not affiliated with the Immich project. It talks to Immich over its public API; compatibility only.

Source is MIT-licensed at github.com/glarue/cairn.
```

## Keywords

_100 characters max, comma-separated. No spaces after commas (Apple counts them against your budget)._

```
immich,photos,sync,reconcile,delete,cleanup,self-hosted,trash,backup,homelab,selfhosted,storage
```

(If over: drop `homelab`, `selfhosted` — duplicates of `self-hosted`.)

## What's new (release notes)

_4000 characters max. Update per-release._

For 0.1.0:

```
Initial release.

cairn reconciles your iPhone photo library against your Immich server — when you delete a photo on your phone, cairn moves the matching photo on Immich to Trash. Every run previews the candidates first; nothing moves on the server until you confirm.
```

## Support URL

_Required. Where users go when they need help._

```
https://github.com/glarue/cairn/issues
```

## Marketing URL

_Optional. Landing page or project page. For now, same as support._

```
https://github.com/glarue/cairn
```

## Privacy policy URL

_Required. Must resolve to the privacy policy — not the raw repo file, ideally a rendered page._

```
https://glarue.github.io/cairn/PRIVACY
```

## Category

- **Primary:** Photo & Video
- **Secondary:** Utilities

## Age rating

Likely 4+ across the board — `cairn` doesn't render user content beyond thumbnails of the user's own library, which is exactly what every photo-management app on the platform does. Fill out the App Store Connect questionnaire conservatively:

- Cartoon violence: none
- Realistic violence: none
- Sexual content: none
- Profanity: none
- Alcohol/drugs: none
- Mature themes: none
- Simulated gambling: none
- Horror/fear: none
- Unrestricted web access: no
- User-generated content: no — users only see their own photos via their own Immich server.

## Rights / content ownership

`cairn` does not contain third-party content the user has rights to. Source code is MIT-licensed (the developer's own work). Declare "no" for third-party trademarks / copyrighted material.

## Notes

- The name "Immich" appears throughout the description; this is allowed (nominative fair use) but avoid implying affiliation. The description's "`cairn` is not affiliated with the Immich project" line is deliberate — don't drop it.
- Keep the Stripe-docs-meets-Strunk-and-White voice: direct, specific, no marketing adjectives, no empowerment-speak. See [`feedback_copy_voice`](../.claude/ — not in repo) for the full internal style guide.
