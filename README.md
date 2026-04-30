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
├── scripts/
│   ├── lib.sh / lib.ps1         # shared helpers (bash / PowerShell)
│   ├── build.sh / build.ps1     # scan → overlay → scan → policy gate
│   ├── verify.sh / verify.ps1   # scan-only mode + --check-pin
│   └── update.sh / update.ps1   # find newer SDK release, optionally rebuild
└── examples/
    └── run-openhands.sh         # reference invocation that wires the
                                 # hardened openhands + agent-server images
                                 # together via AGENT_SERVER_IMAGE_REPOSITORY/TAG
```

The **bash** scripts (`*.sh`) and **PowerShell** scripts (`*.ps1`) are
behaviourally equivalent ports of one another; same flags, same exit
codes, same reports. Pick whichever your shell prefers.

## Prerequisites

- Docker Desktop (or Docker Engine ≥ 24.x) with **Docker Scout** available
  (`docker scout version`).
- One of:
  - **macOS** — bash scripts work as-is.
  - **Linux** (incl. **WSL2 Ubuntu**) — bash scripts work as-is.
  - **Windows** — either run the bash scripts inside WSL2 (recommended,
    same code path as Linux) **or** run the native PowerShell scripts
    (`build.ps1`, `verify.ps1`, `update.ps1`) under PowerShell 7+.
- **Both upstream images already present in your local Docker cache.** This
  repo does not pull or build the upstream images — that is the operator's
  job. See "Obtaining the upstream images" below.

### Platform notes

**macOS.** Tested with Docker Desktop on Apple Silicon. No extra setup.

**Linux / WSL2 Ubuntu.** Install Docker Engine + the scout plugin (or use
Docker Desktop on WSL2). For WSL2, ensure Docker Desktop's WSL integration
is enabled for your distro (Settings → Resources → WSL integration), then
run the bash scripts from inside the WSL shell:
```bash
sudo apt-get update && sudo apt-get install -y curl python3
docker scout version       # verify
./scripts/build.sh
```

**Windows (native, no WSL).** Install
[PowerShell 7+](https://learn.microsoft.com/en-us/powershell/scripting/install/installing-powershell-on-windows)
and Docker Desktop for Windows. Allow script execution if you haven't
already (one-time, per-user):
```powershell
Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned
```
Then from the repo root in PowerShell:
```powershell
.\scripts\build.ps1
.\scripts\verify.ps1 -CheckPin
.\scripts\update.ps1 -Apply
```

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

Goal: notice drift early without having to remember. The scripts'
`--check-pin` / `-CheckPin` mode is fast (no Docker, two HTTP calls) and
returns a clean exit code — exactly what schedulers want.

| Platform | Mechanism | Cost |
|---|---|---|
| macOS / Linux / WSL | user **cron** (or systemd-timer / launchd) | $0 |
| Windows native | **Task Scheduler** (PowerShell `Register-ScheduledTask`) | $0 |
| Any (cloud-side) | **GitHub Actions** scheduled workflow | $0 — Actions is **free with no minute cap on public repos** ([docs](https://docs.github.com/en/billing/managing-billing-for-your-products/managing-billing-for-github-actions/about-billing-for-github-actions)) |

#### macOS — `crontab` + `osascript` notification

```bash
# crontab -e
# Mondays at 09:00 local. cd is required because the script reads ./.env.
0 9 * * 1 cd "$HOME/projects/openhands-deployment" && \
  ./scripts/verify.sh --check-pin >> /tmp/oh-deploy-pin.log 2>&1 || \
  /usr/bin/osascript -e 'display notification "Run ./scripts/update.sh --apply" with title "OpenHands agent-server pin drift"'
