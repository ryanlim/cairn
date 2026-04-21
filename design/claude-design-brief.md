# cairn — Design Brief

Paste this into Claude Design as the source-of-truth for what cairn should surface, how flows should feel, and what *not* to do.

## What cairn is

An iOS companion app for [Immich](https://immich.app). When a photo is deleted from the iPhone's Photos library, cairn moves the corresponding server-side asset on Immich to trash. That's the whole job.

cairn is **not** official, not affiliated with Immich, and intentionally narrow. It does not upload, does not browse photos as a feature, does not manage albums.

## Audience

Technically-inclined self-hosters. They run their own Immich server. They know what an API key is. They care more about their photo library's integrity than about polish.

## Core values (rank-ordered)

1. **Safety.** A bug that deletes the wrong photo is catastrophic. A bug that delays a sync is merely annoying. Default to conservative.
2. **Reversibility.** Every destructive action is undoable in two taps. Immich's 30-day trash + cairn's per-run tags make this real.
3. **Transparency.** Always show what cairn is *about* to do and what it *did*. Never silently mutate.
4. **Conservative defaults.** If in doubt, don't delete.

## Tone and visual direction

- Sysadmin-tool calm, not consumer-app loud.
- Receipts, not confetti. Do not animate celebrations after deletions.
- Red: reserved for genuinely dangerous states (safety-rail abort, auth broken). Yellow: attention-needed. Neutral: everything else.
- Information-dense is good where it earns its keep (Run detail, Preview). Don't pad for whitespace if it costs clarity.
- Monospace fine for run IDs, tag values, checksums. Not for body copy.

## Vocabulary (use consistently in UI copy)

- **Run** — a single execution of the sync pipeline.
- **Candidate** — a server asset flagged for trashing by the diff.
- **Dry-run** — a preview that makes no server changes.
- **Threshold** — the tolerance above which cairn refuses to proceed. Expressed as a percent + a minimum absolute count ("abort if more than 1% *and* more than 5 photos would be trashed").
- **Purview** — the subset of server assets cairn might touch (those whose checksums this device has seen).
- **Breadcrumb tag** — the per-run tag on Immich (`cairn/v1/run/<id>`) that makes a run findable for undo.
- **Move to trash** / **Trash** — never "delete," "purge," "destroy," or "reap." Users need to trust this app; violent verbs erode that.

## Thumbnails are a safety feature, not a nice-to-have

Wherever cairn shows a set of assets — in the Sync preview, in the threshold-trip review, in every Run detail view — **it must show a thumbnail for each asset** alongside the filename. The user needs to see *which photos* are on the chopping block, not just a list of UUIDs.

- **Source:** Immich's thumbnail endpoint, not the local Photos library (the photo may already be deleted locally — that's why cairn is about to trash it on the server).
- **Layout:** Grid preferred in preview and review contexts, so users can scan dozens of thumbnails quickly. List with larger thumbnail + metadata in Run detail.
- **Live Photos:** show the still thumbnail; badge it as a Live Photo so users understand that both halves (still + motion video) will be trashed together. Never show a motion video as a separate tile.
- **Performance:** lazy-load on scroll. A run can have hundreds of assets. Never block the UI fetching them all.
- **Fallback:** if a thumbnail can't load, show a placeholder with the filename. Don't hide the asset.

Thumbnails are the single most important safety affordance cairn can offer. If the preview shows IMG_2024 candidates and the user recognizes "that's my kid's birthday photos, not the screenshots I meant to clean up" — cairn has done its job.

## The six screens

### 1. Home
What the user sees 95% of the time.

- **Last run line:** timestamp, one-sentence status ("3 photos trashed," "nothing to do," "aborted — review needed"). Color-coded: neutral / attention / danger.
- **Pending candidates count** if a background run surfaced work.
- **Large "Sync Now" button.** This is the primary CTA.
- **Server status indicator:** reachable, auth OK.
- Tab-bar links to History and Settings.

### 2. Sync Now flow
A modal sequence, not a separate screen. Stages:

