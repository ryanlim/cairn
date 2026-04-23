# Changelog

All notable changes to `cairn` will land here. Format roughly follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versioning is [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Automated App Store screenshot capture via `make screenshots`. The UITest
  bundle drives the app through Status / Pending Review / Runs / Settings /
  Setup Welcome states with a fixture-mode launch arg that swaps real
  dependencies for `CairnFixtures` data, so captures are deterministic and
  require no Immich server.

## [0.1.0] — Initial release

The first public release. Covers the CLI and the iOS app.

### CLI (`swift run cairn`)

- `verify` — connectivity and auth check against your Immich server.
- `dump-server-checksums` — export every server-side asset's SHA1 for local reconciliation.
- `dry-run` — full reconciliation against a local checksum file, no mutation.
- `trash` — destructive reconciliation. Refuses to run until the user has done at least one dry-run.
- `restore` — undo by run id, by asset id, or by filename regex.
- `journal` — inspect the append-only local audit log.
- `history` — server-side reconstruction using run breadcrumb tags.
- `diagnose` — visibility-class breakdown + Live Photo integrity check.

### iOS app

- **Setup flow** — server URL + API key with live verification, Photos permission, Background App Refresh, safety thresholds, strictness picker, first-scan explainer.
- **Initial scan** — one-time SHA1 pass over the library with foreground progress, pause/resume, iCloud download limits, hard ceiling for pathological large assets.
- **Reconciliation** — detects deletions via `PHPhotoLibrary.fetchPersistentChanges(since:)`, with a cache-vs-library fallback for missed events. Confirmed deletions stamp a per-item quarantine clock.
- **Status screen** — current state, library stats, recent runs, journal tail, banners for degraded / backlog / deferred-hash states.
- **Pending review** — items awaiting user input before being moved to Trash, with per-row approve/exclude actions and a bulk-selection mode.
- **Runs tab** — every reconciliation run with drill-down into the candidate list, safety outcome, and journal of API calls. Per-asset restore or exclude.
- **Settings** — safety thresholds, deletion strictness, quarantine window, iCloud download limits, hard ceiling, backlog alert, exclusions list, color scheme, danger-zone resets.
- **Safety rails** — percent threshold with absolute floor, empty-library abort, first-run preview-then-confirm, two-signal confirmation in strict mode.
- **Breadcrumbs on Immich** — every run tagged as `cairn/v1/run/<run_id>` so a reinstall can still find its history server-side.
- **Exclusions** — protect specific assets from future runs; survives indexing resets.
- **Background App Refresh** — scheduled incremental scans (`BGAppRefreshTask`) and an initial-library-hash processing task (`BGProcessingTask`).

### Shared (`CairnCore`)

- Multi-platform Swift core with no Apple-only APIs. PhotoKit / SwiftData / Keychain / BackgroundTasks / UIKit / SwiftUI stay in `CairnIOSCore`.
- The test suite (181+ tests across 27 suites at release) is the conformance spec — any future Kotlin port has a clear target.

[Unreleased]: https://github.com/glarue/cairn/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/glarue/cairn/releases/tag/v0.1.0
