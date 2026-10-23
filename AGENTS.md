# AGENTS.md — repo-local memory for AI agents

Persistent notes for any agent working on this repo. Keep terse and current.

## Repo purpose

Hardening overlay for two OpenHands images:

- **`openhands`**     — frontend / orchestration container (Node + Python).
- **`agent-server`**  — sandbox / runtime container (Python + browser tools).

Each gets a thin overlay Dockerfile that applies apt + Python upgrades on
top of an upstream maintainer-published base, then is scanned by Scout
or Trivy. Output images are tagged `:custom_base` and pushed to
`docker.io/sgireddy/{openhands,agent-server}`.

## Build / scan / push topology

The repo is developed on **two Macs** but **only the Intel Mac has a
working Docker daemon, Docker Desktop login, and credential keychain**.
All builds, scans, and pushes happen on that host.

The agent typically runs in a Linux container that **does not have**
Docker locally. It drives the Intel Mac via SSH (host alias `mac`):

```
ssh mac '<command>'           # arbitrary command on Intel Mac
DOCKER_CONFIG=$HOME/.docker-ssh   # logged-in Docker config inside SSH sessions
                                  # (the default $HOME/.docker uses macOS keychain
                                  # which is locked from non-GUI sessions)
```

**Two-step setup for `~/.docker-ssh` (one-time):**

1. From an interactive Mac Terminal.app session (so credsStore is reachable):
   ```
   DOCKER_CONFIG=$HOME/.docker-ssh docker login -u sgireddy
   ```
   This populates `~/.docker-ssh/config.json` but with `credsStore:
   "osxkeychain"` — which **doesn't help SSH-driven docker** because
   keychain is still locked from non-GUI sessions.
2. Strip the `credsStore` line and re-login. The CLI will print a
   "stored unencrypted" warning, which is what we want — token now lives
   in the file:
   ```
   python3 -c 'import json; p="$HOME/.docker-ssh/config.json"; d=json.load(open(p)); d.pop("credsStore", None); d.pop("credHelpers", None); json.dump(d, open(p, "w"), indent=2)'
   DOCKER_CONFIG=$HOME/.docker-ssh docker login -u sgireddy
   ```
   After this, `ssh mac 'env DOCKER_CONFIG=$HOME/.docker-ssh docker push …'`
   works without keychain unlock.

Also wire buildx + plugins into `~/.docker-ssh` (else SSH sessions can't
find buildx):
```
mkdir -p ~/.docker-ssh
ln -sfn ~/.docker/cli-plugins ~/.docker-ssh/cli-plugins
ln -sfn ~/.docker/buildx      ~/.docker-ssh/buildx
```

Scout binary inside SSH sessions is keychain-blocked even with
`DOCKER_CONFIG` workaround (Scout requires interactive login). Use
**Trivy** for any scan driven from the agent. The user can run Scout
manually from a Terminal.app GUI session and paste output back.

Trivy install: `brew install trivy` (already installed at
`/opt/homebrew/bin/trivy` on Apple-Silicon Mac, may differ on Intel).

## Key paths

| Where               | Path                                                        |
|---------------------|-------------------------------------------------------------|
| Mac canonical repo  | `~/projects/openhands-deployment` (i.e. `/Users/reactivedev/projects/openhands-deployment`) |
| Build context       | same dir                                                    |
| Scan reports        | `~/openhands-deployment/reports/<timestamp>/`               |
| Runtime data        | `~/openhands-deployment/` (outside repo by design)          |
| Build scripts       | `scripts/build.sh` / `build.ps1`                            |
| Verify scripts      | `scripts/verify.sh` / `verify.ps1`                          |
| Update upstream pin | `scripts/update.sh` / `update.ps1`                          |
| Overlays            | `overlays/Dockerfile.{openhands,agent-server}`              |

## Cross-arch policy

User wants **multi-arch (linux/amd64 + linux/arm64)** for both images.
Intel Mac builds natively on amd64 and uses QEMU emulation for arm64
through `docker buildx` (slow but works).

