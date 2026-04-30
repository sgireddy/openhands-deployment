#!/usr/bin/env bash
# scripts/build.sh — pull, scan, overlay, scan, verify policy.
#
# For each component (openhands, agent-server):
#   1. Pull the upstream image.
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
#   ./scripts/build.sh --no-pull           # use whatever's already cached
#
# Exit codes:
#   0  all components built and within policy
#   1  hard error (missing tools, bad config)
#   2  policy violated (Critical > limit) on at least one component

set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib.sh
. "$REPO_ROOT/scripts/lib.sh"

# --- arg parse --------------------------------------------------------------
COMPONENTS=()
ASSUME_YES=0
DO_PULL=1
while (( $# )); do
    case "$1" in
        openhands|agent-server) COMPONENTS+=("$1"); shift ;;
        --yes|-y)               ASSUME_YES=1; shift ;;
        --no-pull)              DO_PULL=0; shift ;;
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

# --- per-component build function ------------------------------------------
build_component() { # $1 = component name (openhands | agent-server)
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

    # 1. pull
    if (( DO_PULL )); then
        log "[$comp] pulling $upstream"
        docker pull "$upstream"
    else
        log "[$comp] --no-pull: using cached $upstream"
        docker image inspect "$upstream" >/dev/null 2>&1 \
            || { err "[$comp] $upstream not in local cache"; return 1; }
    fi

    # 2. baseline scan
    scout_scan "$upstream" "${comp}-01-baseline" "$RUN_DIR"
    local b_counts; b_counts="$(scout_counts "$RUN_DIR/${comp}-01-baseline-quickview.txt")"
    local b_crit="${b_counts%%:*}" b_high="${b_counts##*:}"
    log "[$comp] baseline           : ${b_crit}C / ${b_high}H"

    # 3. overlay build
    hdr "[$comp] building overlay → $hardened"
    docker build \
        -f "$REPO_ROOT/$dockerfile" \
        --build-arg "BASE_IMAGE=$upstream" \
        --build-arg "PIP_UPGRADES=$pip_upgrades" \
        --no-cache \
        -t "$hardened" \
        "$REPO_ROOT"
    ok "[$comp] built $hardened"

    # 4. post-overlay scan
    scout_scan "$hardened" "${comp}-02-post-overlay" "$RUN_DIR"
    local p_counts; p_counts="$(scout_counts "$RUN_DIR/${comp}-02-post-overlay-quickview.txt")"
    local p_crit="${p_counts%%:*}" p_high="${p_counts##*:}"
    log "[$comp] after overlay      : ${p_crit}C / ${p_high}H   (was ${b_crit}C / ${b_high}H)"

    # 5. policy gate
    local verdict; verdict="$(policy_check "$p_crit" "$p_high")" || true
    case "$verdict" in
        PASS*)    ok "[$comp] policy: $verdict" ;;
        FAIL*)    err "[$comp] policy: $verdict";  return 2 ;;
        UNKNOWN*) warn "[$comp] policy: $verdict" ;;
    esac
}

# --- run all requested components ------------------------------------------
exit_code=0
for comp in "${COMPONENTS[@]}"; do
    if ! build_component "$comp"; then
        rc=$?
        if (( rc == 2 )); then
            exit_code=2
        else
            exit 1
        fi
    fi
done

hdr "Summary"
log "Run reports : $RUN_DIR"
log "Compose up  : docker compose -f compose/docker-compose.yml --env-file .env up -d"

if (( exit_code == 2 )); then
    warn "At least one component violates policy. See reports/*-cves-critical-high.txt"
fi
exit $exit_code
