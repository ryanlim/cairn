# Demand evidence for cairn

A curated, direction-verified list of places where Immich users have explicitly discussed the gap cairn closes — phone-deletion not propagating to the Immich server. Every entry below was read end-to-end to confirm the *direction* matches cairn's premise (iPhone Photos.app delete → Immich server trash), not a similar-sounding but unrelated request.

Captured 2026-04-28. Update as new threads appear or as Immich's roadmap changes.

## How to use this list

- **For citing demand** (e.g., README, blog post, the App Store Connect "App Review notes" justifying why cairn exists): lead with **Discussion #4341** — it's the canonical, most-upvoted, longest-running thread asking for exactly cairn's behavior.
- **For posting beta links**: comment on **Discussion #4341** itself (highest concentration of motivated readers), then targeted replies on other threads where individual commenters describe matching workflows. Be cautious about adjacent / inverse threads — the audience there is asking for a different thing, and a beta link will read as off-topic.
- **Don't cite** the Inverse section. Those threads ask for the opposite of what cairn does and would weaken the demand argument.

## Direct matches — primary citations

These threads ask for exactly what cairn does: a user's iPhone Photos.app deletion propagating to the Immich server.

### [Discussion #4341 — "[Feature] Two-way Sync"](https://github.com/immich-app/immich/discussions/4341)

- **Status:** OPEN, 125 upvotes, opened 2023-10-04
- **OP quote:** *"assets deleted in Photos are deleted from Immich. Assets deleted from Immich are deleted in Photos."*
- **Why it's strong:** explicit, bidirectional ask; long discussion thread with comments specifically about phone→server direction; no Immich-team commitment to ship; 2.5 years old and still active.
- **Action:** primary citation; primary place to post the cairn beta link.

## Adjacent demand — supporting evidence, secondary citations

Same audience, related pain, different surface.

### [Discussion #4282 — "[Feature] Avoid resyncing if deleted manually"](https://github.com/immich-app/immich/discussions/4282)

- **Status:** OPEN, 86 upvotes, opened 2023-09-29
- **Direction:** related but inverse — user deletes via Immich web UI, mobile app then re-uploads. Different mechanism, but the underlying broken assumption (Immich isn't tracking user intent across phone↔server) is the same one cairn names.
- **Action:** reference as adjacent demand; do not post beta link there (different solution surface).

### [Discussion #3594 — "[Feature] Delete from web and sync to mobile"](https://github.com/immich-app/immich/discussions/3594)

- **Status:** OPEN, 193 upvotes, opened 2023-08-08
- **Direction:** OPPOSITE of cairn — wants web/server delete to propagate down to mobile.
- **Why list it:** highest-upvoted "delete sync" feature anywhere in the repo. Same audience as cairn's. Useful for arguing the broader sync gap is huge, but cairn doesn't solve this direction so don't post the beta link there.

### [Discussion #14441 — "Having both 'Delete' and 'Move to Trash' is confusing"](https://github.com/immich-app/immich/discussions/14441)

- **Status:** OPEN, 25 upvotes, Android-specific
- **Direction:** UX friction with delete semantics in the Immich app itself.
- **Action:** light reference; shows ongoing delete-flow confusion.

## Inverse — DO NOT cite

These threads ask for the *opposite* of what cairn does, or are about Immich's own UI deleting things. Listing them here so future-me doesn't accidentally cite them.

| URL | What it actually asks |
|---|---|
| [#2379 Delete Images from Mobile Device and keep on Server](https://github.com/immich-app/immich/discussions/2379) | User wants Immich's app to remove device copies while keeping server copies. Opposite. |
| [#11047 How to use Immich to delete original files on device?](https://github.com/immich-app/immich/discussions/11047) | About Immich web UI deleting external-library files. |
| [#12576 Auto-Delete After Upload](https://github.com/immich-app/immich/discussions/12576) | Wants Immich app to auto-delete local copy after backup. |
| [#7621 Cleanup old Photos that have been synced](https://github.com/immich-app/immich/discussions/7621) | Same as above, different framing. |
| [#3546 Free up space button](https://github.com/immich-app/immich/discussions/3546) | Now-shipped Immich feature for the same direction. |
| [Issue #165 Mass remove already backed-up photos](https://github.com/immich-app/immich/issues/165) | Same direction. |
| [#19015 Deleting on phone deletes from server – how to prevent](https://github.com/immich-app/immich/discussions/19015) | Android user OBSERVING something like cairn's behavior and wanting to disable it. Useful only as a footnote that the audience is split. |
| [#22507 Don't re-upload after Web UI delete](https://github.com/immich-app/immich/discussions/22507) | Adjacent re-upload mechanic, not deletion propagation. |
| [#18509 synchronisation bidirectionnelle](https://github.com/immich-app/immich/discussions/18509) | Pivots to file-sync-via-Syncthing. |

## Reddit / forums / external

I couldn't surface specific high-signal Reddit threads — searches kept routing to the GitHub discussions above. Two AnswerOverflow threads ([1322848990328389662](https://www.answeroverflow.com/m/1322848990328389662), [1470864979929469140](https://www.answeroverflow.com/m/1470864979929469140)) appeared in title metadata as relevant to "iPhone delete + Immich" but their pages 403 to programmatic fetch. Worth a manual check before posting beta links.

Plausible posting targets (verify rules / self-promo policies before posting):

- **r/immich** — small but exact-fit subreddit
- **r/selfhosted** — large; "I made this" flair when the rules call for it
- **r/HomeServer**, **r/DataHoarder** — adjacent audiences
- **Lobste.rs** — Lobsters has a [self-hosting-Immich post](https://lobste.rs/s/cljhyb/self_hosting_my_photos_with_immich); a "Show Lobsters" submission for cairn would fit the venue.
- **Hacker News** — Show HN once cairn has a stable v1.0; the iCloud-vs-Immich angle reads well as a HN narrative.
- **The Immich Discord** — high-signal but ephemeral; Immich maintainers are present so be transparent about cairn's third-party / unaffiliated status.

## Recommended sequence

1. Cite **#4341** in cairn's README as the headline demand signal ("125 upvotes since 2023; no Immich-team commitment to ship").
2. Once a TestFlight build is up, post a beta-invite comment on **#4341** linking to a public TestFlight URL.
3. Cross-post a short "I built this to scratch my own itch" Reddit thread to r/immich and r/selfhosted with the same TestFlight link.
4. Defer Lobsters / HN until v1.0 to maximize signal-to-noise.
