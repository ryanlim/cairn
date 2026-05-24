# cairn iOS — accessibility audit

Date: 2026-05-23
Scope: `Sources/CairnIOSCore/UI/*` and `iOS/App/*`
Audit standard: WCAG 2.1 AA + Apple HIG (44pt tap targets, Dynamic Type, VoiceOver, Reduce Motion).

Findings are tagged by severity (high / medium / low) and category. Severity reflects user impact, not implementation difficulty.

---

## Summary tally

| Severity | Count |
|---|---|
| High   | 11 |
| Medium | 14 |
| Low    |  7 |

---

## High severity

### H1 — Dynamic Type is effectively disabled across the entire UI
- **Category:** DynamicType
- **Sites:** ~373 occurrences of `.font(.system(size:...))` across UI files. Every screen text — body copy, headings, list rows, callouts — uses pinned point sizes. Spot examples:
  - `CairnPrimitives.swift:456` — `AppHeader` title at fixed 28pt
  - `CairnPrimitives.swift:461` — `AppHeader` subtitle at fixed 13pt
  - `CairnPrimitives.swift:602` — `KeyValRow` label at fixed 15pt
  - `CairnPrimitives.swift:606` — `KeyValRow` value at fixed 13/15pt
  - `CairnPrimitives.swift:643, 647` — `ToggleRow` label/sub at fixed 15/12pt
  - `CairnPrimitives.swift:698, 703` — `Stat` value at fixed 24pt, sub at 12pt
  - `CairnPrimitives.swift:745, 1401` — Callout body 13pt, `CairnTabBar` label 11pt
  - `StatusScreen.swift:976` — "READY TO TRASH" hero number at fixed 44pt
  - `SetupScreen.swift:267, 1045, 1055` — wizard headlines/blurbs at fixed 22/26/14pt
  - `RunsScreen.swift:184, 189` — empty-state headline 18pt, explainer 13pt
  - `SettingsScreen.swift:609, 700, 718` — section bodies at 15/13pt
  - and so on for every screen
- **Observation:** SwiftUI's `Font.system(size:)` does not participate in Dynamic Type by default. To scale, fonts must use `.font(.body)`, `.font(.title)`, or `Font.system(size:relativeTo:)`. None of the UI does either.
- **Why it matters:** users running larger Dynamic Type sizes (the Larger Accessibility Sizes available in Settings → Display & Brightness → Text Size, or in Accessibility → Display & Text Size) will see the cairn UI render at the same pixel size as default. For users with low vision who depend on AX5 (the largest accessibility size), the entire app is unreadably small. This is the single most impactful finding in the audit.

### H2 — Most muted/hint text fails WCAG AA contrast in light mode
- **Category:** Contrast
- **Sites:** Every `foregroundStyle(t.textHint)` and most `foregroundStyle(t.textMuted)` in light mode:
  - `t.textHint (#a8a194)` on `t.bg (#f2eee7)` = **2.22:1** (needs 4.5:1) — used at `CairnPrimitives.swift:611, 828, 1289, 1765, 1770; SettingsScreen.swift:424, 460, 615, 723, 749, 881; RunsScreen.swift:232, 316, 320, 323, 338`
  - `t.textHint (#a8a194)` on `t.surface (#faf8f4)` = **2.42:1**
  - `t.textMuted (#76716a)` on `t.bg (#f2eee7)` = **4.18:1** (just below 4.5:1) — pervasive: `t.textMuted` is the default secondary-text color, used in nearly every screen for sub-rows, descriptions, "last checked" timestamps, etc.
  - `t.quiet (#72889c)` on `t.bg (#f2eee7)` = **3.18:1** — used at `StatusScreen.swift:991` for "Last checked"
- **Why it matters:** users with contrast sensitivity (mild visual impairment, glare in outdoor light, older displays) cannot read subdued labels. `textHint` is used for filenames in journal rows, asset counts, breadcrumb suffixes — meaningful content. textMuted is the secondary copy across the app. Failure here means the bulk of secondary content is below AA in light mode.

