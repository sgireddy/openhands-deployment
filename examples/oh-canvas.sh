#!/bin/zsh

# Launch the hardened OpenHands **Agent Canvas** all-in-one app.
#
# Canvas is self-contained: frontend + automation + a bundled agent-server
# behind one ingress proxy on :8000. Unlike the classic oh.sh, it does NOT
# spawn per-conversation sandbox containers, so it needs NO docker.sock and no
# AGENT_SERVER_IMAGE_* wiring.
#
# Security posture: the ingress is bound to 127.0.0.1 ONLY (localhost-only
# network exposure) and protected by a backend API key. This script generates
# the key once and persists it, so restarts keep the same key (and your browser
# session stays valid).
#
# The LLM is configured ONCE through the Canvas Settings UI on first run and
# persisted in the state volume below (it is not a launch-time env var). Point
# it at the existing litellm proxy at http://host.docker.internal:4000 — this
# script already wires host.docker.internal.
#
# Usage:
#   ./oh-canvas.sh              # localhost:3000  (the cutover target)
#   ./oh-canvas.sh 3005         # localhost:3005  (verify alongside classic :3000)
#
# This script only ever touches its OWN container ("agent-canvas"); the classic
# "openhands" / "openhands-claude" stacks are left untouched. If the chosen port
# is already taken (e.g. by the classic openhands on 3000), `docker run` fails
# loudly rather than clobbering anything.

# Configuration
PORT=${1:-3000}
BIND_ADDR=${BIND_ADDR:-127.0.0.1}
CONTAINER_NAME="agent-canvas"

# --- Hardened, eMudhra-clean, browser-capable image (pinned by digest) -------
# Built from openhands-deployment/overlays/Dockerfile.agent-canvas; verified on
# linux/amd64 + linux/arm64. Registry Trivy re-scan BY DIGEST = 1 Critical: the
# unfixable libxml2 CVE-2026-6653 (a mandatory Chromium dependency, DoS-only) —
# the accepted floor for any browser-capable image. emSign/eMudhra distrusted in
# the OS store + certifi; uv on native TLS. Bundles agent-server/SDK 1.63.1.
# For a literal Critical=0 image (no in-sandbox browser tool), rebuild the
# overlay with STRIP_BROWSER_TOOLS=1.
IMAGE="docker.io/sgireddy/agent-canvas:custom_base-browser-1.45.0@sha256:9c85c1dded71a27947adb78816506e2386f742f45f8a5ba8a138fd47ad86d52e"

SCRIPT_DIR="${0:a:h}"
DATA_DIR="$SCRIPT_DIR/canvas-data"
LOG_FILE="$SCRIPT_DIR/agent-canvas.log"
KEY_FILE="$DATA_DIR/.backend_api_key"

# Setup persistence:
#   state    -> /home/openhands/.openhands  (settings, secrets, conversations,
#                                             automation DB)
#   projects -> /projects                   (user code the agent can read/edit)
mkdir -p "$DATA_DIR"/{state,projects}

# Generate the backend API key once; reuse it across restarts.
if [[ ! -s "$KEY_FILE" ]]; then
  openssl rand -hex 32 > "$KEY_FILE"
  chmod 600 "$KEY_FILE"
fi
LOCAL_BACKEND_API_KEY=$(<"$KEY_FILE")

# Replace only our own container; never touch the classic stacks.
docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1
pkill -f "docker logs -f $CONTAINER_NAME" >/dev/null 2>&1

# Pull the pinned hardened image so the local cache matches the published,
# scanned artifact.
echo "Pulling hardened Agent Canvas image..."
docker pull "$IMAGE" >/dev/null 2>&1

# Launch. shm_size is bumped so Chromium (browser tool) is happy in-container.
CONTAINER_ID=$(docker run -d --restart unless-stopped --name "$CONTAINER_NAME" \
  -p "${BIND_ADDR}:${PORT}:8000" \
  --shm-size=2g \
  --add-host "host.docker.internal:host-gateway" \
  -v "$DATA_DIR/state:/home/openhands/.openhands" \
  -v "$DATA_DIR/projects:/projects" \
  -e "LOCAL_BACKEND_API_KEY=$LOCAL_BACKEND_API_KEY" \
  -e "OH_ENABLE_BROWSER=true" \
  -e "OH_ENABLE_VSCODE=true" \
  -e "CHROMIUM_FLAGS=--no-sandbox --disable-dev-shm-usage --disable-gpu" \
  "$IMAGE" 2>&1)

if [[ $? -eq 0 ]]; then
    # Background Logging (Detached/Disowned), same pattern as oh.sh.
    { docker logs -f "$CONTAINER_NAME" >> "$LOG_FILE" 2>&1 } &!

    print -P "%F{green}Agent Canvas backgrounded.%f"
    print "UI:  http://${BIND_ADDR}:${PORT}/canvas"
    print "Key: $KEY_FILE (backend API key; keep it)"
    print "LLM: configure once in the Settings UI -> point at http://host.docker.internal:4000"
else
    print -P "%F{red}Failed: $CONTAINER_ID%f"
fi
