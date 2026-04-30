#!/bin/zsh
# examples/run-openhands.sh — start the openhands web app from the hardened
# images produced by ../scripts/build.sh.
#
# This is an *example* invocation script. It is not part of the build
# pipeline; it shows how to wire the two hardened images together at run
# time. Adapt freely.
#
# Required env (export these from your shell or a .env you source first):
#   OH_SECRET_KEY        — JWT signing key for openhands sessions
#                          (any reasonably long random string).
#                          Generate one once with:
#                            openssl rand -hex 32
#
# Optional env (sensible defaults provided):
#   AGENT_SERVER_REPO    — repo of the hardened agent-server image
#                          (default: agent-server)
#   AGENT_SERVER_TAG     — tag of the hardened agent-server image
#                          (default: custom_base — matches build.sh output)
#   DEPLOY_HOME          — parent dir for all runtime state and logs
#                          (default: $HOME/openhands-deployment)
#                          Sub-paths (one set per instance, scoped by name):
#                            $DEPLOY_HOME/<instance>/{state,workspace,.openhands}
#                            $DEPLOY_HOME/<instance>.log
#                            $DEPLOY_HOME/<instance>.pid
#   INSTANCE_NAME        — unique name scoping every per-instance bit of
#                          state (container name, data dir, logs, pidfile).
#                          (default: openhands-<port>)
#                          Letting two simultaneous runs on different ports
#                          stay isolated:
#                            ./run-openhands.sh 3010 'anthropic/claude-...'
#                            ./run-openhands.sh 3020 'openai/gpt-...'
#                          gives you openhands-3010 + openhands-3020.
#
# Positional args:
#   $1 — host port to bind the UI on (default: 3000)
#   $2 — model alias (default: a placeholder; replace with your real one)
#   $3 — LLM base URL (default: a local litellm proxy on :4000)
#
# ⚠️  Privilege note: this script bind-mounts the host docker socket into
#     the openhands container. That gives the container effective root on
#     the host. This is required for openhands to spawn sandbox containers
#     for each conversation. Don't run this on a machine where the
#     openhands process is not trusted with full docker access.
#
# ⚠️  Logging note: LOG_LEVEL=DEBUG can record prompt/response payloads
#     and may incidentally capture API keys or other secrets. The log
#     file lives at $DEPLOY_HOME/openhands.log — outside the repo by
#     default, so it can never accidentally be staged. Treat it as
#     sensitive regardless of where it lands.

# ----- configuration --------------------------------------------------------
PORT=${1:-3000}

# Replace this default with your own model alias. The example shows the
# litellm-proxy syntax (provider/model). For a direct provider, use e.g.
# "anthropic/claude-sonnet-4-5" or "openai/gpt-4o".
MODEL=${2:-"litellm_proxy/your-model-alias"}

# Default points at a litellm proxy on the host. If you don't run a proxy,
# replace with the upstream provider URL or leave unset and let openhands
# use its built-in defaults.
BASE_URL=${3:-"http://host.docker.internal:4000"}

IMAGE="openhands:custom_base"            # built by ../scripts/build.sh
AGENT_SERVER_REPO="${AGENT_SERVER_REPO:-agent-server}"
AGENT_SERVER_TAG="${AGENT_SERVER_TAG:-custom_base}"

# Per-instance scoping. Defaults to "openhands-<PORT>" so two runs on
# different ports get distinct container names + state automatically.
# Override INSTANCE_NAME if you'd rather have a friendlier name like
# "claude-prod". Sanitise to docker's allowed name charset just in case.
INSTANCE_NAME="${INSTANCE_NAME:-openhands-${PORT}}"
# Reject up-front if the input contains zero docker-legal characters
# (alnum / _ / . / -), otherwise we'd silently produce a name made of
# only replacement dashes.
if [[ ! "$INSTANCE_NAME" =~ [a-zA-Z0-9_.] ]]; then
    print -P "%F{red}INSTANCE_NAME '$INSTANCE_NAME' has no valid characters [a-zA-Z0-9_.]; cannot continue.%f"
    exit 1
fi
# Substitute all illegal chars with '-', collapse runs of '-', strip
# leading/trailing '-'.
INSTANCE_NAME="${INSTANCE_NAME//[^a-zA-Z0-9_.-]/-}"
while [[ "$INSTANCE_NAME" == *--* ]]; do
    INSTANCE_NAME="${INSTANCE_NAME//--/-}"
done
INSTANCE_NAME="${INSTANCE_NAME#-}"
INSTANCE_NAME="${INSTANCE_NAME%-}"
CONTAINER_NAME="$INSTANCE_NAME"

SCRIPT_DIR="${0:a:h}"
# Runtime state lives OUTSIDE the repo. Consolidated under one parent
# ($HOME/openhands-deployment/) alongside reports/ and workspace/ so the
# whole local footprint is in one place and zero of it can leak into a
# git commit. The repo's .gitignore is still defensive in case someone
# overrides these back inside the tree.
#
# Each instance gets its OWN data dir, log files, and pidfile so two
# simultaneous instances cannot corrupt each other's conversation DB or
# settings store.
#
# MIGRATION: existing single-instance users had everything under
# $DEPLOY_HOME/data/{state,workspace,.openhands}. To preserve their
# history when moving to this version, rename that directory once:
#     mv "$DEPLOY_HOME/data" "$DEPLOY_HOME/openhands-3000"
DEPLOY_HOME="${DEPLOY_HOME:-$HOME/openhands-deployment}"
DATA_DIR="$DEPLOY_HOME/$INSTANCE_NAME"
LOG_FILE="$DEPLOY_HOME/${INSTANCE_NAME}.log"
PID_FILE="$DEPLOY_HOME/${INSTANCE_NAME}.pid"

