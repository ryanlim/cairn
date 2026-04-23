# Security

## Reporting a vulnerability

If you think you've found a security issue in `cairn`, please **don't** open a public GitHub issue. Instead:

1. Open a **private security advisory** via GitHub: `Security` tab → `Report a vulnerability` on the `cairn` repo, or
2. Email the repository owner (address in the repo's GitHub profile).

Expect an initial response within a week. For anything that could cause unintended asset destruction, credential exposure, or a bypass of `cairn`'s safety rails, faster is better.

## Scope

In-scope:

- The `cairn` iOS app (source in this repo, compiled artifacts distributed via TestFlight / App Store).
- The `cairn` CLI tool.
- The Swift packages (`CairnCore`, `CairnIOSCore`, `CairnCLI`).

Examples of what we'd want to hear about:

- Anything that could cause `cairn` to move a photo to Immich's Trash when the user didn't intend it — safety-rail bypass, reconciliation bug, misidentification.
- Credential leakage — API key or server URL ending up somewhere outside the iOS Keychain / local `.env`, or leaking into logs, crash reports, or analytics (`cairn` has no analytics, so any such finding is a bug).
- On-device data leakage — the journal, hash cache, or settings ending up somewhere shared (iCloud Drive, shared photos, etc.) without explicit user action.
- Malicious server responses causing unexpected client behavior — e.g. a hostile or compromised Immich server being able to coax `cairn` into trashing or exposing data beyond the intended scope.

Out-of-scope:

- Issues in the Immich server itself — please report those to the [Immich project](https://github.com/immich-app/immich) directly.
- Issues in third-party software `cairn` depends on at runtime (Apple frameworks, Swift runtime) — those go to the upstream.
- Self-inflicted configuration issues, e.g. handing out an API key with destructive scopes to someone you don't trust.
- Social-engineering attacks that require the user to hand over credentials or install a malicious binary.

## What we do when we receive a report

1. Confirm and reproduce.
2. Assess severity and scope (does it affect the CLI, the app, both; which versions).
3. Develop and test a fix privately.
4. Coordinate disclosure — generally, publish the fix, push a release, and only then describe the issue in the changelog.
5. Credit the reporter if they want to be credited.

There's no bug bounty — `cairn` is a small open-source project. But security reports are genuinely valued and will be handled seriously.