- **Reconciling…** Progress indicator. Can take seconds on large libraries.
- **Preview.** "N candidates across M in-purview assets." **Thumbnail grid of every candidate**, scrollable. Threshold status banner (safe / at-threshold / over-threshold). Two buttons: Cancel, "Trash N photos."
- **Confirm.** Final sheet. "This will move N photos to Immich trash. They stay recoverable there for 30 days." Go back / Trash.
- **Running.** Progress indicator, cancellable.
- **Done.** "N trashed. Tagged `cairn/v1/run/<id>` for undo." Button: "See this run" → Run detail.

Any stage can surface a **safety-rail abort** — plain-English explanation, candidate list (with thumbnails), and options to raise the threshold, abort, or proceed anyway (with a second confirmation).

### 3. Threshold-trip / review screen
When a safety rail stops a run. Supportive, not scolding.

- Plain-English reason: "68% of tracked photos would be trashed — above the 1% limit."
- **Full candidate list with thumbnails.** The user needs to *see* what would have been deleted to decide.
- Actions: Cancel, Raise threshold and retry, Proceed anyway (with second-confirm).

### 4. History
Reverse-chronological list of runs. Each entry: timestamp, candidate count, status pill (trashed / restored / aborted / dry-run / failed), breadcrumb tag value in a secondary row. Tap → Run detail.

### 5. Run detail
The heart of the undo flow.

- **Header:** run metadata (timestamp, trigger, threshold at run time, breadcrumb tag).
- **Asset grid:** **every asset in the run as a thumbnail + filename**, with its current state (trashed, restored, or no-longer-touchable). Live Photos shown as a single pair-badged tile.
- **Selection controls:** tap thumbnails to select, "Select all," filename-filter text input (e.g., "IMG_2024"). Selection count updates live.
- **"Restore selected" button** with live count of what it'll do after Live Photo auto-expansion.

### 6. Settings
Server URL, API key (masked by default, "reveal" to show), threshold settings (percent + minimum count floor), global dry-run toggle, log verbosity, link to view the deletion journal file, disconnect/reset.

## Onboarding (first run)

Linear wizard:

1. Welcome — one sentence about what cairn does.
2. Paste server URL + API key. Verify button tests connectivity and shows "X assets on your server."
3. Request Photos permission (must be **Full** — explain why Limited won't work).
4. Request Background App Refresh permission (optional but recommended).
5. Configure safety threshold with sensible defaults + tooltips.
6. "Let's do your first dry-run." Reconciliation runs, seeds the ever-seen set, shows "Nothing to delete yet — we've learned your library (N photos tracked)." Button → Home.

## Typical steady-state flow

- Open app → Home.
- If a background task surfaced pending candidates or an abort, Home shows it prominently.
- Tap Sync Now → Reconciling → Preview → Confirm → Running → Done → Home.
- Occasionally: History → Run detail → select specific assets → Restore.

## States to design (don't skip)

- First-ever open (empty ever-seen set).
- Server unreachable.
- API key invalid/revoked.
- Photos permission revoked or downgraded to Limited — cairn cannot function safely in Limited; surface this prominently.
- Safety rail abort — each of the four reasons deserves its own copy.
- Run-in-progress from background task when app opens.
- Empty History.
- Network drop mid-run.
- Healthy "nothing to do" state.

## Navigation

- Bottom tab bar: Home, History, Settings.
- Modal presentations: Sync Now flow, Restore confirm, onboarding wizard.
- Every modal is cancellable. Every destructive action confirms.

## What NOT to do

- Don't hide the threshold config in Settings only — expose it in the Sync preview too, so users can adjust without context-switching.
- Don't use emoji in chrome. User filenames may contain them; that's their choice.
- Don't show the API key even masked without user tapping reveal.
- Don't combine dry-run mode and live mode in an ambiguous UI. Be explicit about which you're in.
- Don't celebrate deletions.
- Don't show per-photo thumbnails on Home — lazy-load only in Preview, Review, and Run detail contexts.
- Don't surface ever-seen set internals to the user. They should never need to know the term.
