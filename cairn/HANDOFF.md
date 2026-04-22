# cairn — design → engineering handoff

This repo is a **high-fidelity interactive prototype** of an iOS app called cairn. It
is not shippable code. It exists to pin down the UX, visual language, microcopy,
and safety-rail semantics of the app so that the iOS implementation can move
fast and make the right trade-offs.

Read this file first, then open `cairn.html` in a browser and click around with
the "Tweaks" panel (toggle it from the toolbar in the design tool, or wire it
up manually — see "Running locally" below).

---

## What cairn does

cairn reconciles an iPhone Photos library against a self-hosted
[Immich](https://immich.app) server. When a user deletes a photo on their
phone, that photo still exists on Immich. cairn finds those orphaned assets
and — with heavy, explicit safety rails — moves them to Immich's trash. Photo
contents never leave the user's devices; cairn only sends delete requests
signed with the user's API key.

The app's entire emotional pitch is **"I will never do something you didn't
ask me to do."** Every decision in this prototype comes back to that.

---

## Running locally

```sh
# Any static file server works. E.g.:
npx serve .
# or
python3 -m http.server 8000
```

Then open `http://localhost:8000/cairn.html`. Tweaks panel is not wired to
a UI toggle outside the design tool; while developing, append this to
`cairn.html`'s inline script to force it on:

```js
// inside the App component, replace: const [editMode, setEditMode] = React.useState(false);
// with:                              const [editMode, setEditMode] = React.useState(true);
```

That exposes the App state / Theme / Library size / Degraded / Frame / History
controls on the right side of the screen.

No build step. The prototype uses in-browser Babel for JSX — fine for design
iteration, **do not ship this pattern**. Production iOS app should be
SwiftUI.

---

## File structure

```
cairn.html                  # App root + state, mounts screens
cairn.css                   # Layer-2 semantic tokens (--ui-*) + all component styles
palette.css                 # Layer-1 palette fallbacks (runtime overrides these)
palette.js                  # Raw palette + color math (shade/tint/ink)
data.js                     # Fixtures: library sizes, sample runs, sample candidates, journal
icons.jsx                   # Inline SVG icon set (window.I)
parts.jsx                   # Shared primitives: AppHeader, TabBar, KeyValRow, ToggleRow, Stat, CairnMark
thumb.jsx                   # CSS-only deterministic thumbnails + AssetThumb + Live Photo badge
ios-frame.jsx               # iPhone device bezel (from starter)
toast.jsx                   # Global toast singleton (window.showToast)
screens/
  status.jsx                # Primary landing. State-aware: steady | dryrun | threshold | degraded
  runs.jsx                  # Full history list + empty state
  run-detail.jsx            # Per-run detail sheet: grid, filter, selection, action bar
  settings.jsx              # Settings + API key reveal + safety rails
  excluded.jsx              # Allowlist management (reachable from Settings)
  palette.jsx               # Palette editor (reachable from Settings → Appearance)
  setup.jsx                 # Onboarding: Server → Photos → Safety → First-run → Indexing
  dryrun.jsx                # Review-and-sync modal (the most important safety surface)
uploads/                    # Brand marks (cairn logo, in several formats)
```

---

## Architecture

### Two-layer color system

Editing a palette swatch needs to propagate through the whole app without
hand-editing every component. We solve this with two token layers:

- **Layer 1 — raw palette.** Hex values from `palette.js`, written at runtime
  into CSS vars `--c-<role>` (accents) and `--n-<role>` (neutrals) by
  `applyPaletteToCSS()`. Stable role names: `destructive`, `danger`,
  `pending`, `verified`, `accent-info`, etc. See `screens/palette.jsx`.
- **Layer 2 — semantic tokens.** Defined in `cairn.css` as `--ui-*`
  (`--ui-primary`, `--ui-info-ink`, `--ui-verified-soft`, etc). Every
  `--ui-*` token resolves to a `var(--c-*)` or `var(--n-*)`. Components
  **always** reference `--ui-*`, never the raw palette.

Consequence: when the user changes "danger" in the palette editor, every
component that uses `--ui-danger`, `--ui-danger-ink`, `--ui-danger-soft`
repaints live, including dark mode (which recomputes `*-soft` and `*-ink`
variants in the `.theme-dark` selector).

**For the iOS engineer:** mirror this in Swift — a `CairnPalette` struct with
role-keyed colors, and a `CairnSemanticTokens` enum that reads from it.
Never let a view reach for a raw color.

### State model

Top-level in `cairn.html`:

```js
const [tweaks, setTweaks] = useStoredTweaks();    // design-tool toggles
const [tab, setTab] = React.useState('status');   // status | runs | settings
const [dryRunOpen, setDryRunOpen] = React.useState(false);
const [openRun, setOpenRun] = React.useState(null);
const [settings, setSettings] = React.useState(SETTINGS_DEFAULTS);
const [excluded, setExcluded] = ...;              // Set<filename>
const [excludeMeta, setExcludeMeta] = ...;        // filename → {reason, addedAt, ...}
const [settingsRoute, setSettingsRoute] = ...;    // root | excluded | palette (Settings sub-routes)
```

`tweaks.appState` simulates the product's actual high-level state:

- `setup` — fresh install, onboarding active
- `dryrun` — first sync done; steady state but never auto-trashed
- `steady` — normal operation, history populated
- `threshold` — last run tripped a safety rail and was aborted

### Tweaks

All tweak overrides persist to `localStorage['cairn.tweaks']`. The host of
this prototype speaks a small message protocol:

- Page posts `{type: '__edit_mode_available'}` when ready.
- Host posts `{type: '__activate_edit_mode'}` to show the panel;
  `{type: '__deactivate_edit_mode'}` to hide.
- Page posts `{type: '__edit_mode_set_keys', edits: {...}}` to persist tweaks.

There's also an `EDITMODE-BEGIN/END` JSON block in `cairn.html` that the host
parses to know the initial defaults.

**For iOS:** delete all of this. The Tweaks panel is a prototyping scaffold, not
product UI.

---

## What's real vs. mocked

### Real (worth keeping)

- **The copy.** All microcopy is considered. The dry-run sheet header, the
  "Cancelable · reversible · transparent" footer, the empty-history
  explanation, the safety-rail abort banner, the "don't screenshot"
  warning on API key reveal — all load-bearing. Don't paraphrase.
- **The safety rail logic.** Percent cap (default 1.0%) AND count floor
  (default 5) must *both* trip to abort. See `DryRunSheet` → `tripped`.
  The banner explains this explicitly ("Your cap is X% and N+ assets").
- **The breadcrumb tag model.** Every trash run writes a tag
  `cairn/v1/run/<timestamp>` to all trashed assets, so a user can
  inspect or bulk-restore a specific run in Immich. The journal shows
  the exact API call order: `tag.create` → `tag.attach` → `delete.batch`.
  Follow this order.
- **Dry-run as a first-class mode.** Settings → "Dry-run by default" flips
  the sheet into a mode where confirming *logs* a preview run without
  touching the server. The ModeChip at the top of the sheet makes this
  unambiguous. Live mode shows "Live · will trash" in rust; dry-run mode
  shows "Dry-run mode" in info blue. These must stay visually distinct.
- **Live Photo pair handling.** Each Live Photo is a still + motion video
  pair on the server. Our fixtures mark one thumbnail per pair with the
  `kind: 'live-pair'` flag, and the action bar shows
  "N selected · +M paired videos = total" so the user knows the real
  server-side impact. Implement the pair expansion in the client, not by
  asking Immich to infer it.
- **Exclusion semantics.** Excluded filenames are protected from future
  runs system-wide, with metadata (when, which run, why). The excluded
  list is reachable from both Settings and as a "just-excluded" flash in
  the run detail. Restore and exclude are separate actions: restore
  un-trashes, exclude tells cairn to skip going forward. They can be
  combined ("Restore AND exclude" is a common flow after a too-eager
  run).
- **The two-confirm trash path.** Even outside dry-run mode, moving
  assets to trash requires "Move N to trash" → "Yes, trash N" (a
  second confirm on a rust-red banner). No single-tap deletions, ever.

### Mocked (replace with real implementations)

- **Thumbnails.** `thumb.jsx` renders a deterministic CSS-gradient "scene"
  per filename. Real app uses `PHAsset` fetch for on-device images and
  Immich's thumbnail endpoint for server-side. Keep the 76px square
  tile size in the dry-run grid; it's tuned for the iPhone SE width.
- **Hashing / diff.** `IndexingStep` fakes three phases with timeouts.
  Real implementation:
  - Phase 1: iterate `PHAsset.fetchAssets`, compute a stable content ID
    (Apple's `localIdentifier` plus `modificationDate`, or a perceptual
    hash if you want cross-device resilience — design doc should be
    consulted).
  - Phase 2: `GET /api/assets?limit=*` paginated, pull `checksum` field.
  - Phase 3: diff the two sets → candidate list.
- **API calls.** All journal entries are made-up. Real endpoints per
  Immich's OpenAPI spec (as of this writing):
  - `POST /api/tags` (create)
  - `PUT /api/tags/:id/assets` (attach)
  - `DELETE /api/assets` with `{ids: [...], force: false}` (trash)
  - `POST /api/assets/restore` (undo trash within 30 days)
- **Server verification.** Onboarding step 0 ("1,204 assets visible to
  this key") is hardcoded. Real: hit `/api/assets?limit=1` with the
  key, read the `count` header or paginate to count.
- **Restore.** Currently a toast. Real call per above, then update the
  run's local state to reflect the restored-count.
- **Open in Immich.** Toast only. Real: universal link to
  `https://<server>/tags/<tag-id>` or fall back to the trash view.
  Selection-aware deep link is in `run-detail.jsx`'s `handleOpenInImmich`.

---

## Screens in play

| Screen                       | File                  | When                                                        |
|------------------------------|-----------------------|-------------------------------------------------------------|
| Status (steady)              | `screens/status.jsx`  | Default landing, last-run summary + sync CTA                |
| Status (dry-run banner)      | `screens/status.jsx`  | `appState === 'dryrun'`: first-sync nudge                   |
| Status (threshold tripped)   | `screens/status.jsx`  | `appState === 'threshold'`: rust callout, review CTA        |
| Status (degraded)            | `screens/status.jsx`  | Server / auth / photos-limited / tiny-library variants      |
| Runs list                    | `screens/runs.jsx`    | Full history grouped by day                                 |
| Runs empty                   | `screens/runs.jsx`    | Zero-run state, with explainer card                         |
| Run detail                   | `screens/run-detail.jsx` | Sheet over Runs: grid, filter, selection, action bar    |
| Dry-run / Sync sheet         | `screens/dryrun.jsx`  | Modal sheet for the core review-and-commit flow             |
| Setup (0–4)                  | `screens/setup.jsx`   | First launch only                                           |
| Settings                     | `screens/settings.jsx`| Root                                                        |
| Settings → Excluded          | `screens/excluded.jsx`| Sub-route                                                   |
| Settings → Palette           | `screens/palette.jsx` | Sub-route (second-class: themeing is not primary UX)        |

Each screen has a `[data-screen-label]` on its root in the prototype to make
navigation comments easier during review. You don't need this in production.

---

## Visual language

- **Stone neutrals** (warm gray, not cool) on light mode; near-black + warm
  charcoal on dark mode. Defined as `--n-paper-…` through `--n-graphite-…`.
- **Accent roles:** `destructive` (flag red — the hero mark),
  `danger` (strawberry red — actionable warnings), `pending` (amber),
  `verified` (moss green), `accent-info` (slate blue). Never mix these
  semantically: a passed safety check is `verified`; a tripped one is `danger`;
  an informational nudge is `accent-info`.
- **Typography:** Inter Tight for UI, JetBrains Mono for anything that's a
  hash, filename, checksum, or API string. Hashes are always mono so the
  user can eyeball them.
- **Tabular numerals** on every count (`.tabular` class). Critical for the
  "N trashed" / "N candidates" rhythm in the run detail and stat rows.
- **Callouts** (`.callout`, `.callout-rust`, `.callout-moss`, `.callout-amber`)
  are the primary inline-message pattern. Use soft fill + left-border accent.
- **No emoji.** The brand mark is a 3-stone cairn, drawn in SVG
  (`CairnMark` in `parts.jsx`).

---

## Things you'll probably ask

**Why no real iOS frame code?** Prototype is HTML to keep iteration fast and
reviewable by anyone with a browser. The `ios-frame.jsx` component just
draws a bezel so screens feel real during review.

**Why two config stores (settings vs. tweaks)?** `settings` is product state
(what the user configured inside the app). `tweaks` is design-tool state
(which mock app-state are we viewing). Only `settings` migrates to
production; `tweaks` is prototype-only scaffolding.

**Where's the server URL validation?** Mocked. Real implementation should at
minimum (a) prefix with `https://` if missing, (b) strip trailing slash,
(c) probe `/api/server-info` and fail on anything that doesn't return
Immich's expected shape.

**Why is the palette editor in Settings and not a tab?** Earlier iterations
had it as a primary tab. It got demoted because theming is a power-user
feature, not a daily-use one. Settings → Appearance → Palette keeps it
discoverable without taking primary-nav real estate.

**Do I need to implement every `--ui-*` token?** No. Grep for the token in
the codebase — if it's referenced from a file you're porting, port it; if
it's referenced only by the palette editor itself (i.e. an example-only
token), skip it.

---

## Open questions for the eng/PM team

These are flagged in the prototype but not resolved:

1. **Background runs.** The prototype has no background-refresh UX. Should
   cairn silently run on a schedule and badge the app icon if something
   needs review, or stay strictly foreground-only? The current journal
   structure assumes the user is watching.
2. **Recovery window.** We say "30 days" everywhere. That's Immich's
   default but server-configurable. Should we query the server for its
   actual retention and parameterize the copy?
3. **Undo after restore.** We have a "just-restored" flash in run detail.
   Do we also want a cross-run "Undo last restore" path? Currently no.
4. **Batching.** We assume all trashes go in one `delete.batch`. For
   large runs (hundreds of assets), should we chunk and show progress?
5. **Checksum drift.** If a photo is edited on-device after being
   indexed, does it still match the server's checksum? We silently
   assume yes. Real answer depends on the hash function choice.

---

## Keep these copies verbatim

(Changing these changes the product's voice. If you need to edit, ping the
designer.)

- "cancelable · reversible · transparent"
- "Nothing was touched. Review the photos before deciding."
- "Recoverable in Immich trash for 30 days."
- "I will never do something you didn't ask me to do." *(internal pitch)*
- "Don't screenshot." *(API key reveal)*
- "Every scheduled run is preview-only. You confirm each trash manually."
- "Photos never leave your iPhone or your Immich server."

---

_Last updated alongside the prototype. If this file contradicts the live
design, trust the design._
