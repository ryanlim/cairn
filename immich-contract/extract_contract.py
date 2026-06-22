#!/usr/bin/env python3
"""Extract and diff the slice of Immich's OpenAPI spec that cairn depends on.

cairn talks to Immich over a hand-rolled HTTP client (no generated SDK), so a
cosmetic upstream change — a renamed schema class, a reordered enum — is a
non-event for us. What *would* break cairn is a change to the endpoints it
calls or the JSON shapes it decodes. This script isolates exactly that surface:
for each operation listed in endpoints.json it pulls the operation object plus
every component schema it transitively references, normalizes the result, and
either writes it as a snapshot (`write`) or diffs the live spec against the
committed snapshot (`check`).

Scoping the diff to cairn's actual surface is the whole point: the full spec
churns constantly; this only fires when something cairn relies on moves.

Stdlib only — runs on a bare CI runner with no pip install.

Usage:
  extract_contract.py write --spec <spec.json> --endpoints endpoints.json --snapshot contract-snapshot.json
  extract_contract.py check --spec <spec.json> --endpoints endpoints.json --snapshot contract-snapshot.json

Exit codes (check): 0 = no drift, 1 = drift in a used operation/schema,
2 = an endpoint cairn calls is gone from the spec (the loud case).
"""
import argparse
import difflib
import json
import os
import sys

SCHEMA_PREFIX = "#/components/schemas/"


def collect_refs(node, all_schemas, out, visited):
    """Walk an arbitrary spec fragment, resolving every #/components/schemas
    $ref transitively into `out`. Generic over dicts/lists so it catches refs
    wherever they hide (request bodies, responses, params, allOf, items, ...)."""
    if isinstance(node, dict):
        for key, value in node.items():
            if key == "$ref" and isinstance(value, str) and value.startswith(SCHEMA_PREFIX):
                name = value[len(SCHEMA_PREFIX):]
                if name not in visited:
                    visited.add(name)
                    schema = all_schemas.get(name)
                    if schema is not None:
                        out[name] = schema
                        collect_refs(schema, all_schemas, out, visited)
            else:
                collect_refs(value, all_schemas, out, visited)
    elif isinstance(node, list):
        for item in node:
            collect_refs(item, all_schemas, out, visited)


def build_subset(spec, endpoints):
    all_schemas = spec.get("components", {}).get("schemas", {})
    paths = spec.get("paths", {})
    operations = {}
    schemas = {}
    visited = set()
    missing = []
    for ep in endpoints:
        method = ep["method"].lower()
        path = ep["path"]
        key = f"{ep['method'].upper()} {path}"
        op = paths.get(path, {}).get(method)
        if op is None:
            missing.append(key)
            continue
        operations[key] = op
        collect_refs(op, all_schemas, schemas, visited)
    return {"operations": operations, "schemas": schemas}, missing


def normalize(obj):
    return json.dumps(obj, sort_keys=True, indent=2) + "\n"


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("mode", choices=["write", "check"])
    ap.add_argument("--spec", required=True, help="path to immich-openapi-specs.json")
    ap.add_argument("--endpoints", required=True, help="path to endpoints.json")
    ap.add_argument("--snapshot", required=True, help="path to contract-snapshot.json")
    args = ap.parse_args()

    with open(args.spec) as f:
        spec = json.load(f)
    with open(args.endpoints) as f:
        endpoints = json.load(f)["endpoints"]

    subset, missing = build_subset(spec, endpoints)
    rendered = normalize(subset)

    if missing:
        print("ERROR: endpoints cairn calls are absent from the upstream spec "
              "(removed or path renamed):", file=sys.stderr)
        for m in missing:
            print(f"  - {m}", file=sys.stderr)
        if args.mode == "check":
            sys.exit(2)

    if args.mode == "write":
        with open(args.snapshot, "w") as f:
            f.write(rendered)
        print(f"Wrote {args.snapshot}: "
              f"{len(subset['operations'])} operations, {len(subset['schemas'])} schemas.")
        return

    # check
    if not os.path.exists(args.snapshot):
        print(f"ERROR: snapshot {args.snapshot} not found — run `write` first.", file=sys.stderr)
        sys.exit(2)
    with open(args.snapshot) as f:
        committed = f.read()
    if committed == rendered:
        print(f"OK: cairn's Immich API subset is unchanged "
              f"({len(subset['operations'])} operations, {len(subset['schemas'])} schemas).")
        return
    print("DRIFT: the Immich endpoints/schemas cairn depends on changed upstream.\n",
          file=sys.stderr)
    diff = difflib.unified_diff(
        committed.splitlines(keepends=True),
        rendered.splitlines(keepends=True),
        fromfile="committed snapshot",
        tofile="upstream now",
    )
    sys.stderr.writelines(diff)
    sys.exit(1)


if __name__ == "__main__":
    main()
