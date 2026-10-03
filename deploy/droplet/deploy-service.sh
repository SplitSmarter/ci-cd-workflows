#!/usr/bin/env bash
set -euo pipefail
# Usage: deploy-service.sh <compose_service> <image_ref> [container_port] [health_path]
# Example: deploy-service.sh mail-service ghcr.io/splitsmarter/mail-service:abc1234 8083 /health

SERVICE="${1:?compose service required}"
IMAGE="${2:?image ref required}"
PORT="${3:-8083}"
HEALTH_PATH="${4:-/health}"
ROOT="${DEPLOY_PATH:-/opt/splitsmarter}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

step() {
  echo "==> $*"
}

step "preflight host"
if [[ -x "${SCRIPT_DIR}/check-host.sh" ]]; then
  # shellcheck disable=SC1091
  DEPLOY_PATH="$ROOT" "${SCRIPT_DIR}/check-host.sh" --require-env
elif [[ -x "${ROOT}/scripts/check-host.sh" ]]; then
  DEPLOY_PATH="$ROOT" "${ROOT}/scripts/check-host.sh" --require-env
else
  command -v docker >/dev/null 2>&1 || fail "docker not found. Run bootstrap.sh as root."
  docker info >/dev/null 2>&1 || fail "cannot access Docker daemon as $(id -un)."
  [[ -f "${ROOT}/.env" ]] || fail "${ROOT}/.env missing. Run sync-host-secrets first."
fi

step "cwd ${ROOT}"
cd "$ROOT" || fail "cannot cd to ${ROOT}"
[[ -f "${ROOT}/docker-compose.yml" ]] || fail "missing ${ROOT}/docker-compose.yml"

export MAIL_IMAGE="$IMAGE"
step "image ${IMAGE} service ${SERVICE} port ${PORT} health ${HEALTH_PATH}"

if [[ -n "${GHCR_USERNAME:-}" && -n "${GHCR_TOKEN:-}" ]]; then
  step "docker login ghcr.io"
  echo "$GHCR_TOKEN" | docker login ghcr.io -u "$GHCR_USERNAME" --password-stdin \
    || fail "docker login to ghcr.io failed (check GHCR_USERNAME / GHCR_TOKEN)."
else
  echo "WARN: GHCR_USERNAME/GHCR_TOKEN unset; skipping docker login"
fi

step "docker compose pull ${SERVICE}"
docker compose pull "$SERVICE" || fail "compose pull failed for ${SERVICE} (${IMAGE})."

step "docker compose up ${SERVICE}"
docker compose up -d --no-deps --force-recreate "$SERVICE" \
  || fail "compose up failed for ${SERVICE}."

# Normalize health path
if [[ "$HEALTH_PATH" != /* ]]; then
  HEALTH_PATH="/$HEALTH_PATH"
fi

step "health check http://127.0.0.1:${PORT}${HEALTH_PATH}"
for i in $(seq 1 30); do
  if curl -fsS "http://127.0.0.1:${PORT}${HEALTH_PATH}" >/dev/null; then
    echo "ok healthy (${i}/30)"
    exit 0
  fi
  sleep 2
done

docker compose logs --no-color --tail=100 "$SERVICE" || true
fail "health check failed for ${SERVICE} on :${PORT}${HEALTH_PATH} after ~60s"
