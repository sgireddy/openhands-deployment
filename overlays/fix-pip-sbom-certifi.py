#!/usr/bin/env python3
"""Align the certifi version in pip's vendored CycloneDX SBOM with reality.

pip ships a CycloneDX SBOM at ``pip/_vendor/bom.cdx.json`` describing its
vendored dependencies. After we replace the vendored ``certifi`` with the
upgraded, eMudhra-stripped bundle, this SBOM still lists the OLD certifi
version (e.g. 2026.6.17), and scanners such as Trivy read the SBOM in
preference to the actual files — so they keep reporting the superseded,
CVE-flagged version (GHSA-6q48-6c7w-9gw2).

This script rewrites the ``certifi`` component's ``version``, ``purl`` and
``bom-ref`` to the version actually installed, so the SBOM faithfully reflects
the vendored tree. Idempotent; a missing file or missing component is a no-op.

usage: fix-pip-sbom-certifi.py <bom.cdx.json> <version>
"""
from __future__ import annotations

import json
import sys


def fix(path: str, version: str) -> int:
    try:
        with open(path, "r", encoding="utf-8") as fh:
            data = json.load(fh)
    except FileNotFoundError:
        print(f">>> {path}: not found, skipping")
        return 0

    changed = 0
    for comp in data.get("components", []):
        if comp.get("name") != "certifi":
            continue
        purl = f"pkg:pypi/certifi@{version}"
        if comp.get("version") != version or comp.get("purl") != purl:
            comp["version"] = version
            comp["purl"] = purl
            if "bom-ref" in comp:
                comp["bom-ref"] = purl
            changed += 1

    if changed:
        with open(path, "w", encoding="utf-8") as fh:
            json.dump(data, fh, indent=2)
    print(f">>> {path}: updated {changed} certifi SBOM component(s) to {version}")
    return changed


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        print("usage: fix-pip-sbom-certifi.py <bom.cdx.json> <version>",
              file=sys.stderr)
        return 2
    fix(argv[1], argv[2])
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
