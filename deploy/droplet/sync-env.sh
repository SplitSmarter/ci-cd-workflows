#!/usr/bin/env bash
set -euo pipefail
# stdin = full env body for one service; atomically replaces env/<service_name>.env
# Usage: sync-env.sh <service_name>
#   SERVICE_NAME may also be set in the environment.

ROOT="${DEPLOY_PATH:-/opt/splitsmarter}"
SERVICE_NAME="${1:-${SERVICE_NAME:-}}"

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

step() {
  echo "==> $*"
}

[[ -n "$SERVICE_NAME" ]] || fail "service_name required (arg1 or SERVICE_NAME=)"
[[ "$SERVICE_NAME" =~ ^[A-Za-z0-9_-]+$ ]] || fail "invalid service_name: ${SERVICE_NAME}"

ENV_DIR="${ROOT}/env"
ENV_FILE="${ENV_DIR}/${SERVICE_NAME}.env"

step "sync env file ${ENV_FILE}"

if [[ ! -d "$ROOT" ]]; then
  if ! mkdir -p "$ROOT" 2>/dev/null; then
    fail "cannot create ${ROOT} as $(id -un). Run bootstrap.sh as root, or: mkdir -p ${ROOT} && chown -R $(id -un):$(id -un) ${ROOT}"
  fi
fi

[[ -w "$ROOT" ]] || fail "${ROOT} is not writable by $(id -un). Fix: chown -R $(id -un):$(id -un) ${ROOT}"

mkdir -p "$ENV_DIR" || fail "cannot create ${ENV_DIR}"
[[ -w "$ENV_DIR" ]] || fail "${ENV_DIR} is not writable by $(id -un)"

tmp="$(mktemp "${ENV_DIR}/.${SERVICE_NAME}.env.XXXXXX")" || fail "mktemp failed under ${ENV_DIR}"
umask 077
if ! cat > "$tmp"; then
  rm -f "$tmp"
  fail "failed to write temp env file"
fi

if [[ ! -s "$tmp" ]]; then
  rm -f "$tmp"
  fail "refusing to write empty env file (stdin was empty). Check APPSECRET Variable for ${SERVICE_NAME}."
fi

chmod 600 "$tmp"
chown "$(id -u)":"$(id -g)" "$tmp" 2>/dev/null || true
mv -f "$tmp" "$ENV_FILE" || fail "failed to replace ${ENV_FILE}"

[[ -s "$ENV_FILE" ]] || fail "${ENV_FILE} missing or empty after write"

echo "ok Wrote ${ENV_FILE} ($(wc -l < "${ENV_FILE}") lines)"
