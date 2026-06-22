# Immich API contract guardrail

cairn depends on a self-hosted project's REST API. The dependency isn't
"Immich" so much as **the subset of Immich's HTTP API that cairn calls and the
JSON shapes it decodes**. This directory tracks exactly that subset and
notices when it moves upstream.

## Why this exists (and why it's scoped)

cairn talks to Immich through a hand-rolled `ImmichClient` with manual
`Decodable`s — not a generated SDK. That's deliberate: it makes cairn immune to
cosmetic upstream churn (a renamed schema class, a reordered enum, a new field
it ignores). The trade-off is that the compiler can't tell us when something
cairn *does* rely on changes. This guardrail fills that gap.

The check is **scoped to cairn's surface** on purpose. The full Immich spec
(~160 endpoints) changes constantly; 99% of it is irrelevant to us. We extract
only the operations in [`endpoints.json`](endpoints.json) plus every schema
they transitively reference, so the diff fires only when something cairn
actually touches changes.

## Files

- **`endpoints.json`** — the source-of-truth list of operations cairn calls.
  Keep it in sync with `Sources/CairnCore/ImmichClient.swift`: add or remove an
  endpoint there → update this list → regenerate the snapshot.
- **`extract_contract.py`** — extracts the scoped subset from an Immich spec and
  either writes the snapshot (`write`) or diffs a live spec against it
  (`check`). Stdlib-only; runs on a bare runner.
- **`contract-snapshot.json`** — the committed baseline: cairn's endpoint subset
  as it looked in the Immich version we last verified against (currently
  **2.7.5**, matching `ImmichVersionSupport.lastVerified` in the app). Generated,
  not hand-edited.

## What the CI does

[`.github/workflows/immich-contract-check.yml`](../.github/workflows/immich-contract-check.yml)
runs weekly (and on edits to this directory). It fetches the latest upstream
spec from Immich's `main`, runs `extract_contract.py check`, and on drift opens
(or comments on) an issue with the diff. Exit codes from `check`:

- `0` — cairn's subset is unchanged.
- `1` — drift: something in a used operation/schema changed. Review whether it
  affects a field cairn decodes (most drift is additive/cosmetic and safe).
- `2` — an endpoint cairn calls is **gone** from the spec (removed or renamed).
  The loud case; cairn almost certainly needs a change.

## Triaging a drift report

1. Read the diff. Most hits are additive (`format`/`pattern`/`description`
   annotations, new optional fields, loosened patterns) — cairn's tolerant
   decoding absorbs these.
2. The ones that matter: a field cairn decodes being **removed**, **renamed**,
   **retyped**, or made nullable where cairn expects it non-optional; an enum
   value cairn switches on disappearing; an endpoint moving (exit 2).
3. Cross-check against `ImmichClient`'s `Decodable` structs — only fields those
   structs actually read can break cairn.
4. Once reconciled (cairn updated if needed, or confirmed safe), refresh the
   baseline against the spec version you verified:

   ```sh
   python3 immich-contract/extract_contract.py write \
     --spec /path/to/immich-openapi-specs.json \
     --endpoints immich-contract/endpoints.json \
     --snapshot immich-contract/contract-snapshot.json
   ```

   and bump `ImmichVersionSupport.lastVerified` to match.

This is the cheap layer. The thorough layer is running cairn's client against
Immich-in-Docker at pinned version tags — worth adding if drift reviews start
missing behavioral (non-schema) changes.
