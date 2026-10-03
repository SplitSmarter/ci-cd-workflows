#!/usr/bin/env bash
set -euo pipefail
# Usage: deploy-service.sh <compose_service> <image_ref> [container_port] [health_path]
# Example: deploy-service.sh mail-service ghcr.io/splitsmarter/mail-service:abc1234 8083 /health

SERVICE="${1:?compose service required}"
IMAGE="${2:?image ref required}"
PORT="${3:-8083}"
HEALTH_PATH="${4:-/health}"
ROOT="${DEPLOY_PATH:-/opt/splitsmarter}"

cd "$ROOT"

export MAIL_IMAGE="$IMAGE"

if [[ -n "${GHCR_USERNAME:-}" && -n "${GHCR_TOKEN:-}" ]]; then
  echo "$GHCR_TOKEN" | docker login ghcr.io -u "$GHCR_USERNAME" --password-stdin
fi

docker compose pull "$SERVICE"
docker compose up -d --no-deps --force-recreate "$SERVICE"

# Normalize health path
if [[ "$HEALTH_PATH" != /* ]]; then
  HEALTH_PATH="/$HEALTH_PATH"
fi

for _ in $(seq 1 30); do
  if curl -fsS "http://127.0.0.1:${PORT}${HEALTH_PATH}" >/dev/null; then
    echo "healthy"
    exit 0
  fi
  sleep 2
done

docker compose logs --no-color --tail=100 "$SERVICE" || true
echo "ERROR: health check failed for $SERVICE on :${PORT}${HEALTH_PATH}" >&2
exit 1