The Apple-Silicon Mac is the opposite: native arm64, emulated amd64.
Either works. The Intel Mac was chosen for this work because amd64
is the dominant deploy target (faster native scan).

## Critical-CVE policy

`POLICY_MAX_CRITICAL=0` in `.env` — build fails if final image has any
Critical-severity CVE that has a fix available. Unfixable Criticals can
be temporarily allowed via `--ignore-unfixed` style filtering, but the
user explicitly does NOT want that filter as default; the goal is
**Critical=0 across the board**, achieved by removing the unused
components that carry the CVEs.

## emSign / eMudhra CA distrust (2026-10)

The emSign root (eMudhra's CA brand) had compromised intermediate CA
keys and is being distrusted everywhere. It shows up in **three**
independent trust stores in our images, and each needs its own fix —
removing one does NOT cover the others:

1. **Debian system trust store** (`ca-certificates`). Debian blacklisted
   `emSign ECC Root CA - G3` in `ca-certificates 20260816+nmu1`
   (bug #1151413, NMU 2026-10-20) but that upload only reached
   `sid`/`forky`. `trixie` (20250419) and `bookworm` (20230311+deb12u1)
   still trust it, so `apt-get upgrade` alone does NOT remove it.
   **IMPORTANT: emSign is a FAMILY of roots, not just G3.** trixie
   `ca-certificates 20250419` ships FOUR emSign roots:
   `emSign_ECC_Root_CA_-_C3`, `emSign_ECC_Root_CA_-_G3`,
   `emSign_Root_CA_-_C1`, `emSign_Root_CA_-_G1`. The first overlay version
   only blacklisted G3 and the build-guard (correctly) FAILED because the
   other three survived in `/etc/ssl/certs`. The overlays now blacklist
   **every** `mozilla/emSign*` line (prefix with `!`, case-insensitive,
   then `update-ca-certificates --fresh`). Default-on; opt out with
   `--build-arg KEEP_EMSIGN_ROOT=1` once stable backports the distrust.
   The overlay step self-verifies and fails the build if NO emSign entry
   is found (upstream rename) or if ANY emSign link survives in
   `/etc/ssl/certs`. (This fail-closed guard is what caught the G3-only
   gap on the 1.58.0-python base — keep it.)
2. **Python `certifi`** (`GHSA-6q48-6c7w-9gw2`) — bundles its own CA
   pem. **Bumping to `certifi 2026.10.19` is necessary but NOT sufficient.**
   That release removes only the ONE compromised root
   (`emSign ECC Root CA - G3`); it STILL ships three other eMudhra roots
   (`emSign Root CA - G1`, `emSign Root CA - C1`,
   `emSign ECC Root CA - C3`). Trivy stops flagging the package (the CVE'd
   root is gone) but the Python TLS path (litellm/requests/httpx/pip) would
   keep trusting eMudhra. The overlays run `overlays/strip-emsign-certifi.py`
   on BOTH the top-level `certifi/cacert.pem` AND pip's vendored
   `pip/_vendor/certifi/cacert.pem` to remove the whole family — matching the
   OS-store distrust. The emSign-residue guard in the overlay step fails the
   build if any eMudhra marker survives. Pin certifi via `PIP_UPGRADES_*`.
   NOTE: pip's **vendored** certifi is a SEPARATE copy Trivy reports by the
   version in `pip/_vendor/certifi/__init__.py` (`__version__`) and
   `pip/_vendor/vendor.txt` (watch the leading whitespace on that line); the
   overlay replaces the whole vendored dir from the upgraded top-level and
   rewrites both markers.
3. **`uv`** (`GHSA-hq85-5cpj-mr62`) — vendors a webpki root set that
   trusts the emSign root. Fixed in `uv 0.13.4`. If `uv` is a standalone
   binary rather than a venv dep, the pip bump may not move it — then
   `uv self update` or replace `/usr/local/bin/uv` in the overlay.

Related TLS-cert bug bundled alongside: `anyio` `CVE-2026-63374` (TLS
certificate spoofing via IDNA) — fixed in `anyio 4.14.2`.

### `linux-libc-dev` kernel-header CVEs (accepted, not runtime-applicable)

Trivy flags two Criticals on the `linux-libc-dev` package in the
agent-server (1.58.0-python base, Debian 13.7):

- `CVE-2026-93221` — **no fix available** in any suite.
- `CVE-2026-98805` — fixed in `6.12.113-1`, but that version is **not in
  the base image's pinned apt snapshot** (`snapshot.debian.org/.../
  20261004T000000Z`); the newest candidate there is `6.12.111-1`, so
  `apt-get upgrade` cannot pull it. (Confirmed via `apt-cache policy`.)

`linux-libc-dev` is **kernel headers only** — there is no running kernel in
the image; containers use the host kernel. These kernel CVEs are therefore
not exploitable through the headers package at runtime. We accept them and
do NOT purge the package by default, because removing it cascades to
`libc6-dev`/the C toolchain (`libc6-dev depends on linux-libc-dev`), which
the sandbox may need to build C-extension wheels at runtime. If a literal
`Critical=0` Trivy number is required, the user can opt into a toolchain
strip, accepting the loss of in-sandbox compilation. Scout/Trivy will keep
listing these until Debian backports `6.12.113-1` into the pinned snapshot.

## Trivy CRITICAL review snapshot (2026-10-22)

Scanned the **published** Hub slim images with fresh Trivy DB. Both have
accumulated Criticals because the artifacts predate these CVEs — a
rebuild + re-push is required. Most OS Criticals clear automatically on
rebuild (fixed versions are in `trixie-security`); the pip ones need the
`PIP_UPGRADES_*` pins now recorded in `.env.example`.

`sgireddy/openhands:custom_base-slim` — 28 Critical:
- OS (fixed on rebuild): `libgnutls30t64` 3.8.9-3+deb13u2→u4 (2),
  `perl*`/`libperl5.40` 5.40.1-6→+deb13u1 (many).
- OS (NO fix, document): `openssh-*`/`ssh` `CVE-2026-60002`.
- Python pins: `certifi`→2026.10.19, `anyio`→4.14.2, `litellm`→1.84.0
  (`CVE-2026-49468`), `pillow`→13.0.0 (4 CVEs), `GitPython`→3.1.59,
  `PyJWT`→2.14.0, `jupyter_server`→2.20.0.

`sgireddy/agent-server:custom_base-slim` — 31 Critical:
- OS (fixed on rebuild): `libglib2.0-0t64`/`-data` →2.84.4-3~deb13u4 (2),
  `libgnutls30t64` →u4 (2), `perl*` →+deb13u1, `linux-libc-dev`
  →6.12.113-1 (the fixed ones).
- OS (NO fix, document): `libxml2` `CVE-2026-6653`; `linux-libc-dev`
  `CVE-2026-93221` (kernel *headers* only — not a running kernel, low
  runtime impact; consider dropping the dev package).
- Node (bundled npm): `@google/gemini-cli` 0.38.0→0.39.1
  (`CVE-2026-12537`, RCE), `proxy-addr` 2.0.7→2.0.8, `tar` →7.5.19
  (`CVE-2026-59873`). **Now fixed in the overlay** (see below).
- Python pins: `certifi`→2026.10.19, `uv`→0.13.4, `anyio`→4.14.2.

Re-scan from the registry after rebuild/push to confirm 0C.

## Rebuild on 1.58.0-python base — local Trivy verification (2026-10-22)

Built `overlays/Dockerfile.agent-server` against
`ghcr.io/openhands/agent-server:1.58.0-python` (Debian **13.7**), linux/arm64,
`--load` for local scan, with `STRIP_BROWSER_TOOLS=1 STRIP_DIND=1` and
`PIP_UPGRADES="certifi==2026.10.19 uv==0.13.4 anyio==4.14.2 litellm==1.93.2"`.

Trivy CRITICAL went 4 → 2 after the overlay fixes. Remaining 2 are both
`linux-libc-dev` kernel-header CVEs (accepted — see the emSign section above).

Fixes that cleared the others (all now in the overlays):
- **shell-quote** — the bundled copy in
  `/openhands/.openvscode-server/node_modules/shell-quote` was 1.8.3
  (`CVE-2026-9277` ACE). 1.8.4 was ALSO vulnerable (`CVE-2026-102422`), so we
  pin **1.12.0** (latest, 0 OSV advisories) and replace every bundled copy via
  `npm pack` (download-only; doesn't disturb the dep tree).
- **certifi / emSign** — three separate carriers had to be fixed, in this
  order of discovery:
  1. top-level `certifi/cacert.pem` — upgraded to 2026.10.19 AND stripped of
     the 3 residual eMudhra roots.
  2. pip's **vendored** certifi (`pip/_vendor/certifi/`) — replaced from the
     stripped top-level; `__init__.py __version__` + `vendor.txt` rewritten.
  3. pip's **CycloneDX SBOM** (`pip/_vendor/bom.cdx.json`) — Trivy reads this
     in preference to the files and kept reporting 2026.6.17; the
     `fix-pip-sbom-certifi.py` helper rewrites the certifi component.

Verified in the built image: OS trust store has no emSign; `certifi.where()`
and the pip-vendored cacert both have 0 emSign records; installed versions
certifi 2026.10.19, litellm 1.93.2, anyio 4.14.2, uv 0.13.4, shell-quote
1.12.0.

## openhands slim overlay — local Trivy verification (2026-10-23)

Built `overlays/Dockerfile.openhands` on top of local `openhands:custom_base`
(the documented slim-on-custom_base pattern), linux/arm64, `--load`, with
`STRIP_VSCODE_BUILD_ARTIFACTS=1`, the new `STRIP_OPENSSH=1`, and
`PIP_UPGRADES="certifi==2026.10.19 anyio==4.14.2 litellm==1.93.2 pillow==13.0.0
GitPython==3.1.59 PyJWT==2.14.0 jupyter_server==2.20.0 lxml==6.1.0"`.

Result: **Trivy CRITICAL = 0** (HIGH 153 → 130). Verified in-image: OS trust
store has no emSign; `/app/.venv` certifi cacert 0 emSign, certifi 2026.10.19,
litellm 1.93.2, anyio 4.14.2, pillow 13.0.0, lxml 6.1.0; no openssh packages.

The certifi/emSign overlay steps run as the **openhands** user and correctly
target the `/app/.venv` venv (stripped 3 eMudhra roots from the top-level
cacert, synced the pip-vendored copy). Confirms the mirrored fixes work in the
app image's venv layout.

### OpenSSH `CVE-2026-60002` (client-side, unfixable) — removed via STRIP_OPENSSH

The openhands base ships openssh 1:10.0p1-* (client/server/sftp-server/ssh).
`CVE-2026-60002` is a use-after-free in the `ssh` **client** when a server
swaps its host key during a key re-exchange (pre-OpenSSH 10.4, client-side
only). Debian has **no fix in any suite**, so it shows as 4 Criticals (one per
openssh sub-package). The app runs no sshd and uses git over HTTPS+token (git
only *Recommends* ssh-client, does not depend on it), so OpenSSH is unused.

`overlays/Dockerfile.openhands` now has an opt-in `STRIP_OPENSSH` build-arg that
purges all four openssh packages (verified: no cascade to git/libssl) with a
fail-closed post-purge dpkg check. Default OFF (keeps git+ssh). Enabling it is
what takes the openhands slim to 0 Critical. agent-server does NOT ship openssh,
so no equivalent flag is needed there.

Still TODO: the multi-arch `--push` of both images + registry re-scan. For a
fully current openhands app, note the local base is the **0.x** source fork
(`~/projects/OpenHands`, describe `0.22.0-...`), not the new 1.x SDK app — the
1.x app is distributed differently and is a separate base-sourcing decision.

## Base-image currency + litellm supply-chain (2026-10-22)

Target the newest published bases:

- **agent-server**: `ghcr.io/openhands/agent-server:1.58.0-python` (newest
  release, multi-arch amd64+arm64, Debian 13.4 / Trixie). `.env.example`
  `AGENT_SERVER_BASE_TAG` bumped 1.19.1-python → 1.58.0-python.
  `scripts/update.{sh,ps1}` already derive this tag from the SDK's latest
  GitHub release, so they need no edit.
- **openhands app**: newest OpenHands release is **v1.31.0** (2026-10-22).
  The 1.x app is SDK-based and is NOT published as a single `1.31.0`
  container under `openhands/openhands` or `all-hands-ai/openhands` (those
  are the legacy 0.x line). Build the base locally from the `v1.31.0` tag
  (`make build`) or use your fleet's derived image — the repo's
  `OPENHANDS_BASE_IMAGE=openhands:latest` local-build flow is unchanged.

### litellm — pin `1.93.2`, never `1.107.x`

Both images pull litellm via `openhands-sdk` v1.58.0, which constrains
`litellm>=1.93.0,<1.106` (1.106+ needs `mcp>=2`, breaks on mcp 1.x; see
software-agent-sdk #6088). Evidence from OSV (2026-10-22):

- **`litellm` 1.107.0 is MALICIOUS** — OSV `MAL-2026-2144` (also 1.82.7,
  1.82.8). 1.107.0 is yanked from PyPI (install → 404). **Never pin it.**
- `CVE-2026-84377` (`GHSA-3cv6-jpf6-8222`): authenticated SSRF +
  provider-credential exfiltration. Fixed on the 1.93 branch in **1.93.2**
  (mainline 1.88.6). The SDK lock target 1.93.0 and our old 1.84.0 pin are
  both still vulnerable.
- Secure+compatible window is therefore **[1.93.2, 1.106)**. We pin
  `litellm==1.93.2` (minimal bump off the SDK's own branch, fixes 84377).
  1.105.x is the newest within the cap if a newer one is ever wanted.
- Residual no-fix litellm advisories (`CVE-2026-1277x`/`1279x`) are
  authenticated-proxy issues; OpenHands uses litellm as a client library,
  so they do not apply. Accept/track like the no-fix OS CVEs.

`litellm==1.93.2` is now in both `PIP_UPGRADES_OPENHANDS` and
`PIP_UPGRADES_AGENT_SERVER` (the agent-server bundles the SDK too, so it
ships litellm and needs the same pin).

### Bundled-npm fix (agent-server overlay)

A default-on step updates the npm toolchains and ACP agent CLIs in place
rather than stripping them (the ACP agents are a product feature):

- Update bundled `npm` to `12.2.1` in both `/usr/local` and
  `/opt/acp-node` — it vendors `tar ^7.5.22`, clearing every
  `npm`-internal `tar` copy (`CVE-2026-59873`).
- Update `@google/gemini-cli` to `0.39.1` (`CVE-2026-12537` RCE).
- Refresh `proxy-addr` to `2.0.8` under `claude-agent-acp`
  (best-effort; the `POLICY_MAX_CRITICAL=0` scan gate is the backstop).

Pins are build-args (`NPM_PIN`, `GEMINI_CLI_PIN`, `PROXY_ADDR_PIN`); opt
out with `--build-arg KEEP_BUNDLED_NPM=1`. This step needs network and
could not be exercised in the authoring environment — validate on the
first Mac build; the self-fail/scan-gate catches a wrong path assumption.

### No-fix OS CVEs — decisions

These have no fixed Debian package yet; accept and track, do not strip:

- `openssh-*`/`ssh` `CVE-2026-60002` (openhands) — openssh is used for
  git-over-SSH; keep. Revisit when `trixie-security` ships a fix.
- `libxml2` `CVE-2026-6653` (agent-server) — core library, broadly
  depended on; keep.
- `linux-libc-dev` `CVE-2026-93221` (agent-server) — kernel *headers*,
  not a running kernel; negligible runtime risk. Removable if nothing
  compiles against headers at runtime, but kept by default to avoid
  breaking source builds of pip packages.

Because these are unfixable, they do NOT violate `POLICY_MAX_CRITICAL=0`
when the scan gate is run with fixed-only filtering; keep the default
(no `--ignore-unfixed`) and treat them as a documented exception.

## Known-good patterns

- **Strip unused embedded stacks** rather than chasing upstream-no-fix
  CVEs. Pattern: add `ARG STRIP_X=""` to overlay; when set, run
  `apt-get purge --auto-remove` for the unused package set.
- **Use `apt-get autoremove --purge`** after a purge so transitive
  deps come out too (this is how Mesa/X11/freedesktop libs got cleared
  in the agent-server slim variant — they were transitive of `x11-utils`).
- **`/usr/local/bin/node`** (bundled by openvscode-server, v22) is
  independent of Debian's `/usr/bin/node` (v20). Removing the system
  Node 20 does NOT break the embedded VS Code.
- **PIP_UPGRADES build-arg** already exists in both overlays for
  Python pinning. Use it for litellm / lxml / cryptography / urllib3
  type upgrades — much simpler than rebuilding Python wheels.
- **npm packages baked into `node_modules`** are harder. Either accept
  them, use npm `overrides` in a package.json patch, or remove the
  bundled tool that pulled them in.
- **`docker buildx --push` MUST include `--provenance=false`** when the
  goal is "Scout sees 0 Critical". BuildKit's default in-toto SLSA
  provenance attestation lists the BASE_IMAGE as a `resolvedDependency`
  (`pkg:docker/<base-ref>?platform=...`). Scout follows that pointer
  and indexes the **base image's** SBOM as if those packages were still
  present — so Critical CVEs you cleanly purged with apt-get get
  reported anyway. Trivy is unaffected (it scans actual layers).
  Symptom: Trivy 0C, Scout 1C+, Scout's report says
  `provenance: <git ref> <last commit SHA before push>`. Disable the
  attestation with `--provenance=false`. (We could alternatively try
  attaching a fresh image SBOM via `--attest type=sbom` but that
  requires an extra scanner pass and isn't tested in this repo.)

## Tags currently on Docker Hub

| Tag                                              | Manifest list digest        | Purpose                                              |
|--------------------------------------------------|-----------------------------|------------------------------------------------------|
| `sgireddy/openhands:custom_base`                 | `7b3e9c5d5523…`             | regular hardened                                     |
| `sgireddy/openhands:custom_base-slim`            | `d3202281ddc4…`             | strip vscode build sandbox + bump litellm/lxml       |
| `sgireddy/agent-server:custom_base`              | `8e88e6506cca…`             | regular hardened                                     |
| `sgireddy/agent-server:custom_base-1.19.1`       | `8e88e6506cca…`             | (alias of regular)                                   |
| `sgireddy/agent-server:custom_base-slim`         | `844840c105c8…`             | no chromium/VNC/Mesa + no DinD + node 22.22 symlink  |
| `sgireddy/agent-server:custom_base-slim-1.19.1`  | `844840c105c8…`             | (alias of slim)                                      |

Per-arch digests for the agent-server slim manifest list (`844840c105c8…`):
- `linux/amd64` → `sha256:0e85ee72836a…`
- `linux/arm64` → `sha256:d38788cfe77f…`

Per-arch digests for the openhands slim manifest list (`d3202281ddc4…`):
- amd64 + arm64 (same arch keys as agent-server, run
  `docker buildx imagetools inspect` for the current per-arch digests).

The openhands slim is built on top of `sgireddy/openhands:custom_base`
itself (which is already multi-arch on Hub), so the BASE_IMAGE for
the slim build is `docker.io/sgireddy/openhands:custom_base` — not the
local `openhands:latest` used for the regular `:custom_base`.

History of the slim digests (most recent first):

- agent-server slim
  - `844840c105c8…` — current. Built with `--provenance=false` so Scout
    can't follow the BASE_IMAGE provenance dep back to the upstream
    SBOM. This is what finally takes Scout to 0C.
  - `1ccb3dab9839…` — had STRIP_DIND + node fix in the layer content,
    but Scout still reported `grpc 1.78.0` because it was reading the
    BuildKit-generated SLSA provenance attestation, which lists
    `pkg:docker/ghcr.io/openhands/agent-server@1.19.1-python` as a
    dependency, and Scout followed that to the upstream SBOM (which
    DOES list grpc 1.78). Trivy was 0C on this digest because Trivy
    scans actual layers.
  - `b9dcaa5c2495…` — first slim with `STRIP_BROWSER_TOOLS=1` only.
    Trivy 0C, Scout 2C (grpc 1.78 from containerd, node 22.14 from
    `/opt/acp-node`).

- openhands slim
  - `d3202281ddc4…` — current, built with `--provenance=false`.
  - `7eaf2901c9c8…` — earlier, with provenance enabled.

## Scout vs Trivy DB drift

Scout sometimes ranks GHSA advisories Critical that NVD/OSV (Trivy's
sources) rank High. When the user reports a Critical that Trivy doesn't
see, the candidate is almost always one of:

- A `litellm` GHSA (LLM proxy → credential exposure / SSRF profile)
- An `lxml` CVE (XML parsing → XXE / RCE profile)
- A bundled npm pkg with a recent supply-chain advisory (undici, lodash,
  serialize-javascript, tar-fs, etc.)

### Known Scout false positive: `gh` reporting grpc 1.78.0

On `agent-server:custom_base-slim` (digest `844840c105c8…`), Scout
reports `pkg:golang/google.golang.org/grpc@1.78.0` Critical for
**CVE-2026-33186** (fixed in 1.79.3).

This is **wrong**. The only Go binary in the slim image is
`/usr/bin/gh` (GitHub CLI 2.92.0), and its actual Go BuildInfo says:

    dep    google.golang.org/grpc  v1.80.0 h1:Xr6m2WmWZL…

`v1.80.0` is past the fix (1.79.3), so the CVE does not apply. Trivy
reads the same BuildInfo correctly and reports 0 Critical. gh's
upstream `go.mod` and `go.sum` at v2.92.0 also confirm `v1.80.0` (no
1.78.0 anywhere in the source tree). gh embeds the grpc package's
`LICENSE` and `NOTICE.txt` as `embed.FS` data for its skill-install
feature, but the runtime dep is v1.80.0.

I haven't been able to reproduce the Scout report locally; presumably
Scout's Go scanner picks up the embedded LICENSE path
(`third-party/google.golang.org/grpc/`) and pairs it with a stale
version from its DB instead of reading the BuildInfo's `dep` line.

Workarounds for "0C in Scout" if absolutely required:
1. Wait for Scout to update its detector (recommended — there is no
   real CVE here, only a misreport).
2. `apt-get remove --purge gh` in the overlay. Loses GitHub CLI
   capability inside the agent — you can plumb the agent's GitHub
   work through the user's host gh, or use the GitHub API directly
   via `curl` + `$GITHUB_TOKEN`. This is a real product trade-off,
   not a security trade-off.
3. Replace gh with a self-built version that omits the third-party
   embed.FS. Maintenance burden.

Recommendation: keep gh and document the Scout report as a known false
positive. Trivy is authoritative for this CVE.

Cross-reference by asking the user to run from a GUI Terminal:

```
docker scout cves <image> --only-severity critical
```

…and paste the CVE/pkg/version. The fix path then forks:
- Python pkg → bump `PIP_UPGRADES_OPENHANDS` in `.env`
- npm pkg    → either npm overrides patch, strip the tool, or document.

## Conventions enforced

- Every change to `scripts/*.sh` must have an equivalent change in the
  matching `*.ps1` (behavioural equivalence, not line-for-line).
- Never commit upstream-from-source builds; only consume stable
  maintainer-published bases.
- Overlays must be idempotent: `docker build` twice in a row produces
  identical layers when nothing changed.
- The repo has `.env` and runtime artifacts gitignored. Never commit
  secrets, never commit reports/.

## How the user prefers to operate

- The agent identifies the issue and writes the fix; the user runs the
  build/push (because keychain unlock is in the user's Terminal.app).
- Multi-arch buildx commands should be one self-contained shell block
  the user can paste.
- After push, the agent re-scans **from the registry** (not local
  cache) to confirm the published artifacts are clean.
- Final commits are pushed to `main` after the registry verification
  passes; PRs only when explicitly requested.