# ----- pre-flight -----------------------------------------------------------
if [[ -z "$OH_SECRET_KEY" ]]; then
    print -P "%F{red}OH_SECRET_KEY is not set. Generate one with: openssl rand -hex 32%f"
    exit 1
fi

# Verify both hardened images are present.
for img in "$IMAGE" "${AGENT_SERVER_REPO}:${AGENT_SERVER_TAG}"; do
    if ! docker image inspect "$img" >/dev/null 2>&1; then
        print -P "%F{red}image not found locally: $img%f"
        print "  Run ../scripts/build.sh first."
        exit 1
    fi
done

# ----- setup ----------------------------------------------------------------
mkdir -p "$DEPLOY_HOME"
mkdir -p "$DATA_DIR"/{state,workspace,.openhands}

# Stop the prior container WITH THE SAME INSTANCE NAME. This deliberately
# does NOT touch other instances — re-running with PORT=3010 only restarts
# openhands-3010 and leaves openhands-3020 running.
docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1

# Stop the prior `docker logs -f` tailer for THIS instance only by reading
# the per-instance pidfile written at the end of the previous run.
if [[ -f "$PID_FILE" ]]; then
    OLD_PID=$(<"$PID_FILE")
    if [[ -n "$OLD_PID" ]] && kill -0 "$OLD_PID" 2>/dev/null; then
        kill "$OLD_PID" 2>/dev/null
    fi
    rm -f "$PID_FILE"
fi

# ----- launch ---------------------------------------------------------------
# NOTE: .openhands is mounted to BOTH /.openhands (for FILE_STORE_PATH
#       settings/secrets) AND /home/enduser/.openhands (where openhands.db
#       and v1_conversations are stored).
#
# AGENT_SERVER_IMAGE_REPOSITORY + AGENT_SERVER_IMAGE_TAG together tell
# openhands which agent-server image to spawn for each new sandbox.
# Both must be set or the resolver falls back to the upstream pinned
# default (ghcr.io/openhands/agent-server:<version>-python).
# See: openhands/app_server/sandbox/sandbox_spec_service.py:get_agent_server_image
CONTAINER_ID=$(docker run -d --restart unless-stopped --name "$CONTAINER_NAME" \
  -p "${PORT}:3000" \
  -v "/var/run/docker.sock:/var/run/docker.sock" \
  -v "$DATA_DIR/state:/app/data" \
  -v "$DATA_DIR/workspace:/opt/workspace_base" \
  -v "$DATA_DIR/.openhands:/.openhands" \
  -v "$DATA_DIR/.openhands:/home/enduser/.openhands" \
  -e "SANDBOX_USER_ID=$(id -u)" \
  -e "OPENAI_BASE_URL=$BASE_URL" \
  -e "OPENAI_MODEL=$MODEL" \
  -e "OH_SECRET_KEY=$OH_SECRET_KEY" \
  -e "LOG_LEVEL=DEBUG" \
  -e "CONVERSATION_MAX_AGE_SECONDS=315360000" \
  -e "AGENT_SERVER_IMAGE_REPOSITORY=$AGENT_SERVER_REPO" \
  -e "AGENT_SERVER_IMAGE_TAG=$AGENT_SERVER_TAG" \
  "$IMAGE" 2>&1)

if [[ $? -eq 0 ]]; then
    # Detached log tailer so this script can exit immediately. Capture the
    # PID into the per-instance pidfile so the next run can clean it up
    # without touching other instances' tailers.
    { docker logs -f "$CONTAINER_NAME" >> "$LOG_FILE" 2>&1 } &!
    TAILER_PID=$!
    print "$TAILER_PID" > "$PID_FILE"

    print -P "%F{green}${INSTANCE_NAME} backgrounded.%f"
    print "Instance:     $INSTANCE_NAME"
    print "UI:           http://localhost:$PORT"
    print "Web image:    $IMAGE"
    print "Sandbox img:  ${AGENT_SERVER_REPO}:${AGENT_SERVER_TAG}"
    print "Data dir:     $DATA_DIR"
    print "Logs:         $LOG_FILE"
    print "Tailer PID:   $TAILER_PID  (stop with: kill $TAILER_PID)"
    print ""
    print "Stop this instance only:"
    print "  docker rm -f $INSTANCE_NAME"
    print "  kill $TAILER_PID"
    print ""
    print "List all instances launched by this script:"
    print "  docker ps --filter name=openhands- --format 'table {{.Names}}\t{{.Ports}}\t{{.Status}}'"
    print ""
    print "Verify the sandbox image is being used by spawning a conversation"
    print "in the UI, then run:"
    print "  docker ps --filter name=oh-agent-server- --format '{{.Image}}'"
else
    print -P "%F{red}Failed: $CONTAINER_ID%f"
    exit 1
fi
