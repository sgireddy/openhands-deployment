#!/usr/bin/env bash
# scripts/update.sh — discover newer upstream tags and (optionally) re-run build.sh.
#
# Queries the upstream registries for tag lists, prints any tags that look
# newer than what's in `.env`, and offers to bump `.env` and re-run build.sh.
#
# This script is intentionally read-only by default — it only modifies `.env`
# (via `--apply`) after asking. It never pushes anywhere.
#
# Usage:
#   ./scripts/update.sh                # list newer tags (read-only)
#   ./scripts/update.sh --apply        # bump .env and run build.sh --yes
#
# Notes:
#   - agent-server: we treat the OpenHands software-agent-sdk GitHub
#     **releases** as the source of truth, then map vX.Y.Z → X.Y.Z-python
#     to find the corresponding ghcr.io image tag. (GHCR's tags/list
#     endpoint paginates ~20k+ entries with one semver tag per release
#     buried among per-commit tags, so direct enumeration is impractical.)
#   - openhands base image is operator-managed; not auto-discovered here.

set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib.sh
. "$REPO_ROOT/scripts/lib.sh"

APPLY=0
while (( $# )); do
    case "$1" in
        --apply) APPLY=1; shift ;;
        -h|--help)
            awk 'NR>1 && /^#/ {sub(/^# ?/,""); print; next} {exit}' "$0"
            exit 0 ;;
        *) err "unknown arg: $1"; exit 1 ;;
    esac
done

load_env
command -v curl   >/dev/null || { err "curl required"; exit 1; }
command -v python3 >/dev/null || { err "python3 required"; exit 1; }

# --- discovery via GitHub releases ------------------------------------------
SDK_REPO="OpenHands/software-agent-sdk"

# Latest SDK release tag (e.g. "v1.19.0"). Empty string on failure.
latest_sdk_release() {
    local hdr=()
    [[ -n "${GITHUB_TOKEN:-}" ]] && hdr=(-H "Authorization: Bearer $GITHUB_TOKEN")
    curl -fsSL "${hdr[@]}" \
        -H "Accept: application/vnd.github+json" \
        "https://api.github.com/repos/${SDK_REPO}/releases/latest" 2>/dev/null \
        | python3 -c 'import json,sys
try:
    print(json.load(sys.stdin).get("tag_name",""))
except Exception:
    pass'
}

# Verify the corresponding "<X.Y.Z>-python" tag exists on GHCR. Returns 0 if so.
ghcr_tag_exists() { # $1 = repo (e.g. openhands/agent-server)  $2 = tag
    local repo="$1" tag="$2" token
    token="$(curl -fsSL "https://ghcr.io/token?scope=repository:${repo}:pull" \
        | python3 -c 'import json,sys;print(json.load(sys.stdin)["token"])' 2>/dev/null)"
    [[ -n "$token" ]] || return 1
    local code
    code="$(curl -sS -o /dev/null -w '%{http_code}' \
        -H "Authorization: Bearer $token" \
        -H "Accept: application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.v2+json,application/vnd.docker.distribution.manifest.list.v2+json" \
        "https://ghcr.io/v2/${repo}/manifests/${tag}")"
    [[ "$code" == "200" ]]
}

# --- find newer tags --------------------------------------------------------
hdr "Discovering newer upstream tags"

# agent-server: SDK GitHub releases → derive expected image tag → verify on GHCR.
log "Querying github.com/${SDK_REPO}/releases/latest ..."
sdk_tag="$(latest_sdk_release)"
if [[ -z "$sdk_tag" ]]; then
    warn "  could not reach GitHub releases API (rate limit? offline?)"
    as_newest=""
else
    # Strip leading "v": v1.19.0 → 1.19.0
    sdk_ver="${sdk_tag#v}"
    candidate="${sdk_ver}-python"
    log "  latest SDK release : $sdk_tag"
    if ghcr_tag_exists "openhands/agent-server" "$candidate"; then
        as_newest="$candidate"
    else
        warn "  ${candidate} not found on ghcr.io (mismatch between release and image publish)"
        as_newest=""
    fi
fi
log "  current  : ${AGENT_SERVER_BASE_TAG}"
log "  newest   : ${as_newest:-<none-found>}"

oh_newest=""   # placeholder for --apply path below; openhands not auto-discovered
log "OpenHands base image (${OPENHANDS_BASE_IMAGE}:${OPENHANDS_BASE_TAG}) is operator-managed; not auto-discovered."

# --- apply ------------------------------------------------------------------
if (( ! APPLY )); then
    log
    log "Run with --apply to bump .env and rebuild."
    exit 0
fi

[[ -f "$REPO_ROOT/.env" ]] || cp "$REPO_ROOT/.env.example" "$REPO_ROOT/.env"

if [[ -n "$as_newest" && "$as_newest" != "$AGENT_SERVER_BASE_TAG" ]]; then
    confirm "Bump AGENT_SERVER_BASE_TAG ${AGENT_SERVER_BASE_TAG} → ${as_newest}?" \
        && sed -i.bak "s|^AGENT_SERVER_BASE_TAG=.*|AGENT_SERVER_BASE_TAG=${as_newest}|" "$REPO_ROOT/.env" \
        && rm -f "$REPO_ROOT/.env.bak" \
        && ok "bumped AGENT_SERVER_BASE_TAG"
fi
if [[ -n "$oh_newest" && "$oh_newest" != "$OPENHANDS_BASE_TAG" && "$OPENHANDS_BASE_TAG" != "latest" ]]; then
    confirm "Bump OPENHANDS_BASE_TAG ${OPENHANDS_BASE_TAG} → ${oh_newest}?" \
        && sed -i.bak "s|^OPENHANDS_BASE_TAG=.*|OPENHANDS_BASE_TAG=${oh_newest}|" "$REPO_ROOT/.env" \
        && rm -f "$REPO_ROOT/.env.bak" \
        && ok "bumped OPENHANDS_BASE_TAG"
fi

log "Re-running build.sh ..."
exec "$REPO_ROOT/scripts/build.sh" --yes
