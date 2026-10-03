#!/usr/bin/env bash
set -euo pipefail
# Fail-fast host readiness checks for deploy user.
# Usage: check-host.sh [--require-env] [--require-scripts]
#
# Exit non-zero with a clear ERROR line on the first failed check.

ROOT="${DEPLOY_PATH:-/opt/splitsmarter}"
REQUIRE_ENV=0
REQUIRE_SCRIPTS=0

for arg in "$@"; do
  case "$arg" in
    --require-env) REQUIRE_ENV=1 ;;
    --require-scripts) REQUIRE_SCRIPTS=1 ;;
    *)
      echo "ERROR: unknown argument: $arg" >&2
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

if [[ "$REQUIRE_SCRIPTS" -eq 1 ]]; then
  step "required scripts under ${ROOT}/scripts"
  [[ -d "${ROOT}/scripts" ]] || fail "${ROOT}/scripts missing. Re-run bootstrap or sync-host-secrets."
  for s in validate-env.sh sync-env.sh deploy-service.sh check-host.sh; do
    [[ -x "${ROOT}/scripts/${s}" ]] || fail "missing or not executable: ${ROOT}/scripts/${s}"
  done
fi

if [[ "$REQUIRE_ENV" -eq 1 ]]; then
  step "env file ${ROOT}/.env"
  [[ -f "${ROOT}/.env" ]] || fail "${ROOT}/.env missing. Run sync-host-secrets first."
  [[ -r "${ROOT}/.env" ]] || fail "${ROOT}/.env is not readable by $(id -un)."
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

echo "ok host checks passed"
