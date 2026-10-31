#!/usr/bin/env python3
"""Strip every emSign/eMudhra root CA from one or more certifi cacert.pem files.

Why this exists
---------------
certifi 2026.10.19 fixes GHSA-6q48-6c7w-9gw2 by removing only the single
compromised root ("emSign ECC Root CA - G3"). It STILL ships three other
eMudhra-operated roots:

    emSign Root CA - G1
    emSign Root CA - C1
    emSign ECC Root CA - C3

Our deployment distrusts the ENTIRE emSign/eMudhra family in the OS trust
store (see the overlay Dockerfiles), so for consistency and genuine
"eMudhra-clear" posture the Python TLS trust path (used by litellm, requests,
httpx-via-certifi, pip, ...) must drop them too.

cacert.pem layout: each trust record is a block of `# ...` comment lines
(Issuer / Subject / Label / fingerprints) immediately followed by a
`-----BEGIN CERTIFICATE-----`...`-----END CERTIFICATE-----` PEM body, and
records are separated by a blank line. We split on blank lines and drop any
record whose text mentions emSign or eMudhra. The file preamble (no cert) is
preserved because it does not match.

Idempotent: running it again removes nothing and still exits 0. Exits non-zero
only if, after stripping, an emSign/eMudhra marker somehow survives (defensive).
"""
from __future__ import annotations

import sys

MARKERS = ("emSign", "eMudhra")


def strip_file(path: str) -> int:
    try:
        with open(path, "r", encoding="utf-8") as fh:
            content = fh.read()
    except FileNotFoundError:
        print(f">>> {path}: not found, skipping")
        return 0

    paragraphs = content.split("\n\n")
    kept = []
    removed = 0
    for para in paragraphs:
        if any(m in para for m in MARKERS):
            removed += 1
            continue
        kept.append(para)

    if removed:
        with open(path, "w", encoding="utf-8") as fh:
            fh.write("\n\n".join(kept))

    # Defensive re-check.
    with open(path, "r", encoding="utf-8") as fh:
        residual = fh.read()
    if any(m in residual for m in MARKERS):
        print(f"ERROR: emSign/eMudhra still present in {path} after strip",
              file=sys.stderr)
        return -1

    print(f">>> {path}: removed {removed} emSign/eMudhra record(s)")
    return removed


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print("usage: strip-emsign-certifi.py <cacert.pem> [<cacert.pem> ...]",
              file=sys.stderr)
        return 2
    for path in argv[1:]:
        if strip_file(path) < 0:
            return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
