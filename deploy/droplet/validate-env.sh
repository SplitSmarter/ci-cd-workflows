#!/usr/bin/env bash
set -euo pipefail
# Presence-only check for a service env file (no per-key enumeration).
# Usage: validate-env.sh <service_name>
# Checks that $DEPLOY_PATH/env/<service_name>.env exists and is non-empty.

ROOT="${DEPLOY_PATH:-/opt/splitsmarter}"
SERVICE_NAME="${1:-${SERVICE_NAME:-}}"

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

[[ -n "$SERVICE_NAME" ]] || fail "service_name required (arg1 or SERVICE_NAME=)"
[[ "$SERVICE_NAME" =~ ^[A-Za-z0-9_-]+$ ]] || fail "invalid service_name: ${SERVICE_NAME}"

ENV_FILE="${ROOT}/env/${SERVICE_NAME}.env"

echo "==> checking secrets file present: ${ENV_FILE}"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "missing_env_file"
  echo "ERROR: ${ENV_FILE} does not exist. Run sync-host-secrets for service=${SERVICE_NAME} first." >&2
  exit 1
fi

if [[ ! -s "$ENV_FILE" ]]; then
  echo "empty_env_file"
  echo "ERROR: ${ENV_FILE} is empty. Re-run sync-host-secrets with a non-empty APPSECRET Variable." >&2
  exit 1
fi

if [[ ! -r "$ENV_FILE" ]]; then
  echo "ERROR: ${ENV_FILE} is not readable by $(id -un)." >&2
  exit 1
fi

echo "ok secrets file present ${ENV_FILE} ($(wc -l < "${ENV_FILE}") lines)"
