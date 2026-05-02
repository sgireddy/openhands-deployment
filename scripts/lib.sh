#!/usr/bin/env bash
# scripts/lib.sh — shared helpers for build.sh / verify.sh / update.sh.
# Sourced, never executed directly.

# --- color logging ----------------------------------------------------------
if [[ -t 1 ]]; then
    C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'
    C_RED=$'\033[31m';  C_GRN=$'\033[32m'
    C_YEL=$'\033[33m';  C_BLU=$'\033[34m'; C_CYN=$'\033[36m'
else
    C_RESET=""; C_BOLD=""; C_RED=""; C_GRN=""; C_YEL=""; C_BLU=""; C_CYN=""
fi
log()  { printf "%s[%s]%s %s\n"   "$C_BLU" "$(date +%H:%M:%S)" "$C_RESET" "$*"; }
ok()   { printf "%s[ OK ]%s %s\n" "$C_GRN" "$C_RESET" "$*"; }
warn() { printf "%s[WARN]%s %s\n" "$C_YEL" "$C_RESET" "$*" >&2; }
err()  { printf "%s[ERR ]%s %s\n" "$C_RED" "$C_RESET" "$*" >&2; }
hdr()  { printf "\n%s==> %s%s\n"  "$C_BOLD$C_CYN" "$*" "$C_RESET"; }

confirm() {
    local prompt="${1:-Proceed?}"
    [[ "${ASSUME_YES:-0}" == "1" ]] && return 0
    read -r -p "$prompt [y/N] " ans
    [[ "$ans" =~ ^[Yy]$ ]]
}

# --- agent-server pin drift -------------------------------------------------
# Policy: pin should track the latest stable software-agent-sdk release.
# Deviation is acceptable only when justified (e.g., a critical CVE in the
# latest stable forces a hold or a jump to a non-stable hotfix).
#
# This helper queries the SDK GitHub releases API for the latest *stable*
# release (the /releases/latest endpoint already excludes prereleases and
# drafts) and compares it to AGENT_SERVER_BASE_TAG. It prints one of three
# tokens to stdout, suitable for capture:
#   IN_SYNC      — pin matches latest stable
#   DRIFT:<tag>  — pin is behind; <tag> is what latest stable maps to
#   UNKNOWN      — couldn't reach GitHub (offline, rate-limited, etc.)
#
# Diagnostics go to stderr via warn/log so callers can show or hide them.
agent_server_drift() {
    local hdr_args=()
    [[ -n "${GITHUB_TOKEN:-}" ]] && hdr_args=(-H "Authorization: Bearer $GITHUB_TOKEN")
    local sdk_tag
    sdk_tag="$(curl -fsSL --max-time 5 "${hdr_args[@]}" \
        -H "Accept: application/vnd.github+json" \
        "https://api.github.com/repos/OpenHands/software-agent-sdk/releases/latest" 2>/dev/null \
        | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("tag_name",""))
except Exception: pass' 2>/dev/null)"
    if [[ -z "$sdk_tag" ]]; then
        echo "UNKNOWN"
        return 0
    fi
    local expected="${sdk_tag#v}-python"
    if [[ "$expected" == "${AGENT_SERVER_BASE_TAG:-}" ]]; then
        echo "IN_SYNC"
    else
        echo "DRIFT:$expected"
    fi
}

# Print a one-line drift summary suitable for build.sh / verify.sh banners.
# Always returns 0 — drift is informational, not a failure mode.
report_drift() {
    local drift; drift="$(agent_server_drift)"
    case "$drift" in
        IN_SYNC)
            ok "agent-server pin is on latest stable (${AGENT_SERVER_BASE_TAG})" ;;
        DRIFT:*)
            local newer="${drift#DRIFT:}"
            warn "agent-server pin DRIFT: current=${AGENT_SERVER_BASE_TAG}  latest-stable=${newer}"
            warn "  policy: track latest stable. Bump unless a known regression justifies holding."
            warn "  to update: ./scripts/update.sh --apply" ;;
        UNKNOWN)
            warn "could not reach github.com to check pin drift (offline / rate-limited?)" ;;
    esac
    return 0
}

# --- env loading ------------------------------------------------------------
# Loads .env from REPO_ROOT, then applies defaults for any unset variable so
# scripts work even with no .env at all.
load_env() {
    if [[ -f "$REPO_ROOT/.env" ]]; then
        # shellcheck disable=SC1091
        set -a; . "$REPO_ROOT/.env"; set +a
    fi
    : "${OPENHANDS_BASE_IMAGE:=openhands}"
    : "${OPENHANDS_BASE_TAG:=latest}"
    : "${AGENT_SERVER_BASE_IMAGE:=ghcr.io/openhands/agent-server}"
    : "${AGENT_SERVER_BASE_TAG:=1.19.0-python}"
    : "${OPENHANDS_OUT_IMAGE:=openhands}"
    : "${OPENHANDS_OUT_TAG:=custom_base}"
    : "${AGENT_SERVER_OUT_IMAGE:=agent-server}"
    : "${AGENT_SERVER_OUT_TAG:=custom_base}"
    : "${POLICY_MAX_CRITICAL:=0}"
    : "${POLICY_MAX_HIGH:=}"
    : "${PIP_UPGRADES_OPENHANDS:=}"
    : "${PIP_UPGRADES_AGENT_SERVER:=}"
}