### H3 — Multiple in-soft-callout text/background pairs fail WCAG AA
- **Category:** Contrast
- **Sites:**
  - `t.verifiedInk (#2f7761)` on `t.verifiedSoft (#dfede4)` = **4.42:1** (just below 4.5:1) — used in every "ok" Callout (`Callout(.verified, ...)` instances at `StatusScreen.swift:905; SetupScreen.swift:561, 566, 682; PendingReviewScreen.swift:516`)
  - `t.pendingInk (#95772f)` on `t.pendingSoft (#f9efd6)` = **3.70:1** — every "warn"-tone Callout (StatusScreen pending-trash banner, mass-offload, recycled-exclusions, etc.)
  - `t.dangerInk on t.dangerSoft (dark mode)` = **3.92:1** — every danger callout in dark mode (`DryRunSheet.swift:194; PendingReviewScreen.swift:497; StatusScreen.swift:594, 635, 638`)
  - `t.infoInk on t.infoSoft (dark mode)` = **3.83:1**
  - `t.primaryInk on t.primary (dark mode)` = **4.36:1** — the destructive red CTA in dark mode ("Move N to Trash"), `DryRunSheet.swift:331; CairnAppRoot.swift; SetupScreen.swift:1117`
- **Why it matters:** these are *callouts* — banners that communicate state changes (success, warning, error). The "verified-green" success state is the most-used positive feedback; the "pending-amber" warn state is the second-most-used. Users with mild low vision can't reliably parse Callout content despite it being meant to be a hero-visible message.

### H4 — Many icon-only buttons under 44pt tap-target minimum
- **Category:** TapTarget
- **Sites:**
  - `DryRunSheet.swift:161-167` — sheet Close button (`Image "xmark"` at 14pt, no explicit frame or padding, ~22pt actual tap area)
  - `RunDetailSheet.swift:284-290` — Close button (same shape, ~22pt)
  - `RunDetailSheet.swift:482-488` — Clear-filter "xmark" at 10pt, no frame (~12pt)
  - `CairnPrimitives.swift:823-832` — HelpPopover `questionmark.circle` at 13pt + 6pt padding each side = ~25pt actual tap area
  - `PendingReviewScreen.swift:1415-1448` — `RowIconButton.frame(width: 32, height: 28)` — three of these (trash/dismiss/exclude) per row. Both dimensions below 44pt.
  - `PendingTrashesSheet.swift:152-158` — Discard "trash" button frame(width: 32, height: 32) — both below 44pt
  - `SettingsScreen.swift:1766-1781` — `ApiKeyRow` Reveal/Hide and Copy buttons at 12pt + 2pt padding all sides = ~16pt tap area. Critical control on the most-sensitive surface in the app.
  - `StatusScreen.swift:1184-1187` — chevron up/down at 12pt with `frame(width: 32, height: 28)` — below 44pt and lacks `accessibilityLabel`
  - `StatusScreen.swift:1278-1294` — "Hash now" capsule button at 12pt + 10/5pt padding = ~24pt vertical
- **Why it matters:** Apple HIG specifies 44×44pt minimum hit area for any tap target. Users with motor impairment, large fingers, or unsteady hands repeatedly mis-tap on these. The Pending Review row trash button is the most-tapped destructive control in the app; mis-tap risk is real.

### H5 — Toggle controls in `ToggleRow` lack accessibility labels
- **Category:** VoiceOver
- **Sites:**
  - `CairnPrimitives.swift:653` — `Toggle("", isOn: $value).labelsHidden()` in the shared `ToggleRow` primitive. The label text lives in a sibling `Text` view; SwiftUI does not associate the two for VoiceOver, so the toggle itself reads as just "switch, on" or "switch, off" with no context.
  - `InitialScanScreen.swift:823` — `Toggle("", isOn: isEnabled).labelsHidden()` for the "Never-touch ceiling" toggle. Same problem.
  - `SettingsScreen.swift:1455` — same pattern in `HardCeilingRow`.
  - `MissedDeletionsSheet.swift:226-231, 248-253` — `Toggle(isOn: $minBoundEnabled) { Text("From") }.labelsHidden()` strips the inner `Text` from VoiceOver, leaving the switch unlabeled.
