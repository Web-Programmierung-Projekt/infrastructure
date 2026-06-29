#!/usr/bin/env bash
# Deploy a single environment.
#
# Usage:
#   ./deploy.sh <env>           # build locally (laptop), bring up the stack
#   ./deploy.sh <env> --vm      # pull images from GHCR (production VM)
#
# <env> is one of: dev | test | prod.
#
# On the VM, GitHub Actions runs this via SSH. The deploy key only needs
# read access to the relevant repos.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV="${1:-}"
MODE="${2:-laptop}"

case "$ENV" in
    dev|test|prod) ;;
    *) echo "usage: $0 <dev|test|prod> [--vm]" >&2; exit 1;;
esac

if [[ "$MODE" == "--vm" ]]; then
    MODE="vm"
elif [[ -n "$MODE" && "$MODE" != "laptop" ]]; then
    echo "second argument must be --vm or omitted" >&2
    exit 1
fi

COMPOSE_FILE="${REPO_ROOT}/docker-compose.${ENV}.yml"
SECRETS_FILE="${REPO_ROOT}/secrets/${ENV}.env"

[[ -f "$COMPOSE_FILE" ]] || { echo "missing ${COMPOSE_FILE}" >&2; exit 1; }
[[ -f "$SECRETS_FILE" ]] || { echo "missing ${SECRETS_FILE} (run bootstrap-vm.sh or copy from .env.example)" >&2; exit 1; }

cd "$REPO_ROOT"

if [[ "$MODE" == "vm" ]]; then
    # Pull images built by CI rather than building from a local source tree.
    : "${GHCR_OWNER:?GHCR_OWNER must be set, e.g. web-programmierung-projekt}"
    # GHCR_TAG is the historical single-tag knob; the per-app vars take
    # precedence so a partial deploy can pin one app while leaving the other
    # at its current tag.
    : "${GHCR_BACKEND_TAG:=${GHCR_TAG:-latest}}"
    : "${GHCR_FRONTEND_TAG:=${GHCR_TAG:-latest}}"

    BACKEND_IMAGE="ghcr.io/${GHCR_OWNER}/backend:${GHCR_BACKEND_TAG}"
    FRONTEND_IMAGE="ghcr.io/${GHCR_OWNER}/frontend:${GHCR_FRONTEND_TAG}"

    echo "[deploy] pulling ${BACKEND_IMAGE} and ${FRONTEND_IMAGE}"
    docker pull "$BACKEND_IMAGE"
    docker pull "$FRONTEND_IMAGE"

    BACKEND_IMAGE="$BACKEND_IMAGE" FRONTEND_IMAGE="$FRONTEND_IMAGE" \
        docker compose -p "wohnmobil-${ENV}" -f "$COMPOSE_FILE" -f docker-compose.vm.yml up -d --remove-orphans
else
    docker compose -p "wohnmobil-${ENV}" -f "$COMPOSE_FILE" up -d --build --remove-orphans
fi

echo "[deploy] running alembic migrations against ${ENV}"
docker compose -p "wohnmobil-${ENV}" -f "$COMPOSE_FILE" exec -T backend alembic upgrade head

echo "[deploy] ${ENV} stack is up. Tail logs with: docker compose -p wohnmobil-${ENV} -f ${COMPOSE_FILE} logs -f"
