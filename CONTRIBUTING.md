# Contributing

`cairn` is a small project. Contributions are welcome; a few ground rules keep the review cycle short.

## Before you start

For anything non-trivial (new feature, architectural change, new dependency), open an issue first. It's faster for both of us to sort out scope in writing than to redo work after a PR lands.

Trivial fixes (typo, doc tweak, obviously-broken-thing) — skip straight to a PR.

## Prerequisites

- macOS 14 (Sonoma) or later.
- Xcode 16 and the Swift 6 toolchain.
- For the iOS app specifically: an Apple Developer account (free tier works for local builds; paid is needed for TestFlight / App Store).
- A reachable Immich server (for end-to-end testing against real data).

## Build and test

```sh
swift build                 # compile every target
swift test                  # run the full test suite — should be green before you push
```

For iOS app changes, additionally:

```sh
cd iOS
make install                # once per machine — xcodegen + fastlane gems
make generate               # regenerates Cairn.xcodeproj from project.yml
open Cairn.xcodeproj        # standard Xcode flow from here
```

See [`iOS/README.md`](iOS/README.md) for the full iOS setup, including the one-time Development Team configuration.

## Style

Read [`ARCHITECTURE.md`](ARCHITECTURE.md) before anything substantial — it captures the accumulated design context the codebase follows, including the portability contract that keeps `CairnCore` platform-neutral. [`CLAUDE.md`](CLAUDE.md) is the shorter working-session companion (current status, in-flight workstreams, and notes useful to AI-pair-programming sessions).

Beyond that:

- **Tests are the conformance spec.** `CairnCore` has no Apple-specific APIs; any behavior change it exposes needs to be test-covered so a future Kotlin port has something to match.
- **Terse comments.** Code should mostly self-document through naming. Comments are for *why* something non-obvious is the way it is, not *what* the code does.
- **No trailing-summary docstrings** on functions that are obvious from their signature.
- **No emojis** in code or in user-facing copy unless explicitly requested — the app's voice is plain.
- **User-facing copy** follows the style captured in recent PRs (Stripe-docs-meets-Strunk-and-White — direct, specific, no marketing adjectives, no empowerment-speak). Match the surrounding tone.
- The product name is `cairn` (all lowercase) in user-facing prose. Swift identifiers stay PascalCase (`CairnCore`, `struct Cairn`).

## Commit and PR conventions

- Short, specific commit subjects. Prefer "Fix NPE in reconcileCacheAgainstLibrary when protectedIds is empty" over "Fix bug".
- Squash before merge is fine. Clean history is appreciated but not enforced.
- If your PR changes user-facing behavior, include a short note in `CHANGELOG.md` under `[Unreleased]`.
- Run `swift test` before pushing. CI runs it too but faster feedback is nicer.

## License

By contributing, you agree that your contributions are licensed under the project's MIT License — see [`LICENSE`](LICENSE).
