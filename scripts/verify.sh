#!/usr/bin/env bash
# scripts/verify.sh — scan-only, no build, no pull.
#
# Useful for re-checking already-built hardened images, or for sanity-checking
# raw upstream images before deciding to overlay them.
#
# Usage:
#   ./scripts/verify.sh                    # scan both hardened images
#   ./scripts/verify.sh --upstream         # scan upstream images instead
#   ./scripts/verify.sh openhands          # one component
#   ./scripts/verify.sh agent-server       # one component
#   ./scripts/verify.sh --check-pin        # NO scan; just check pin drift
#                                            against latest stable SDK release
#
# Exit codes:
#   0 = within policy / pin in sync
#   1 = pin drift detected (--check-pin only)
#   2 = policy violation
#   3 = drift check could not reach GitHub (--check-pin only)

set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib.sh
. "$REPO_ROOT/scripts/lib.sh"

COMPONENTS=()
SCAN_TARGET=hardened
CHECK_PIN_ONLY=0
while (( $# )); do
    case "$1" in
        openhands|agent-server) COMPONENTS+=("$1"); shift ;;
        --upstream)             SCAN_TARGET=upstream; shift ;;
        --hardened)             SCAN_TARGET=hardened; shift ;;
        --check-pin)            CHECK_PIN_ONLY=1; shift ;;
        -h|--help)
            awk 'NR>1 && /^#/ {sub(/^# ?/,""); print; next} {exit}' "$0"
            exit 0 ;;
        *) err "unknown arg: $1"; exit 1 ;;
    esac
done
(( ${#COMPONENTS[@]} == 0 )) && COMPONENTS=(openhands agent-server)

load_env

# --check-pin is a fast, no-Docker drift check. Useful for cron / CI.
if (( CHECK_PIN_ONLY )); then
    drift="$(agent_server_drift)"
    case "$drift" in
        IN_SYNC)
            ok "agent-server pin in sync with latest stable (${AGENT_SERVER_BASE_TAG})"
            exit 0 ;;
        DRIFT:*)
            err "agent-server pin DRIFT: current=${AGENT_SERVER_BASE_TAG}  latest-stable=${drift#DRIFT:}"
            exit 1 ;;
        UNKNOWN)
            warn "could not reach github.com to check drift"
            exit 3 ;;
    esac
fi

require_tools
report_drift

# See note in build.sh about why REPORTS_DIR defaults outside the repo.
REPORTS_DIR="${REPORTS_DIR:-$HOME/openhands-deployment/reports}"
RUN_DIR="$REPORTS_DIR/verify-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$RUN_DIR"

resolve_image() {
    case "$1:$SCAN_TARGET" in
        openhands:upstream)       echo "${OPENHANDS_BASE_IMAGE}:${OPENHANDS_BASE_TAG}" ;;
        openhands:hardened)       echo "${OPENHANDS_OUT_IMAGE}:${OPENHANDS_OUT_TAG}" ;;
        agent-server:upstream)    echo "${AGENT_SERVER_BASE_IMAGE}:${AGENT_SERVER_BASE_TAG}" ;;
        agent-server:hardened)    echo "${AGENT_SERVER_OUT_IMAGE}:${AGENT_SERVER_OUT_TAG}" ;;
    esac
}

exit_code=0
for comp in "${COMPONENTS[@]}"; do
    image="$(resolve_image "$comp")"
    docker image inspect "$image" >/dev/null 2>&1 || {
        warn "[$comp] image not present locally: $image (skipping)"
        continue
    }

    scout_scan "$image" "${comp}-${SCAN_TARGET}" "$RUN_DIR"
    counts="$(scout_counts "$RUN_DIR/${comp}-${SCAN_TARGET}-quickview.txt")"
    crit="${counts%%:*}"; high="${counts##*:}"
    log "[$comp] $SCAN_TARGET ($image) : ${crit}C / ${high}H"

    verdict="$(policy_check "$crit" "$high")" || exit_code=2
    case "$verdict" in
        PASS*)    ok    "[$comp] $verdict" ;;
        FAIL*)    err   "[$comp] $verdict" ;;
        UNKNOWN*) warn  "[$comp] $verdict" ;;
    esac
done

log "Reports → $RUN_DIR"
exit $exit_code
