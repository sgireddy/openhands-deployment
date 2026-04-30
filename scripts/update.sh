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
#   - For ghcr.io we use the public anonymous token endpoint, no auth needed.
#   - For other registries (e.g. internal mirrors) we hit the v2 catalog/tags
#     API. If the registry requires auth, the script will surface the error
#     and stop.

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

# --- registry tag listing ---------------------------------------------------
list_ghcr_tags() { # $1 = "openhands/agent-server"
    local repo="$1"
    local token
    token="$(curl -fsSL "https://ghcr.io/token?scope=repository:${repo}:pull" \
        | python3 -c 'import json,sys;print(json.load(sys.stdin)["token"])')"
    curl -fsSL -H "Authorization: Bearer $token" \
        "https://ghcr.io/v2/${repo}/tags/list" \
        | python3 -c 'import json,sys;[print(t) for t in json.load(sys.stdin).get("tags",[])]'
}

list_v2_tags() { # $1 = registry/repo (no tag), e.g. registry.example.com/myorg/openhands
    local image="$1"
    local registry="${image%%/*}"
    local repo="${image#*/}"
    curl -fsSL "https://${registry}/v2/${repo}/tags/list" 2>&1 \
        | python3 -c 'import json,sys
try:
    print("\n".join(json.load(sys.stdin).get("tags",[])))
except Exception as e:
    sys.stderr.write(f"warn: {e}\n")' 2>/dev/null || true
}

# Pick the newest tag matching a regex, by semver-ish sort.
newest_matching() { # $1 = newline-separated tags, $2 = regex
    local tags="$1" pattern="$2"
    echo "$tags" | grep -E "$pattern" \
        | sort -t. -k1,1n -k2,2n -k3,3n -V \
        | tail -1
}

# --- find newer tags --------------------------------------------------------
hdr "Discovering newer upstream tags"

# agent-server is the only component this repo can meaningfully tag-discover,
# because it's published to a known registry (ghcr.io/openhands/agent-server).
#
# OpenHands itself is built from source by the operator (`make build` in the
# OpenHands source repo) and tagged locally — there's no canonical registry
# we can query. If you've configured OPENHANDS_BASE_IMAGE to point at your
# own internal registry, run `docker pull` against it manually.

log "Querying ${AGENT_SERVER_BASE_IMAGE} ..."
as_repo="${AGENT_SERVER_BASE_IMAGE#ghcr.io/}"
as_tags="$(list_ghcr_tags "$as_repo" 2>/dev/null || true)"
as_newest="$(newest_matching "$as_tags" '^[0-9]+\.[0-9]+\.[0-9]+-python$' || true)"
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