# --- pre-flight -------------------------------------------------------------
# Selects a CVE scanner. SCANNER env can be set to force one of {scout, trivy};
# default `auto` prefers Docker Scout (richer output, base-image suggestions),
# falls back to Trivy if Scout isn't installed. Trivy is also the right choice
# in non-interactive contexts (CI, cron, SSH-without-keychain) where Scout's
# Docker Hub login requirement gets in the way.
#
# Sets the global SCANNER to the chosen tool. Exits 1 if neither is usable.
require_tools() {
    command -v docker >/dev/null \
        || { err "docker not on PATH"; exit 1; }
    docker info >/dev/null 2>&1 \
        || { err "Docker daemon not reachable"; exit 1; }

    local want="${SCANNER:-auto}"
    case "$want" in
        scout)
            docker scout version >/dev/null 2>&1 \
                || { err "SCANNER=scout but Docker Scout CLI not available"; exit 1; }
            SCANNER=scout ;;
        trivy)
            command -v trivy >/dev/null \
                || { err "SCANNER=trivy but trivy not on PATH (brew install trivy)"; exit 1; }
            SCANNER=trivy ;;
        auto)
            if docker scout version >/dev/null 2>&1; then
                SCANNER=scout
            elif command -v trivy >/dev/null; then
                SCANNER=trivy
            else
                err "No CVE scanner found. Install one of:"
                err "  - Docker Scout (Docker Desktop, or: curl -sSfL https://raw.githubusercontent.com/docker/scout-cli/main/install.sh | sh -s --)"
                err "  - Trivy       (brew install trivy, or https://aquasecurity.github.io/trivy/)"
                exit 1
            fi ;;
        *)
            err "SCANNER=$want is not one of {auto, scout, trivy}"; exit 1 ;;
    esac
    export SCANNER
    log "Scanner: $SCANNER"
}

# --- scan helpers (Scout + Trivy) -------------------------------------------
# Both back-ends produce three files under $run_dir with these stable names so
# build.sh / verify.sh don't care which scanner ran:
#   <label>-quickview.txt           one-liner suitable for human eyes
#   <label>-cves-critical-high.txt  full critical/high CVE listing
#   <label>-pkgs-critical-high.txt  vulnerable-packages-only listing
#
# `scan_image` dispatches; `scan_counts` parses the quickview to "<crit>:<high>".

# Public entry points -------------------------------------------------------

scan_image() { # $1 = image, $2 = label, $3 = run_dir
    case "${SCANNER:-scout}" in
        trivy) trivy_scan "$@" ;;
        *)     scout_scan "$@" ;;
    esac
}

scan_counts() { # $1 = quickview file
    case "${SCANNER:-scout}" in
        trivy) trivy_counts "$@" ;;
        *)     scout_counts "$@" ;;
    esac
}

# Scout back-end ------------------------------------------------------------

scout_scan() { # $1 = image, $2 = label, $3 = run_dir
    local image="$1" label="$2" run_dir="$3"
    mkdir -p "$run_dir"
    hdr "Scout scan: $label  ($image)"
    docker scout quickview "$image" 2>&1 \
        | tee "$run_dir/${label}-quickview.txt"
    docker scout cves "$image" --only-severity critical,high 2>&1 \
        > "$run_dir/${label}-cves-critical-high.txt" || true
    docker scout cves "$image" \
        --only-severity critical,high --format only-packages 2>&1 \
        > "$run_dir/${label}-pkgs-critical-high.txt" || true
    log "Saved: $run_dir/${label}-{quickview,cves-critical-high,pkgs-critical-high}.txt"
}

# Parse "Target | <image> | NC NH NM NL" → emit "<critical>:<high>" or "n/a:n/a".
scout_counts() { # $1 = quickview file
    local f="$1"
    [[ -f "$f" ]] || { echo "n/a:n/a"; return; }
    awk '
        /Target/ {
            for (i=1; i<=NF; i++) {
                if ($i ~ /^[0-9]+C$/ && $(i+1) ~ /^[0-9]+H$/) {
                    c=$i; h=$(i+1); gsub(/C/,"",c); gsub(/H/,"",h);
                    print c ":" h; exit
                }
            }
        }
    ' "$f" 2>/dev/null || echo "n/a:n/a"
}

