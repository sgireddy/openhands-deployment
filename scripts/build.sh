#!/usr/bin/env bash
# scripts/build.sh — scan upstream, overlay, scan again, verify policy.
#
# This script ASSUMES the upstream images already exist locally. It does NOT
# pull anything. Procuring the upstream images is the operator's job:
#
#   - openhands:latest               built from the OpenHands source repo
#                                    (`make build`) or pulled from whichever
#                                    registry your fleet uses.
#   - ghcr.io/openhands/agent-server:<tag>
#                                    `docker pull ghcr.io/openhands/agent-server:1.19.0-python`
#                                    (public — no auth needed for read).
#
# For each component (openhands, agent-server):
#   1. Verify the upstream image is in the local cache; bail clearly if not.
#   2. Scout-scan it as the BASELINE.
#   3. Build the local hardening overlay → <out>:<custom_base>.
#   4. Scout-scan the result.
#   5. Apply policy (POLICY_MAX_CRITICAL / POLICY_MAX_HIGH from .env).
#
# Run from repo root:
#   ./scripts/build.sh                     # both components
#   ./scripts/build.sh openhands           # one component
#   ./scripts/build.sh agent-server        # one component
#   ./scripts/build.sh --yes               # non-interactive
#
# Exit codes:
#   0  all components built and within policy
#   1  hard error (missing tools, bad config, missing upstream image, build failed)
#   2  policy violated (Critical > limit) on at least one component

set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib.sh
. "$REPO_ROOT/scripts/lib.sh"

# --- arg parse --------------------------------------------------------------
COMPONENTS=()
ASSUME_YES=0
while (( $# )); do
    case "$1" in
        openhands|agent-server) COMPONENTS+=("$1"); shift ;;
        --yes|-y)               ASSUME_YES=1; shift ;;
        -h|--help)
            awk 'NR>1 && /^#/ {sub(/^# ?/,""); print; next} {exit}' "$0"
            exit 0 ;;
        *) err "unknown arg: $1"; exit 1 ;;
    esac
done
if (( ${#COMPONENTS[@]} == 0 )); then
    COMPONENTS=(openhands agent-server)
fi
export ASSUME_YES

# --- env + tools ------------------------------------------------------------
load_env
require_tools

RUN_DIR="$REPO_ROOT/reports/$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$RUN_DIR"
log "Reports → $RUN_DIR"

# Surface drift before doing real work — not a build blocker, but the
# operator should know if their pin is behind the latest stable SDK.
report_drift

# --- per-component build function ------------------------------------------
# Returns:
#   0  success and within policy
#   1  hard error (image missing, build failed)
#   2  policy violation
build_component() {
    local comp="$1"
    local base_image base_tag out_image out_tag dockerfile pip_upgrades

    case "$comp" in
        openhands)
            base_image="$OPENHANDS_BASE_IMAGE"
            base_tag="$OPENHANDS_BASE_TAG"
            out_image="$OPENHANDS_OUT_IMAGE"
            out_tag="$OPENHANDS_OUT_TAG"
            dockerfile="overlays/Dockerfile.openhands"
            pip_upgrades="$PIP_UPGRADES_OPENHANDS" ;;
        agent-server)
            base_image="$AGENT_SERVER_BASE_IMAGE"
            base_tag="$AGENT_SERVER_BASE_TAG"
            out_image="$AGENT_SERVER_OUT_IMAGE"
            out_tag="$AGENT_SERVER_OUT_TAG"
            dockerfile="overlays/Dockerfile.agent-server"
            pip_upgrades="$PIP_UPGRADES_AGENT_SERVER" ;;
        *) err "unknown component: $comp"; return 1 ;;
    esac

    local upstream="${base_image}:${base_tag}"
    local hardened="${out_image}:${out_tag}"

    hdr "[$comp] upstream=$upstream  →  hardened=$hardened"

    # 1. require upstream to be in the local cache. We don't pull.
    if ! docker image inspect "$upstream" >/dev/null 2>&1; then
        err "[$comp] upstream image not found locally: $upstream"
        err "  This script does not pull upstream images. Obtain it first, e.g.:"
        case "$comp" in
            openhands)
                err "    cd /path/to/OpenHands && make build" ;;
            agent-server)
                err "    docker pull $upstream" ;;
        esac
        return 1
    fi
    ok "[$comp] upstream cached: $upstream"

    # 2. baseline scan
    scout_scan "$upstream" "${comp}-01-baseline" "$RUN_DIR" \
        || { err "[$comp] baseline scout scan failed"; return 1; }
    local b_counts; b_counts="$(scout_counts "$RUN_DIR/${comp}-01-baseline-quickview.txt")"
    local b_crit="${b_counts%%:*}" b_high="${b_counts##*:}"
    log "[$comp] baseline           : ${b_crit}C / ${b_high}H"

    # 3. overlay build
    hdr "[$comp] building overlay → $hardened"
    if ! docker build \
            -f "$REPO_ROOT/$dockerfile" \
            --build-arg "BASE_IMAGE=$upstream" \
            --build-arg "PIP_UPGRADES=$pip_upgrades" \
            --no-cache \
            -t "$hardened" \
            "$REPO_ROOT"; then
        err "[$comp] overlay build failed; see error above"
        return 1
    fi
    ok "[$comp] built $hardened"

    # 4. post-overlay scan
    scout_scan "$hardened" "${comp}-02-post-overlay" "$RUN_DIR" \
        || { err "[$comp] post-overlay scout scan failed"; return 1; }
    local p_counts; p_counts="$(scout_counts "$RUN_DIR/${comp}-02-post-overlay-quickview.txt")"
    local p_crit="${p_counts%%:*}" p_high="${p_counts##*:}"
    log "[$comp] after overlay      : ${p_crit}C / ${p_high}H   (was ${b_crit}C / ${b_high}H)"

    # 5. policy gate
    local verdict rc
    set +e
    verdict="$(policy_check "$p_crit" "$p_high")"
    rc=$?
    set -e
    case "$verdict" in
        PASS*)    ok "[$comp] policy: $verdict" ;;
        FAIL*)    err "[$comp] policy: $verdict";  return 2 ;;
        UNKNOWN*) warn "[$comp] policy: $verdict" ;;
    esac
    return $rc
}

# --- run all requested components ------------------------------------------
exit_code=0
for comp in "${COMPONENTS[@]}"; do
    set +e
    build_component "$comp"
    rc=$?
    set -e
    case $rc in
        0)  ;;                                  # ok
        2)  exit_code=2 ;;                      # policy violation, keep going
        *)  err "build_component '$comp' failed (rc=$rc); aborting"
            exit 1 ;;
    esac
done

hdr "Summary"
log "Run reports : $RUN_DIR"
log "Compose up  : docker compose -f compose/docker-compose.yml --env-file .env up -d"

if (( exit_code == 2 )); then
    warn "At least one component violates policy. See reports/*-cves-critical-high.txt"
fi
exit $exit_code
