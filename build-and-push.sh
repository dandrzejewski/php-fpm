#!/usr/bin/env bash
#
# build-and-push.sh — build the php-fpm image from Containerfile and push to GHCR.
#
# Auth: uses the GitHub CLI (`gh`) for credentials — no PAT to manage. The
#       gh token must carry the write:packages scope; add it once with:
#           gh auth refresh -h github.com -s write:packages
#       The token is read from `gh auth token`, piped via stdin to
#       `docker login`, and never written to disk or echoed. Set GHCR_SKIP_LOGIN=1
#       to skip login entirely (e.g. when already authenticated to ghcr.io).
#
# Usage:
#   ./build-and-push.sh [extra-tag]
#
#   extra-tag  Optional additional tag (default: an immutable <date>-<gitsha>
#              tag is generated automatically alongside :latest).
#
# Requires: docker (BuildKit), gh (authenticated), and bash. No root needed if
# your user is in the docker group; otherwise prefix the invocation with sudo.

set -euo pipefail

# --- Configuration ----------------------------------------------------------
REGISTRY="ghcr.io"
IMAGE="${REGISTRY}/dandrzejewski/php-fpm"
CONTAINERFILE="Containerfile"
CONTEXT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Derive an immutable tag -------------------------------------------------
# Date + short git SHA so every pushed build is uniquely identifiable.
# Falls back to "nogit" when not in a git work tree.
build_date="$(date -u +%Y%m%d)"
if git -C "${CONTEXT_DIR}" rev-parse --short HEAD >/dev/null 2>&1; then
    git_sha="$(git -C "${CONTEXT_DIR}" rev-parse --short HEAD)"
    # Mark a dirty tree so we never label uncommitted builds as a clean SHA.
    git diff --quiet --ignore-submodules HEAD 2>/dev/null || git_sha="${git_sha}-dirty"
else
    git_sha="nogit"
fi
IMMUTABLE_TAG="${build_date}-${git_sha}"

# Tags to apply: latest, the immutable tag, and any caller-supplied extra tag.
TAGS=("latest" "${IMMUTABLE_TAG}")
if [[ $# -ge 1 && -n "${1:-}" ]]; then
    TAGS+=("$1")
fi

# --- Sanity checks -----------------------------------------------------------
if [[ ! -f "${CONTEXT_DIR}/${CONTAINERFILE}" ]]; then
    echo "ERROR: ${CONTAINERFILE} not found in ${CONTEXT_DIR}" >&2
    exit 1
fi

# --- Authenticate via gh -----------------------------------------------------
if [[ "${GHCR_SKIP_LOGIN:-0}" == "1" ]]; then
    echo ">> GHCR_SKIP_LOGIN=1 — assuming existing ${REGISTRY} credentials"
else
    command -v gh >/dev/null 2>&1 || { echo "ERROR: gh not found. Install GitHub CLI or set GHCR_SKIP_LOGIN=1." >&2; exit 1; }

    # Resolve the GitHub username gh is authenticated as.
    ghcr_user="$(gh api user --jq '.login' 2>/dev/null)" \
        || { echo "ERROR: gh is not authenticated. Run: gh auth login" >&2; exit 1; }

    # Ensure the token carries write:packages; add it if missing.
    # Note: gh auth refresh is interactive (browser / one-time code prompt).
    if ! gh auth status 2>&1 | grep -q 'write:packages'; then
        echo ">> gh token lacks write:packages — refreshing scope (interactive)"
        # BROWSER=echo makes gh print the device-login URL instead of opening
        # a browser. Copy the one-time code, open the printed URL, authorize.
        BROWSER=echo gh auth refresh -h github.com -s write:packages
    fi

    echo ">> Logging in to ${REGISTRY} as ${ghcr_user} (via gh token)"
    gh auth token | docker login "${REGISTRY}" -u "${ghcr_user}" --password-stdin
fi

# --- Build -------------------------------------------------------------------
# Assemble -t args for every tag.
tag_args=()
for t in "${TAGS[@]}"; do
    tag_args+=("-t" "${IMAGE}:${t}")
done

echo ">> Building ${IMAGE} with tags: ${TAGS[*]}"
DOCKER_BUILDKIT=1 docker build \
    -f "${CONTEXT_DIR}/${CONTAINERFILE}" \
    "${tag_args[@]}" \
    "${CONTEXT_DIR}"

# --- Push --------------------------------------------------------------------
for t in "${TAGS[@]}"; do
    echo ">> Pushing ${IMAGE}:${t}"
    docker push "${IMAGE}:${t}"
done

echo ">> Done. Pushed: ${TAGS[*]/#/${IMAGE}:}"