# Trivy back-end ------------------------------------------------------------
# Trivy reports every fixable critical/high; we mirror Scout's defaults:
#   --ignore-unfixed   (Scout's policy gate counts only fixable CVEs)
#   --scanners vuln    (no secret/license scanning; we just want CVEs here)

trivy_scan() { # $1 = image, $2 = label, $3 = run_dir
    local image="$1" label="$2" run_dir="$3"
    mkdir -p "$run_dir"
    hdr "Trivy scan: $label  ($image)"
    local json="$run_dir/${label}-trivy.json"
    # JSON for machine parsing (counts), table for human-readable reports.
    trivy image --quiet \
        --severity CRITICAL,HIGH --ignore-unfixed --scanners vuln \
        --pkg-types library,os --format json --output "$json" "$image" \
        || { err "[trivy] scan failed for $image"; return 1; }
    trivy image --quiet \
        --severity CRITICAL,HIGH --ignore-unfixed --scanners vuln \
        --pkg-types library,os --format table "$image" \
        > "$run_dir/${label}-cves-critical-high.txt" 2>&1 || true
    # Build a quickview line in Scout-compatible "NC NH" shape so any external
    # tooling that grep'd the previous format keeps working.
    python3 - "$json" "$image" > "$run_dir/${label}-quickview.txt" <<'PY' || true
import json, sys
path, image = sys.argv[1], sys.argv[2]
try:
    d = json.load(open(path))
except Exception:
    print(f"  Target  |  {image}  |  n/aC n/aH"); sys.exit(0)
crit = high = 0
for r in d.get("Results", []) or []:
    for v in r.get("Vulnerabilities", []) or []:
        s = (v.get("Severity") or "").upper()
        if   s == "CRITICAL": crit += 1
        elif s == "HIGH":     high += 1
print(f"  Target  |  {image}  |  {crit}C {high}H 0M 0L 0?")
PY
    # Vulnerable packages only — concise input for PIP_UPGRADES authoring.
    python3 - "$json" > "$run_dir/${label}-pkgs-critical-high.txt" <<'PY' || true
import json, sys, collections
d = json.load(open(sys.argv[1]))
seen = collections.OrderedDict()
for r in d.get("Results", []) or []:
    klass = r.get("Class", "?"); typ = r.get("Type", "?")
    for v in r.get("Vulnerabilities", []) or []:
        key = (klass, typ, v.get("PkgName"), v.get("InstalledVersion"))
        seen.setdefault(key, v.get("FixedVersion") or "")
for (klass, typ, pkg, ver), fix in seen.items():
    print(f"[{klass}/{typ}] {pkg} {ver}  -> fixed by {fix}")
PY
    log "Saved: $run_dir/${label}-{quickview,cves-critical-high,pkgs-critical-high,trivy.json}"
}

# Parse our trivy-quickview line (same shape as Scout's) → "<critical>:<high>".
trivy_counts() { # $1 = quickview file
    local f="$1"
    [[ -f "$f" ]] || { echo "n/a:n/a"; return; }
    awk '
        /Target/ {
            for (i=1; i<=NF; i++) {
                if ($i ~ /^[0-9]+C$/ && $(i+1) ~ /^[0-9]+H$/) {
                    c=$i; h=$(i+1); gsub(/C/,"",c); gsub(/H/,"",h);
                    print c ":" h; exit
                }
            }
        }
    ' "$f" 2>/dev/null || echo "n/a:n/a"
}

# Apply policy: $1 = critical count, $2 = high count.
# Exits 2 if violated. Stdout: "PASS" or "FAIL: <reason>".
policy_check() { # $1 critical, $2 high
    local crit="$1" high="$2"
    if [[ "$crit" == "n/a" ]]; then
        echo "UNKNOWN: could not parse scanner output"; return 0
    fi
    if (( crit > POLICY_MAX_CRITICAL )); then
        echo "FAIL: $crit CRITICAL > policy limit $POLICY_MAX_CRITICAL"; return 2
    fi
    if [[ -n "$POLICY_MAX_HIGH" ]] && (( high > POLICY_MAX_HIGH )); then
        echo "FAIL: $high HIGH > policy limit $POLICY_MAX_HIGH"; return 2
    fi
    echo "PASS: $crit CRITICAL / $high HIGH within policy"
    return 0
}

# --- output redaction -------------------------------------------------------
# Strip GitHub PATs from any text we tee/log. (Defense in depth — scripts do
# not knowingly print URLs, but `git remote -v` etc. could be added later.)
redact_secrets() {
    sed -E 's/(github_pat_|gh[ps]_|ghu_|ghr_|gho_)[A-Za-z0-9_]+/\1***REDACTED***/g'
}