```

Test the notification path immediately (without waiting for Monday):
```bash
cd ~/projects/openhands-deployment && ./scripts/verify.sh --check-pin; echo "exit=$?"
```

If you'd rather use **launchd** (better suited to laptops that may be
asleep at 09:00), drop a plist into `~/Library/LaunchAgents/`:

```xml
<!-- ~/Library/LaunchAgents/com.openhands.deployment.checkpin.plist -->
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>             <string>com.openhands.deployment.checkpin</string>
  <key>ProgramArguments</key>
    <array>
      <string>/bin/bash</string>
      <string>-c</string>
      <string>cd "$HOME/projects/openhands-deployment" &amp;&amp; ./scripts/verify.sh --check-pin || /usr/bin/osascript -e 'display notification "Run ./scripts/update.sh --apply" with title "OpenHands pin drift"'</string>
    </array>
  <key>StartCalendarInterval</key>
    <dict>
      <key>Weekday</key> <integer>1</integer>
      <key>Hour</key>    <integer>9</integer>
      <key>Minute</key>  <integer>0</integer>
    </dict>
  <key>RunAtLoad</key>         <false/>
  <key>StandardOutPath</key>   <string>/tmp/oh-deploy-pin.log</string>
  <key>StandardErrorPath</key> <string>/tmp/oh-deploy-pin.log</string>
</dict>
</plist>
```

Load it: `launchctl load ~/Library/LaunchAgents/com.openhands.deployment.checkpin.plist`.

#### Linux / WSL2 — `crontab` + `notify-send` (or just a log)

```bash
# crontab -e
0 9 * * 1 cd "$HOME/projects/openhands-deployment" && \
  ./scripts/verify.sh --check-pin >> /tmp/oh-deploy-pin.log 2>&1 || \
  notify-send "OpenHands pin drift" "Run ./scripts/update.sh --apply"
```

On WSL2, `notify-send` may not work without extra setup (libnotify isn't
wired to Windows toast by default). Two simpler options that just work:

- Append to a log file you `cat` when you log in (the `>> /tmp/oh-deploy-pin.log`
  above already does this).
- Pipe to `powershell.exe` from WSL to raise a Windows toast — see the
  Windows section below for the toast snippet, then call it as
  `powershell.exe -File ...` from cron.

If you use **systemd timers** instead of cron:

```ini
# ~/.config/systemd/user/oh-checkpin.service
[Service]
Type=oneshot
WorkingDirectory=%h/projects/openhands-deployment
ExecStart=%h/projects/openhands-deployment/scripts/verify.sh --check-pin

# ~/.config/systemd/user/oh-checkpin.timer
[Unit]
Description=Weekly OpenHands agent-server pin drift check
[Timer]
OnCalendar=Mon 09:00
Persistent=true
[Install]
WantedBy=timers.target
```

Enable: `systemctl --user enable --now oh-checkpin.timer`.

#### Windows — Task Scheduler via PowerShell

Run **once** in an elevated PowerShell to register a weekly task that
runs `verify.ps1 -CheckPin` and shows a Windows toast on drift:

```powershell
$repo = "$HOME\projects\openhands-deployment"   # adjust to your path

$cmd = @"
Set-Location '$repo'
& '$repo\scripts\verify.ps1' -CheckPin
if (`$LASTEXITCODE -eq 1) {
    # Drift -> toast notification
    [Windows.UI.Notifications.ToastNotificationManager,Windows.UI.Notifications,ContentType=WindowsRuntime] | Out-Null
    [Windows.Data.Xml.Dom.XmlDocument,Windows.Data.Xml.Dom.XmlDocument,ContentType=WindowsRuntime] | Out-Null
    `$xml = New-Object Windows.Data.Xml.Dom.XmlDocument
    `$xml.LoadXml('<toast><visual><binding template="ToastGeneric"><text>OpenHands pin drift</text><text>Run .\scripts\update.ps1 -Apply</text></binding></visual></toast>')
    `$toast = New-Object Windows.UI.Notifications.ToastNotification `$xml
    [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier('OpenHands').Show(`$toast)
}
"@

