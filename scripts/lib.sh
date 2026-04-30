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
require_tools() {
    command -v docker >/dev/null \
        || { err "docker not on PATH"; exit 1; }
    docker info >/dev/null 2>&1 \
        || { err "Docker daemon not reachable"; exit 1; }
    if ! docker scout version >/dev/null 2>&1; then
        err "Docker Scout CLI not available."
        err "  Install via Docker Desktop, or:"
        err "  curl -sSfL https://raw.githubusercontent.com/docker/scout-cli/main/install.sh | sh -s --"
        exit 1
    fi
}

# --- scout helpers ----------------------------------------------------------
# Run quickview + cves for an image, save outputs under reports/<run>/<label>.
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

# Apply policy: $1 = critical count, $2 = high count.
# Exits 2 if violated. Stdout: "PASS" or "FAIL: <reason>".
policy_check() { # $1 critical, $2 high
    local crit="$1" high="$2"
    if [[ "$crit" == "n/a" ]]; then
        echo "UNKNOWN: could not parse scout output"; return 0
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