- **Why it matters:** ToggleRow is the shared row primitive used across Settings for every binary preference (Alert on aborted run, Verbose journal, Incremental server sync, etc.) — possibly the most-used VoiceOver-traversed control on the Settings screen. A blind user navigating Settings hears "switch, on. switch, off. switch, off." with no idea which setting each toggle controls.

### H6 — `ProgressBar` lacks accessibilityValue + accessibilityLabel
- **Category:** VoiceOver
- **Sites:**
  - `StatusScreen.swift:2455-2480` — custom `ProgressBar` view (used on Status sync card and on InitialScan)
  - `StatusScreen.swift:1123, 1129` — `ProgressBar(fraction: ..., tone: ...)` for sync progress
  - `InitialScanScreen.swift:506` — `ProgressBar(fraction: ..., tone: .pending)` for the hero indexing progress
  - `SyncDetailSheet.swift:161-169` — inline progress capsule (no label/value)
- **Observation:** SwiftUI's native `ProgressView` carries a built-in accessibility role and value. The custom `ProgressBar` (composed from `Capsule`+`GeometryReader`) does not — VoiceOver reports nothing.
- **Why it matters:** indexing is the longest single operation cairn performs (potentially minutes to tens of minutes on first run). A VoiceOver user gets no audible feedback that work is happening, much less how close it is to done. They can't tell if the app is stuck or making progress.

### H7 — Decorative wordmark text is announced as duplicate of brand mark
- **Category:** VoiceOver
- **Sites:**
  - `CairnPrimitives.swift:219` — `CairnMark.accessibilityLabel("cairn")`
  - `CairnPrimitives.swift:241` — `CairnHeroMark.accessibilityLabel("cairn")`
  - `CairnPrimitives.swift:380` — `CairnWordmark` already does `.accessibilityElement(children: .ignore).accessibilityLabel("cairn")` (correct)
  - But surfaces like `StatusScreen.swift:500-514` (`wordmarkHeader`) wrap `CairnWordmark` + status chip together — the wordmark's "cairn" plus subhead "reconciling iPhone 15 Pro" plus a status pill all get read individually, and the surrounding text already says "cairn" inline.
  - `SetupScreen.swift:266` — welcome step's hero text starts with `.cairnWord + Text(" cleans up...")` — the inline `cairnWord` reads "cairn" and the adjacent `CairnWordmark` (size 40, hero) also reads "cairn" — VoiceOver says "cairn, cairn cleans up your Immich server."
- **Why it matters:** screen-reader users get talked over by repeated brand utterances. Mostly a polish issue, but the welcome screen's double-announcement is a first-impression annoyance.

### H8 — `ImmichAssetThumb` is always `accessibilityHidden(true)` even when wrapped in a tappable button
- **Category:** VoiceOver
- **Sites:**
  - `ImmichAssetThumb.swift:85` — `.accessibilityHidden(true)` on the view itself
  - Multiple call sites wrap it in a `Button` with `.accessibilityLabel("View larger thumbnail of \(displayName)")` (e.g., `PendingReviewScreen.swift:1123-1135`). This is correct — the button surfaces a label and the inner image is hidden.
  - BUT in `DryRunSheet.swift:256-272`, the thumbnails in the candidate grid get wrapped in a Button with only an inner `Text(c.name...)` — there's no `.accessibilityLabel` on the Button, so VoiceOver reads only the filename text, missing context like "Live Photo pair," "video," or "tap to zoom."
  - `RunDetailSheet.swift:836-887` — `AssetTile` button wraps `ImmichAssetThumb` + filename text; no `.accessibilityLabel` on the Button. State is conveyed visually (ring + checkmark for selected, greyed for restored, shield for excluded) but there's no `.accessibilityValue` or label reflecting that state. A VoiceOver user can't tell which assets in the run-detail grid are selected.
- **Why it matters:** the asset grid in DryRunSheet is the moment the user decides whether to authorize a destructive trash batch. The selection state on the RunDetail grid is the entry point for restore/exclude. These are the highest-stakes interactive surfaces in the app and they're opaque to VoiceOver.