$action  = New-ScheduledTaskAction `
    -Execute 'pwsh.exe' `
    -Argument "-NoProfile -Command `"$cmd`""
$trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Monday -At 9am
Register-ScheduledTask -TaskName 'OpenHands-PinDrift' `
    -Action $action -Trigger $trigger -Description 'Weekly drift check'
```

Test it once without waiting for Monday:
```powershell
Start-ScheduledTask -TaskName 'OpenHands-PinDrift'
Get-ScheduledTaskInfo -TaskName 'OpenHands-PinDrift' | Select-Object LastRunTime, LastTaskResult
```

#### GitHub Actions (cloud-side, optional)

A weekly workflow that runs `verify.sh --check-pin` and opens a PR when
drift is detected. Not enabled by default; add as `.github/workflows/check-pin.yml`
when you want it. Free for this public repo.

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
under `$HOME/openhands-deployment/reports/<UTC-timestamp>/` — see *Local
on-disk layout* below.

## Local on-disk layout

By design, **nothing in this repo writes runtime state inside the cloned
working tree**. All script-generated artifacts and runtime data default to
a single parent under your home directory:

```
$HOME/openhands-deployment/
├── reports/<UTC-timestamp>/    # build.sh / verify.sh scout output
├── workspace/                  # WORKSPACE_BASE for compose (sandbox files)
├── data/                       # examples/run-openhands.sh container state
└── openhands.log               # examples/run-openhands.sh container log
```

This is intentional defense-in-depth:

1. Defaults point outside the repo so accidents (like `git add -A` after a
   long session, or an IDE auto-staging files) cannot stage runtime data
   that may include API keys, session tokens, conversation prompts, or
   code the agent generated.
2. The repo's `.gitignore` is *also* configured to exclude `reports/`,
   `workspace/`, `data/`, `*.log`, etc. as a backstop — so even if you
   override a default back inside the tree (e.g. `WORKSPACE_BASE=./ws`),
   nothing leaks.

Override env vars (any subset):

| Variable | Default | Used by |
|---|---|---|
| `REPORTS_DIR` | `$HOME/openhands-deployment/reports` | `scripts/build.{sh,ps1}`, `scripts/verify.{sh,ps1}` |
| `WORKSPACE_BASE` | `$HOME/openhands-deployment/workspace` | `compose/docker-compose.yml` |
| `DEPLOY_HOME` | `$HOME/openhands-deployment` | `examples/run-openhands.sh` (groups `data/` and `openhands.log` under one parent) |

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
| `WORKSPACE_BASE`              | `${HOME}/openhands-deployment/workspace`       | Mounted into the orchestrator and sandboxes. Always use an absolute path; see *Local on-disk layout*. |
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
REPORTS="${REPORTS_DIR:-$HOME/openhands-deployment/reports}"
ls "$REPORTS"                           # latest run is at the bottom
LATEST="$(ls "$REPORTS" | tail -1)"
diff -u "$REPORTS/$LATEST/openhands-01-baseline-quickview.txt" \
        "$REPORTS/$LATEST/openhands-02-post-overlay-quickview.txt"
```

## Security notes

- **Defaults write outside the repo.** All script-generated artifacts and
  runtime data land under `$HOME/openhands-deployment/` by default — see
  *Local on-disk layout*. The repo's `.gitignore` is a *second* line of
  defence in case an operator overrides defaults back inside the tree.
- `.env` is gitignored. Never commit secrets.
- The overlays themselves contain no credentials and produce no auth state.
- Use SSH (`git@github.com:...`) or `credential.helper=osxkeychain` for the
  `origin` remote — never put a token in the URL.
- If you ever need to inspect the runtime state directory, remember the
  log file (`$DEPLOY_HOME/openhands.log`) can contain prompt/response
  payloads when `LOG_LEVEL=DEBUG` is set, which may incidentally include
  secrets. Treat it as sensitive even though it lives outside the repo.

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
