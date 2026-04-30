# openhands-deployment

A small, opinionated downstream deployment repo for [OpenHands](https://github.com/All-Hands-AI/OpenHands)
and the [agent-server](https://github.com/OpenHands/software-agent-sdk). It does
**not** contain any OpenHands source code — it pulls the published upstream
images, applies a thin **security hardening overlay** (OS package upgrades and
optional pinned Python upgrades), and tags the result locally for use.

> **Disclaimer.** This repository is an unofficial, third-party deployment
> wrapper. It is not affiliated with or endorsed by All-Hands AI. The
> upstream images it consumes are governed by their own licenses.

## Why

Upstream images can ship with known CVEs in their base OS packages or pinned
Python deps. Two common (and unsatisfying) responses:

1. Wait for upstream to cut a new release. Slow.
2. Fork the upstream Dockerfile. Endless merge conflicts.

This repo takes a third route: **never edit upstream**. We pull whatever
upstream publishes, layer security patches on top via two small `Dockerfile`s,
and verify the result with [Docker Scout](https://docs.docker.com/scout/).

```
upstream image  ──►  overlay (apt-get upgrade, optional pip pins)  ──►  hardened image
                                                                        │
                                                                        ▼
                                                          docker compose up -d
```

## What's in here

```
.
├── README.md
├── LICENSE                      # MIT
├── .env.example                 # template for runtime config
├── .gitignore                   # excludes .env, reports/, logs, .DS_Store, etc.
├── compose/
│   └── docker-compose.yml       # consumes the *hardened* images, not upstream
├── overlays/
│   ├── Dockerfile.openhands     # FROM ${BASE_IMAGE}; apt upgrade; optional pip
│   └── Dockerfile.agent-server  # same shape, for sandbox runtime image
└── scripts/
    ├── lib.sh                   # shared helpers
    ├── build.sh                 # pull → scan → overlay → scan → policy gate
    ├── verify.sh                # scan-only mode
    └── update.sh                # find newer upstream tags, optionally rebuild
```

## Prerequisites

- Docker Desktop (or Docker Engine ≥ 24.x) with **Docker Scout** available
  (`docker scout version`).
- macOS, Linux, or WSL2.
- **Both upstream images already present in your local Docker cache.** This
  repo does not pull or build the upstream images — that is the operator's
  job. See "Obtaining the upstream images" below.

## Obtaining the upstream images

Before running `./scripts/build.sh`, make sure both of these come back with
something:

```bash
docker image inspect openhands:latest                              >/dev/null && echo openhands OK
docker image inspect ghcr.io/openhands/agent-server:1.19.0-python  >/dev/null && echo agent-server OK
```

If either is missing:

**`openhands:latest`** is built from the OpenHands source repository:

```bash
git clone https://github.com/All-Hands-AI/OpenHands.git
cd OpenHands
make build      # produces local image: openhands:latest
```

If your fleet publishes OpenHands to its own registry, you can override
`OPENHANDS_BASE_IMAGE`/`OPENHANDS_BASE_TAG` in `.env` and `docker pull`
that instead.

**`ghcr.io/openhands/agent-server:<version>-python`** is published publicly
on GHCR by the [software-agent-sdk](https://github.com/OpenHands/software-agent-sdk)
project. Each SDK GitHub release `vX.Y.Z` produces a corresponding image
tag `X.Y.Z-python`. No login required:

```bash
docker pull ghcr.io/openhands/agent-server:1.19.0-python
```

### Versioning policy

> **Track the latest stable SDK release.** Deviate only when justified —
> e.g., when a critical CVE in the latest stable forces you to hold or
> jump to a non-stable hotfix.

The default in `.env.example` is pinned (not floating) so that
`./scripts/build.sh` produces a deterministic `:custom_base`. The pin
should still be kept current; that's what `update.sh` and the drift
warnings exist for.

```bash
./scripts/verify.sh --check-pin    # exit 0 in sync, 1 drift, 3 offline
                                   # — fast, no Docker, suitable for cron
./scripts/update.sh                # informational: print current vs newest
./scripts/update.sh --apply        # bump AGENT_SERVER_BASE_TAG and rebuild
```

`build.sh` and `verify.sh` print a one-line drift banner at the top of
every run. It's never a build blocker, just visibility:

```
[ OK ] agent-server pin is on latest stable (1.19.0-python)
# or
[WARN] agent-server pin DRIFT: current=1.18.1-python  latest-stable=1.19.0-python
[WARN]   policy: track latest stable. Bump unless a known regression justifies holding.
[WARN]   to update: ./scripts/update.sh --apply
```

Discovery uses the `software-agent-sdk` [GitHub releases API](https://api.github.com/repos/OpenHands/software-agent-sdk/releases/latest)
as the authoritative source — that endpoint already excludes prereleases
and drafts, so we only ever propose stable bumps. The GHCR tags/list
endpoint isn't usable for this (~20k commit-SHA tags drown out semver).

### Automation (optional)

Pick whatever fits your environment:

| Mechanism | Setup | Cost |
|---|---|---|
| **Mac local cron** | `crontab -e`, add weekly call to `verify.sh --check-pin`, pipe to `osascript` for a notification or to email | $0, runs only on your laptop |
| **GitHub Actions** | Add a weekly `schedule:` workflow that runs `--check-pin` and opens a PR if drift > 0 | $0 — Actions is **free with no minute cap on public repos** ([docs](https://docs.github.com/en/billing/managing-billing-for-your-products/managing-billing-for-github-actions/about-billing-for-github-actions)) |
| **Manual** | Run `./scripts/update.sh` whenever you remember | $0 |

A reference Actions workflow can be added later if wanted; not included
by default to keep the repo dependency-free.

## Quick start

```bash
git clone https://github.com/sgireddy/openhands-deployment.git
cd openhands-deployment

# 1. (optional) Override defaults — image tags, scan policy, etc.
#    Skip this if the defaults in .env.example are fine; build.sh works
#    without an .env file at all.
cp .env.example .env
$EDITOR .env

# 2. Build & verify the hardened images. Needs Docker + Scout only.
#    No LLM credentials, no GitHub auth, nothing else required —
#    but both upstream images must already be cached locally
#    (see "Obtaining the upstream images" above).
./scripts/build.sh

# 3. To actually run OpenHands, set runtime secrets in .env first
#    (LLM_API_KEY, LLM_MODEL, LLM_BASE_URL) — these are read at compose-up,
#    not at build-time.
docker compose -f compose/docker-compose.yml --env-file .env up -d
# → http://localhost:3000
```

`build.sh` exits non-zero if the post-overlay image still violates policy
(`POLICY_MAX_CRITICAL` from `.env`, default `0`). Reports for each run land
under `reports/<UTC-timestamp>/` (gitignored).

## Configuration

All knobs live in `.env`. Defaults are visible in `.env.example`.

| Variable | Default | Purpose |
|---|---|---|
| `OPENHANDS_BASE_IMAGE`        | `openhands`                                    | Local image name (built via `make build`). Override to point at your registry. |
| `OPENHANDS_BASE_TAG`          | `latest`                                       | Tag of the upstream OpenHands image |
| `AGENT_SERVER_BASE_IMAGE`     | `ghcr.io/openhands/agent-server`               | Upstream agent-server repo |
| `AGENT_SERVER_BASE_TAG`       | `1.19.0-python`                                | Upstream tag to pull |
| `OPENHANDS_OUT_IMAGE/TAG`     | `openhands:custom_base`                        | Locally-built hardened image |
| `AGENT_SERVER_OUT_IMAGE/TAG`  | `agent-server:custom_base`                     | Locally-built hardened image |
| `HOST_PORT`                   | `3000`                                         | Host port for the web UI |
| `WORKSPACE_BASE`              | `./workspace`                                  | Mounted into the orchestrator and sandboxes |
| `POLICY_MAX_CRITICAL`         | `0`                                            | Max allowed CRITICAL CVEs after overlay |
| `POLICY_MAX_HIGH`             | *(unbounded)*                                  | Max allowed HIGH CVEs (empty = no limit) |
| `PIP_UPGRADES_OPENHANDS`      | *(empty)*                                      | Whitespace-separated pip specs to upgrade in the overlay |
| `PIP_UPGRADES_AGENT_SERVER`   | *(empty)*                                      | Same, for agent-server |
| `LLM_API_KEY`, `LLM_MODEL`, `LLM_BASE_URL` | *(empty)*                         | Read by the orchestrator at runtime |

## Common workflows

### Rebuild only one image
```bash
./scripts/build.sh openhands
./scripts/build.sh agent-server
```

### Scan only, no build
```bash
./scripts/verify.sh                     # the hardened images
./scripts/verify.sh --upstream          # the raw upstream images
```

### Upgrade specific Python packages in the overlay
Set in `.env`:
```bash
PIP_UPGRADES_AGENT_SERVER="urllib3==2.5.0 cryptography==45.0.0"
```
Then `./scripts/build.sh agent-server`.

### Bump to newer upstream tags
```bash
./scripts/update.sh                     # list newer tags (read-only)
./scripts/update.sh --apply             # bump .env and rebuild
```

### Check what changed between baseline and hardened
```bash
ls reports/                             # latest run is at the bottom
diff -u reports/<latest>/openhands-01-baseline-quickview.txt \
        reports/<latest>/openhands-02-post-overlay-quickview.txt
```

## Security notes

- `.env` is gitignored. Never commit secrets.
- `reports/` is gitignored. Scout output for *public* images is itself public
  info, but keeping it out of git avoids accidental leakage if you later
  point the overlays at a private registry.
- The overlays themselves contain no credentials and produce no auth state.
- Use SSH (`git@github.com:...`) or `credential.helper=osxkeychain` for the
  `origin` remote — never put a token in the URL.

## Limitations

- An overlay can only fix CVEs whose patches are available in **package
  metadata** (apt or pip). If a CVE lives in an old binary not managed by
  apt/pip (e.g. a bundled chromium), the overlay cannot patch it; bumping
  the upstream tag is the only fix. Use `update.sh` to discover those bumps.
- Image size grows by one layer per overlay. Periodically re-baseline by
  bumping to a newer upstream tag — the `update.sh` script automates this.
- Scout's auto-detected base image may not exactly match the upstream tag
  (it picks the closest published digest). For deterministic provenance,
  build upstream with `--provenance=mode=max`.

## Contributing

PRs welcome. Keep the overlays minimal — anything that requires source-level
changes belongs in the upstream OpenHands or software-agent-sdk repo.

## License

MIT — see [LICENSE](LICENSE).