### H9 — Sync progress and pending-review count changes are not announced
- **Category:** OtherA11y (Live-region updates)
- **Sites:**
  - `StatusScreen.swift` — `library.candidates`, `pendingReviewCount`, `syncPhase`, `syncProgress` all flip during a sync. No `AccessibilityNotification.Announcement.post(...)` or `.accessibilityRespondsToUserInteraction` plumbing anywhere in the project (grepped: zero hits).
  - `DryRunSheet.swift` — phase transitions from `.review → .confirming → .running → .done` are silent.
  - `PendingReviewScreen.swift` — selection-mode count updates ("3 selected") aren't announced.
- **Why it matters:** Apple's accessibility model defines `UIAccessibility.post(notification: .announcement, argument: ...)` (or SwiftUI's `AccessibilityNotification.Announcement`) for live-region content that changes asynchronously. Without it, a VoiceOver user has to repeatedly poll the screen to learn what state cairn is in. For a long-running sync (minutes) this is a real problem — the user can't tell when it's done unless they re-explore the page.

### H10 — Three animations don't honor `accessibilityReduceMotion`
- **Category:** ReduceMotion
- **Sites:**
  - `SettingsScreen.swift:307` — `withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(...) }` for scroll-to-top on tab re-tap. Unconditional.
  - `RunsScreen.swift:79` — same pattern, unconditional.
  - `StatusScreen.swift:443` — `withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(...) }` — unconditional.
  - `StatusScreen.swift:1928` — `withAnimation(.cairnSpring) { ... }` inside `SyncChecklistAnimator` — wait, this one IS gated above by checking `reduceMotion` parameter before entering. Actually `if reduceMotion { target = newTarget } else { withAnimation(.cairnSpring) {...} }` (line 1925-1929) — this one is fine.
