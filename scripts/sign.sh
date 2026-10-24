#!/usr/bin/env bash
# scripts/sign.sh — sign and/or verify the published hardened image digests
# with cosign.
#
# WHY digests, not tags: a signature binds to immutable content. Signing a tag
# is meaningless once the tag moves. We resolve each tag to its manifest-list
# digest and sign that.
#
# KEY CUSTODY (read this): this script never generates or commits a private key.
# You own the key. Two supported models:
#
#   1. Keyed (default here): a local password-protected cosign key pair.
#        cosign generate-key-pair           # writes cosign.key (PRIVATE) + cosign.pub
#        # cosign.key is gitignored; commit ONLY cosign.pub.
#      Sign/verify with COSIGN_KEY=cosign.key / COSIGN_PUB=cosign.pub.
#
#   2. Keyless (OIDC/Fulcio): no local key; identity-bound, needs a browser.
#        SIGN_MODE=keyless ./scripts/sign.sh sign
#      Verify requires --certificate-identity / --certificate-oidc-issuer.
#
# Usage:
#   ./scripts/sign.sh sign                 # sign the published slim digests
#   ./scripts/sign.sh verify               # verify them
#   IMAGES="repo/img:tag ..." ./scripts/sign.sh sign   # custom target list
#
# Env:
#   COSIGN_KEY   path to private key   (default: cosign.key)   [keyed]
#   COSIGN_PUB   path to public key    (default: cosign.pub)   [keyed verify]
#   COSIGN_PASSWORD   key password (export to avoid interactive prompt)
#   SIGN_MODE    keyed | keyless       (default: keyed)
#   DOCKER_CONFIG  registry auth (on the SSH-driven Mac: $HOME/.docker-ssh)
#
# Exit codes: 0 ok, 1 usage/tooling, 2 sign/verify failure.
set -u

ACTION="${1:-}"
SIGN_MODE="${SIGN_MODE:-keyed}"
COSIGN_KEY="${COSIGN_KEY:-cosign.key}"
COSIGN_PUB="${COSIGN_PUB:-cosign.pub}"

# Default targets = the supported, published slim artifacts.
: "${IMAGES:=docker.io/sgireddy/agent-server:custom_base-slim docker.io/sgireddy/openhands:custom_base-slim}"

command -v cosign >/dev/null 2>&1 || { echo "ERROR: cosign not found on PATH" >&2; exit 1; }

resolve_digest() {
  # Print repo@sha256:... for a tag, using buildx imagetools (no local pull).
  local ref="$1" repo="${1%%@*}" dig
  case "$ref" in
    *@sha256:*) echo "$ref"; return 0 ;;
  esac
  repo="${ref%:*}"
  dig="$(docker buildx imagetools inspect "$ref" 2>/dev/null | awk '/^Digest:/{print $2; exit}')"
  [ -n "$dig" ] || { echo "ERROR: could not resolve digest for $ref" >&2; return 1; }
  echo "${repo}@${dig}"
}

case "$ACTION" in
  sign)
    rc=0
    for ref in $IMAGES; do
      target="$(resolve_digest "$ref")" || { rc=2; continue; }
      echo ">>> signing $target"
      if [ "$SIGN_MODE" = "keyless" ]; then
        cosign sign --yes "$target" || rc=2
      else
        [ -f "$COSIGN_KEY" ] || { echo "ERROR: $COSIGN_KEY not found (run: cosign generate-key-pair)" >&2; exit 1; }
        cosign sign --yes --key "$COSIGN_KEY" "$target" || rc=2
      fi
    done
    exit $rc
    ;;
  verify)
    rc=0
    for ref in $IMAGES; do
      target="$(resolve_digest "$ref")" || { rc=2; continue; }
      echo ">>> verifying $target"
      if [ "$SIGN_MODE" = "keyless" ]; then
        echo "   keyless verify needs --certificate-identity + --certificate-oidc-issuer; e.g.:"
        echo "   cosign verify --certificate-identity <you> --certificate-oidc-issuer <issuer> $target"
        rc=2
      else
        [ -f "$COSIGN_PUB" ] || { echo "ERROR: $COSIGN_PUB not found" >&2; exit 1; }
        cosign verify --key "$COSIGN_PUB" "$target" >/dev/null && echo "   OK" || rc=2
      fi
    done
    exit $rc
    ;;
  *)
    echo "Usage: $0 {sign|verify}   (see header for env/key-custody notes)" >&2
    exit 1
    ;;
esac
