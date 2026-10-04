#!/usr/bin/env bash
set -euo pipefail
# Usage: deploy-service.sh <compose_service> <image_ref> [container_port] [health_path]
# Example: deploy-service.sh mail-service ghcr.io/splitsmarter/mail-service:abc1234 8083 /health

SERVICE="${1:?compose service required}"
IMAGE="${2:?image ref required}"
PORT="${3:-8083}"
HEALTH_PATH="${4:-/health}"
# Optional 5th arg or EDGE_PATH env: public path prefix via nginx (e.g. /mail)
EDGE_PATH="${5:-${EDGE_PATH:-}}"
ROOT="${DEPLOY_PATH:-/opt/splitsmarter}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ROOT}/env/${SERVICE}.env"

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

step() {
  echo "==> $*"
}

step "preflight host + secrets file for ${SERVICE}"
CHECK_ARGS=(--require-env "$SERVICE")
if [[ -n "$EDGE_PATH" ]]; then
  CHECK_ARGS+=(--require-edge "$EDGE_PATH")
fi
if [[ -x "${SCRIPT_DIR}/check-host.sh" ]]; then
  DEPLOY_PATH="$ROOT" "${SCRIPT_DIR}/check-host.sh" "${CHECK_ARGS[@]}"
elif [[ -x "${ROOT}/scripts/check-host.sh" ]]; then
  DEPLOY_PATH="$ROOT" "${ROOT}/scripts/check-host.sh" "${CHECK_ARGS[@]}"
else
  command -v docker >/dev/null 2>&1 || fail "docker not found. Run bootstrap.sh as root."
  docker info >/dev/null 2>&1 || fail "cannot access Docker daemon as $(id -un)."
  [[ -s "$ENV_FILE" ]] || fail "${ENV_FILE} missing or empty. Run sync-host-secrets first."
fi

step "cwd ${ROOT}"
cd "$ROOT" || fail "cannot cd to ${ROOT}"
[[ -f "${ROOT}/docker-compose.yml" ]] || fail "missing ${ROOT}/docker-compose.yml"
[[ -s "$ENV_FILE" ]] || fail "${ENV_FILE} missing or empty"

# Compose template for mail-service uses MAIL_IMAGE; keep plain name for debugging.
export MAIL_IMAGE="$IMAGE"
step "image ${IMAGE} service ${SERVICE} port ${PORT} health ${HEALTH_PATH} env_file ${ENV_FILE}"

if [[ -n "${GHCR_USERNAME:-}" && -n "${GHCR_TOKEN:-}" ]]; then
  step "docker login ghcr.io"
  echo "$GHCR_TOKEN" | docker login ghcr.io -u "$GHCR_USERNAME" --password-stdin \
    || fail "docker login to ghcr.io failed (check GHCR_USERNAME / GHCR_TOKEN)."
else
  echo "WARN: GHCR_USERNAME/GHCR_TOKEN unset; skipping docker login"
fi

# Quit any already-running instance of this compose service before recreate.
step "stop existing ${SERVICE} (if any)"
docker compose stop "$SERVICE" 2>/dev/null || true
docker compose rm -f "$SERVICE" 2>/dev/null || true
# Clear any leftover container still publishing the host port (stuck prior deploy)
leftovers="$(docker ps -q --filter "publish=${PORT}" 2>/dev/null || true)"
if [[ -n "$leftovers" ]]; then
  echo "WARN: removing leftover container(s) still publishing :${PORT}"
  # shellcheck disable=SC2086
  docker stop $leftovers || true
  # shellcheck disable=SC2086
  docker rm -f $leftovers || true
fi

step "docker compose pull ${SERVICE}"
docker compose pull "$SERVICE" || fail "compose pull failed for ${SERVICE} (${IMAGE})."

step "docker compose up ${SERVICE}"
docker compose up -d --no-deps --force-recreate --remove-orphans "$SERVICE" \
  || fail "compose up failed for ${SERVICE}."

if [[ "$HEALTH_PATH" != /* ]]; then
  HEALTH_PATH="/$HEALTH_PATH"
fi

step "health check http://127.0.0.1:${PORT}${HEALTH_PATH}"
healthy=0
for i in $(seq 1 30); do
  if curl -fsS "http://127.0.0.1:${PORT}${HEALTH_PATH}" >/dev/null; then
    echo "ok healthy direct (${i}/30)"
    healthy=1
    break
  fi
  sleep 2
done

if [[ "$healthy" -ne 1 ]]; then
  docker compose logs --no-color --tail=100 "$SERVICE" || true
  fail "health check failed for ${SERVICE} on :${PORT}${HEALTH_PATH} after ~60s"
fi

# Traffic via nginx path (containers stay on 127.0.0.1; no public 8083)
if [[ -n "$EDGE_PATH" ]]; then
  [[ "$EDGE_PATH" == /* ]] || EDGE_PATH="/${EDGE_PATH}"
  EDGE_PATH="${EDGE_PATH%/}"
  EDGE_URL="http://127.0.0.1${EDGE_PATH}${HEALTH_PATH}"
  step "edge traffic check ${EDGE_URL}"
  edge_ok=0
  for i in $(seq 1 15); do
    if curl -fsS "$EDGE_URL" >/dev/null; then
      echo "ok healthy via nginx (${i}/15)"
      edge_ok=1
      break
    fi
    sleep 2
  done
  if [[ "$edge_ok" -ne 1 ]]; then
    fail "nginx edge check failed for ${EDGE_URL}. As root: sudo bash ensure-edge.sh (installs nginx + UFW 80). Do not expose port ${PORT} publicly."
  fi
fi

echo "ok deploy ${SERVICE}"
exit 0
