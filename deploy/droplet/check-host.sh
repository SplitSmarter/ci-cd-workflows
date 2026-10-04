#!/usr/bin/env bash
set -euo pipefail
# Fail-fast host readiness checks for deploy user.
# Usage:
#   check-host.sh [--require-env <service_name>] [--require-scripts] [--require-edge <path>]
#
# --require-env mail-service  → require env/mail-service.env present and non-empty
# --require-edge /mail        → nginx active + soft UFW 80 check (traffic curl is in deploy-service)
# Exit non-zero with a clear ERROR line on the first failed check.

ROOT="${DEPLOY_PATH:-/opt/splitsmarter}"
REQUIRE_ENV=0
REQUIRE_SCRIPTS=0
REQUIRE_EDGE=0
SERVICE_NAME=""
EDGE_PATH=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --require-env)
      REQUIRE_ENV=1
      shift
      if [[ $# -gt 0 && "$1" != --* ]]; then
        SERVICE_NAME="$1"
        shift
      fi
      ;;
    --require-scripts)
      REQUIRE_SCRIPTS=1
      shift
      ;;
    --require-edge)
      REQUIRE_EDGE=1
      shift
      if [[ $# -gt 0 && "$1" != --* ]]; then
        EDGE_PATH="$1"
        shift
      fi
      ;;
    *)
      echo "ERROR: unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

step() {
  echo "==> $*"
}

step "user=$(id -un) uid=$(id -u) groups=$(id -Gn)"
step "deploy path ${ROOT}"

[[ -d "$ROOT" ]] || fail "${ROOT} does not exist. Run deploy/droplet/bootstrap.sh as root on this host."
[[ -w "$ROOT" ]] || fail "${ROOT} is not writable by $(id -un). Fix ownership: chown -R $(id -un):$(id -un) ${ROOT}"

if [[ ! -d "${ROOT}/env" ]]; then
  mkdir -p "${ROOT}/env" 2>/dev/null || fail "${ROOT}/env missing and cannot create. Run bootstrap or: mkdir -p ${ROOT}/env && chown $(id -un) ${ROOT}/env"
fi
[[ -w "${ROOT}/env" ]] || fail "${ROOT}/env is not writable by $(id -un)."

if [[ "$REQUIRE_SCRIPTS" -eq 1 ]]; then
  step "required scripts under ${ROOT}/scripts"
  [[ -d "${ROOT}/scripts" ]] || fail "${ROOT}/scripts missing. Re-run bootstrap or sync-host-secrets."
  for s in validate-env.sh sync-env.sh deploy-service.sh check-host.sh; do
    [[ -x "${ROOT}/scripts/${s}" ]] || fail "missing or not executable: ${ROOT}/scripts/${s}"
  done
fi

if [[ "$REQUIRE_ENV" -eq 1 ]]; then
  [[ -n "$SERVICE_NAME" ]] || fail "--require-env needs a service_name (e.g. --require-env mail-service)"
  ENV_FILE="${ROOT}/env/${SERVICE_NAME}.env"
  step "secrets file ${ENV_FILE}"
  [[ -f "$ENV_FILE" ]] || fail "${ENV_FILE} missing. Run sync-host-secrets for service=${SERVICE_NAME} first."
  [[ -s "$ENV_FILE" ]] || fail "${ENV_FILE} is empty. Re-run sync-host-secrets with a non-empty APPSECRET."
  [[ -r "$ENV_FILE" ]] || fail "${ENV_FILE} is not readable by $(id -un)."
fi

step "docker CLI"
command -v docker >/dev/null 2>&1 || fail "docker not found on PATH for $(id -un). Run bootstrap.sh as root (installs Docker + adds deploy to docker group)."

step "docker daemon access"
if ! docker info >/dev/null 2>&1; then
  fail "cannot talk to Docker daemon as $(id -un). Ensure Docker is running and $(id -un) is in the docker group (new SSH session after usermod -aG docker)."
fi

step "docker compose plugin"
if ! docker compose version >/dev/null 2>&1; then
  fail "docker compose plugin missing. Install docker-compose-plugin (see bootstrap.sh)."
fi

step "compose file"
if [[ -f "${ROOT}/docker-compose.yml" ]]; then
  echo "found ${ROOT}/docker-compose.yml"
else
  echo "WARN: ${ROOT}/docker-compose.yml not present yet (ok before first deploy copy)"
fi

if [[ "$REQUIRE_EDGE" -eq 1 ]]; then
  [[ -n "$EDGE_PATH" ]] || fail "--require-edge needs a path (e.g. --require-edge /mail)"
  [[ "$EDGE_PATH" == /* ]] || EDGE_PATH="/${EDGE_PATH}"
  EDGE_PATH="${EDGE_PATH%/}"
  step "nginx edge path ${EDGE_PATH}"
  if systemctl is-active --quiet nginx 2>/dev/null; then
    echo "nginx is active"
  else
    fail "nginx is not active. On the host as root: copy deploy/droplet/ and run sudo bash ensure-edge.sh"
  fi
  # Soft check: UFW status often needs root; warn if we cannot read it
  if command -v ufw >/dev/null 2>&1; then
    if ufw status 2>/dev/null | grep -qE 'Status: active'; then
      if ufw status 2>/dev/null | grep -qE '80/tcp'; then
        echo "ufw allows 80/tcp (or from specific sources)"
      else
        echo "WARN: ufw active but no 80/tcp rule visible (run ensure-edge.sh as root if needed)"
      fi
    else
      echo "WARN: cannot read ufw status as $(id -un) (ok if DO Cloud Firewall enforces 80)"
    fi
  fi
fi

echo "ok host checks passed"