- **Why it matters:** users with vestibular disorders (motion sickness, migraines triggered by motion, Meniere's-class conditions) explicitly toggle Reduce Motion in Settings to suppress all non-essential animation. The scroll-to-top animation is a relatively brief 0.25s but cairn's framework already routes through `.cairnBannerAnimation` everywhere else — the three scroll-to-top sites are inconsistent. Also `StatusScreen.swift:485, 491` use `withAnimation(reduceMotion ? .none : ...)` correctly — these three sites just need the same gate.

### H11 — `CairnHelpPopoverBridge`'s `UIHostingController` host has accessibility user-interaction disabled at the wrong layer
- **Category:** VoiceOver
- **Sites:**
  - `CairnHelpPopoverBridge.swift:308` — `view.isUserInteractionEnabled = false` on the `CairnPopoverHostViewController`'s view. The intent (comment says "touches pass through to SwiftUI (?) button") is touch-through, but this also prevents VoiceOver focus from reaching the hosted popover content.
  - The custom `UIPopoverBackgroundView` (CairnPopoverBackgroundView, lines 37-217) overrides `draw(_:)` but never sets `isAccessibilityElement = false` or hides itself from a11y, so it may compete with the popover content for VoiceOver focus.
- **Why it matters:** help popovers are where every load-bearing setting's explanation lives ("Safety rail" copy at `SettingsScreen.swift:358-361`, deferred-queue mechanics, backlog-alert explainer, etc.). For sighted users this is a discovery shortcut; for VoiceOver users this *is* the documentation. If the popover is unreadable by VoiceOver, blind users have no way to learn what each setting does.

---

## Medium severity

### M1 — `KeyValRow`'s tap area doesn't expose a button trait until tapped
- **Category:** VoiceOver
- **Sites:** `CairnPrimitives.swift:566-622`
- **Observation:** `KeyValRow` uses `.onTapGesture { onTap?() }` on a Rectangle contentShape, then conditionally `.accessibilityAddTraits(onTap != nil ? [.isButton] : [])`. Correct in principle, but the *whole row* is a button — VoiceOver should describe it as one element, not three (label, value, chevron). Missing `accessibilityElement(children: .combine)` or similar to coalesce the row into a single VoiceOver focus.
- **Why it matters:** Settings is dense with KeyValRow instances. A VoiceOver user has to swipe through label-then-value-then-chevron on every row to reach the next row. Combining them into one button-traited element halves the swipe count.

### M2 — Tap-to-zoom thumbnail overlay traps VoiceOver focus poorly
- **Category:** VoiceOver / FocusOrder
- **Sites:**
  - `DryRunSheet.swift:113-137` — `.overlay { if let zoomed = zoomedCandidate { ZStack { Color.black.opacity(0.7).onTapGesture { ... } ... } } }`
  - `PendingReviewScreen.swift:244-274` — same pattern
- **Observation:** when the zoom overlay is presented, the background content (candidate grid, settings rows) is still in the accessibility tree. A VoiceOver user can swipe right and tab out of the zoomed overlay into the dimmed content underneath. No `accessibilityAddTraits([.isModal])` or `.accessibilityHidden(true)` on the underlying ScrollView.
- **Why it matters:** modal expectations are broken. Sighted users see a black backdrop and understand the overlay is dominant; VoiceOver users can wander into the dimmed content, tap something, and not be able to find their way out.

### M3 — `CairnSegmentedPicker` and `CairnRadioList` announce selection with empty value
- **Category:** VoiceOver
- **Sites:**
  - `CairnPrimitives.swift:1553` — `.accessibilityValue(isSelected ? "Selected" : "")`
  - `CairnPrimitives.swift:1643` — same pattern
- **Observation:** when an option is NOT selected, the empty string makes VoiceOver fall back to reading nothing for the value. Better: announce "Selected" / "Not selected" or use `.accessibilityAddTraits(.isSelected)` for the selected case and let the unselected one be silent.
- **Why it matters:** the segmented pickers control Appearance (Auto/Light/Dark) and Time Format (System/12-hour/24-hour), and the radio list controls Strictness (Strict/Trusting/Auto) — load-bearing settings. VoiceOver users can't tell at a glance which is active.

### M4 — `CairnTabBar` accent for active tab is conveyed only by color
- **Category:** VoiceOver
- **Sites:** `CairnPrimitives.swift:1403-1409`
- **Observation:** active tab uses `t.text` color vs `t.textMuted`. The traits include `.isSelected` for the active tab, which IS correct VoiceOver semantics. Good. BUT the icon-vs-label spatial relationship within a tab item (`VStack { icon ; Text(label) }`) reads as two elements by default. Missing `.accessibilityElement(children: .combine)`.
- **Why it matters:** small-but-frequent friction. The tab bar is the global navigation hub — a VoiceOver user touches it many times per session.

### M5 — `Stat` value with `color:` override defeats type-hierarchy contrast
- **Category:** Contrast
- **Sites:**
  - `CairnPrimitives.swift:681, 698` — `Stat(label:, value:, sub:, color:)` allows callers to override the hero number's color. Used at multiple sites with semantic ink colors.
  - `StatusScreen.swift:958, 978` — `readyToTrashColor` returns `t.verifiedInk / t.pendingInk / t.dangerInk` — bare-on-paper rendering. `pendingInk on paper` = 3.66:1 (below AA).
- **Why it matters:** the "READY TO TRASH" hero number is the most visually prominent element on Status. When it's in `pendingInk` (the most common positive non-zero state), it fails AA against the page background.

### M6 — `CairnChip`'s small text fails contrast against `t.bg`
- **Category:** Contrast
- **Sites:** `CairnPrimitives.swift:144-160` — chip foreground is `t.textBody` on neutral or `t.dangerInk` on danger, against `t.bg`. Both pass; but the chip is 11pt + 0.66 tracking, very small. WCAG technically allows 4.5:1 here because it's not "large" (≥14pt bold or ≥18pt), but the tracked semibold text is at the edge of legibility — combine with the small size and the wide tracking gap is hard to scan. Not strictly a failure; flagging as marginal.
- **Why it matters:** chips are everywhere (per-row "Trash now", section badges, "Bulk exclude N"), and they're below comfortable reading size for users with mild vision loss.

### M7 — Sync details disclosure (`Show details` button on Status) lacks `accessibilityHint`
- **Category:** VoiceOver
- **Sites:** `StatusScreen.swift:1087-1099` — Button labeled "Show sync details" with `accessibilityLabel("Show sync details")`. Fine label but no hint that opening it shows a sheet with phase timeline + activity log.
- **Why it matters:** VoiceOver users explore unknown apps via labels first, hints second. Without a hint, opening the sheet is a leap.

### M8 — Cancellation states ("Cancelling…" / "Stopping…") not announced as state changes
- **Category:** OtherA11y
- **Sites:**
  - `StatusScreen.swift:1150-1172` — cancel button swaps to "Cancelling…" with ProgressView when tapped
  - `InitialScanScreen.swift:691-723` — same pattern with "Stopping…"
- **Observation:** the label change is visual-only. VoiceOver would need an `AccessibilityNotification.Announcement.post(value: "Cancelling sync")` triggered on the same state change so the user knows their tap registered.
- **Why it matters:** for VoiceOver users, the only feedback that the cancel registered is the next time they swipe back to the button — silently broken until then.

### M9 — Inline `.cairnWord` (monospaced inline "cairn") embedded in prose may interrupt VoiceOver flow
- **Category:** VoiceOver
- **Sites:** Pervasive — `Text.cairnWord` is concatenated into prose throughout (e.g., `SetupScreen.swift:266, 289, 534, 546, 578, 583, 602, 617, 655, 667, 817, 867; PendingReviewScreen.swift:547, 590, 663, 867; StatusScreen.swift` etc.).
- **Observation:** `Text("...so ") + .cairnWord + Text(" can detect...")` — the monospace styling changes the AttributedString style, but VoiceOver should still read straight through. iOS 17+ generally handles this well; older iOS versions sometimes paused or pronounced the styled run weirdly. Likely benign on iOS 26.4, but worth a manual VoiceOver pass at one site to confirm.
- **Why it matters:** if VoiceOver does pause between styled runs, the speech becomes choppy. Low confidence on actual impact; flagging for hands-on validation.

### M10 — Onboarding "Continue" button is always enabled and may give VoiceOver users false success feedback
- **Category:** VoiceOver
- **Sites:** `SetupScreen.swift:941-957`
- **Observation:** per the inline comment, Continue stays visually-primary at all times to avoid App Review confusion. But when the per-step gate isn't met, tapping it silently triggers `tryAdvance()` which may focus a field or kick off a verify. No state announcement on what happened.
- **Why it matters:** a VoiceOver user taps Continue, no audible response, then has to manually re-explore to find the verify button or the empty field. A short `.accessibilityHint("Verify server first")` (or dynamic hint per step) would close this loop.

### M11 — DatePickers in `MissedDeletionsSheet` use `.labelsHidden()` with no `accessibilityLabel`
- **Category:** VoiceOver
- **Sites:** `MissedDeletionsSheet.swift:232-239, 254-261`
- **Observation:** `DatePicker("From", ...).labelsHidden()` — the title "From" is suppressed visually but should still surface to VoiceOver via the modifier's argument… in practice, `labelsHidden()` historically hid it from a11y too. Need to verify on-device; if confirmed, VoiceOver picks two unlabeled date pickers with no context.

### M12 — Tab bar icon-only "status" tab uses `CairnMark` whose semantic role is "cairn" (the brand), not "Status" (the page)
- **Category:** VoiceOver
- **Sites:** `CairnPrimitives.swift:1390-1410`
- **Observation:** the Status tab renders `CairnMark` (which labels itself "cairn") and below it `Text("Status")`. The outer button has `.accessibilityLabel(tab.label)` = "Status" which is correct, BUT the inner `CairnMark` carries its own accessibility label "cairn" — depending on iOS VoiceOver heuristics this may bubble up or compete.
- **Why it matters:** the tab bar item's name should be "Status" not "cairn, Status." Worth confirming; if competing, the inner `CairnMark` should be `accessibilityHidden(true)` when used inside a labeled parent.

### M13 — Pull-to-refresh on Status doesn't surface its state via VoiceOver
- **Category:** OtherA11y
- **Sites:** `StatusScreen.swift:447-455` — `.refreshable { await onRefreshSync() }`
- **Observation:** SwiftUI's `.refreshable` does have built-in VoiceOver support (the system spinner is announced), but for a deeper sync that runs minutes after the spinner dismisses, the user gets no further audible cue.

### M14 — `degradedBanner`/`stateBanner` transitions are not announced; the user discovers them by re-exploring
- **Category:** OtherA11y
- **Sites:** `StatusScreen.swift:570-628` — multiple banner variants (server unreachable, API key rejected, photos limited, etc.).
- **Observation:** when these banners appear, VoiceOver focus stays on whatever the user was last on. A new banner means a new state change; users with screen-readers usually expect a polite announcement. No announcements are wired.

---

## Low severity

### L1 — `Help` accessibility label is the same for every popover, regardless of context
- **Category:** VoiceOver
- **Site:** `CairnPrimitives.swift:834` — `.accessibilityLabel("Help")`. Every `HelpPopover` in the app reads "Help" rather than "Help with Safety rail" / "Help with Deletion strictness."
- **Why it matters:** a VoiceOver user navigating Settings hears "Help, Help, Help, Help" once per setting. Hard to know which to open.

### L2 — Status `journalHeroLine` button has no accessibility label
- **Category:** VoiceOver
- **Site:** `StatusScreen.swift:364-403` — the hero journal line is a Button containing a circle + event Text + message Text + time Text. No `.accessibilityLabel`; VoiceOver assembles a compound from the inner Texts, which is workable but verbose ("ok bullet trash apply moved 12 to trash 17:32").

### L3 — Live Photo badge on `ImmichAssetThumb` is decorative, not labeled
- **Category:** VoiceOver
- **Site:** `ImmichAssetThumb.swift:77-83`. The view is `accessibilityHidden(true)` so this is moot for the image itself, but call sites that label the surrounding button as e.g. "View larger thumbnail of IMG_4821.HEIC" miss the live-pair context.

### L4 — `RowDivider` is not hidden from accessibility
- **Category:** VoiceOver
- **Site:** `CairnPrimitives.swift:662-672`. A 0.5pt-tall colored rectangle has no semantic role, but VoiceOver may report it as a generic element if it captures focus.

### L5 — `ProgressView` spinner in cancel state lacks accessibility label
- **Category:** VoiceOver
- **Sites:** `StatusScreen.swift:1156-1159, InitialScanScreen.swift:696-700, SettingsScreen.swift:1697-1701`. Each uses `ProgressView()` without `.accessibilityLabel("Cancelling sync")`-style context. SwiftUI's built-in handling does announce "in progress" but tightly-coupled context would be clearer.

### L6 — Confirmation dialog buttons rely on `role: .destructive` for color, no explicit label change for VoiceOver
- **Category:** VoiceOver
- **Sites:** `PendingReviewScreen.swift:884-933`, etc.
- **Observation:** SwiftUI's `Button(_:role:)` does set the appropriate trait (`.isDestructive` reads "Move to Trash, button, destructive" by VoiceOver), so this is mostly fine. Flagging in case any future Button uses a custom label without the role.

### L7 — The `StatusScreen` `quarantineLine` button packs everything into the label, including the trailing "Tap to review."
- **Category:** VoiceOver
- **Site:** `StatusScreen.swift:1245` — `.accessibilityLabel("\(quarantineCount) items in quarantine. Tap to review.")`
- **Observation:** the "Tap to review" suffix duplicates what the button trait already conveys ("button" implies tappable). Could be cleaner as a hint instead of label.

---

## Cross-cutting recommendations (informational, not findings)

These aren't single sites — they're patterns to evaluate at the architectural level:

- **`CairnTokens` color contrast model:** the current `textMuted` / `textHint` derivation aims for visual hierarchy; in practice it sacrifices AA contrast. Consider parameterizing the palette so an "AA contrast" mode can be selected (or always-on) — shifting `textMuted` darker and `textHint` darker still in light mode, lighter in dark mode.
- **Typography model:** swap `Font.system(size:)` for `Font.system(size:relativeTo:)` (with a TextStyle anchor) or pull through `Font.body / .title / .caption` semantic styles. Both opt the font into Dynamic Type with the same default ratios users expect from iOS.
- **Help popover content is currently the only place detailed setting explanations live.** It's effectively the in-app documentation. Wire it through a UIKit a11y-compatible route, or fall back to a sheet/modal with deterministic VoiceOver behavior.
- **No tests cover accessibility.** Apple's Accessibility Inspector + xcodebuild test (with `XCUIApplication.activate` + a11y queries) would catch the missing-label class of regression in CI.

---

End of audit.
