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

## Tags currently on Docker Hub

| Tag                                              | Manifest list digest        | Purpose                |
|--------------------------------------------------|-----------------------------|------------------------|
| `sgireddy/openhands:custom_base`                 | `7b3e9c5d5523…` *(local)*   | regular hardened       |
| `sgireddy/agent-server:custom_base`              | `8e88e6506cca…`             | regular hardened       |
| `sgireddy/agent-server:custom_base-1.19.1`       | `8e88e6506cca…`             | (alias of regular)     |
| `sgireddy/agent-server:custom_base-slim`         | `b9dcaa5c2495…`             | no chromium/VNC/Mesa   |
| `sgireddy/agent-server:custom_base-slim-1.19.1`  | `b9dcaa5c2495…`             | (alias of slim)        |

Per-arch digests for the slim manifest list:
- `linux/amd64` → `sha256:fc18673724…`
- `linux/arm64` → `sha256:0d80333bb8…`

## Scout vs Trivy DB drift

Scout sometimes ranks GHSA advisories Critical that NVD/OSV (Trivy's
sources) rank High. When the user reports a Critical that Trivy doesn't
see, the candidate is almost always one of:

- A `litellm` GHSA (LLM proxy → credential exposure / SSRF profile)
- An `lxml` CVE (XML parsing → XXE / RCE profile)
- A bundled npm pkg with a recent supply-chain advisory (undici, lodash,
  serialize-javascript, tar-fs, etc.)

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
