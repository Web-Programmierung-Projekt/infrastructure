#!/usr/bin/env bash
# Wrapper around deploy.sh that persists per-app image tags between runs.
#
# When CI tells us "backend just got a new image at SHA X", we want to deploy
# backend:X but keep the frontend at whatever tag it had last time — there's
# no frontend image at that backend SHA. This script stores the last-deployed
# tags in .deployed-tags.<env> so a partial deploy can leave the unchanged
# app on its previous tag.
#
# Usage:
#   ./deploy-incremental.sh <env> <changed-app> <new-sha>
#     env         : dev | test | prod
#     changed-app : backend | frontend | manual
#     new-sha     : commit SHA of the image to deploy (ignored if changed-app=manual)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV="${1:?missing env}"
APP="${2:?missing changed-app}"
NEW_SHA="${3:-}"

case "$ENV" in
    dev|test|prod) ;;
    *) echo "env must be dev|test|prod, got '$ENV'" >&2; exit 1;;
esac

case "$APP" in
    backend|frontend|manual) ;;
    *) echo "changed-app must be backend|frontend|manual, got '$APP'" >&2; exit 1;;
esac

TAGS_FILE="${REPO_ROOT}/.deployed-tags.${ENV}"
touch "$TAGS_FILE"

# Read previous tags; default to "latest" the first time
BACKEND_TAG="$(grep '^BACKEND_TAG=' "$TAGS_FILE" | cut -d= -f2- || true)"
FRONTEND_TAG="$(grep '^FRONTEND_TAG=' "$TAGS_FILE" | cut -d= -f2- || true)"
BACKEND_TAG="${BACKEND_TAG:-latest}"
FRONTEND_TAG="${FRONTEND_TAG:-latest}"

case "$APP" in
    backend)
        [[ -n "$NEW_SHA" ]] || { echo "backend deploy needs a SHA" >&2; exit 1; }
        BACKEND_TAG="$NEW_SHA"
        ;;
    frontend)
        [[ -n "$NEW_SHA" ]] || { echo "frontend deploy needs a SHA" >&2; exit 1; }
        FRONTEND_TAG="$NEW_SHA"
        ;;
    manual)
        echo "[deploy-incremental] manual mode — re-deploying current tags ($BACKEND_TAG / $FRONTEND_TAG)"
        ;;
esac

echo "[deploy-incremental] deploying ${ENV} with backend=${BACKEND_TAG} frontend=${FRONTEND_TAG}"

GHCR_OWNER=web-programmierung-projekt \
    GHCR_BACKEND_TAG="$BACKEND_TAG" \
    GHCR_FRONTEND_TAG="$FRONTEND_TAG" \
    "${REPO_ROOT}/deploy.sh" "$ENV" --vm

# Persist on success so the next run knows what's currently deployed.
cat > "$TAGS_FILE" <<EOF
BACKEND_TAG=$BACKEND_TAG
FRONTEND_TAG=$FRONTEND_TAG
EOF
echo "[deploy-incremental] tags persisted to ${TAGS_FILE}"
