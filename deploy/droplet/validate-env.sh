#!/usr/bin/env bash
set -euo pipefail
# Usage: validate-env.sh KEY [KEY ...]
# Checks KEY= is present and non-empty in $DEPLOY_PATH/.env
# Prints only failing key names (never values).

ROOT="${DEPLOY_PATH:-/opt/splitsmarter}"
ENV_FILE="${ROOT}/.env"
failed=0

if [[ "$#" -eq 0 ]]; then
  echo "ERROR: validate-env.sh requires at least one KEY" >&2
  exit 2
fi

echo "==> validating ${#} required keys in ${ENV_FILE}"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "missing_env_file"
  echo "ERROR: $ENV_FILE does not exist. Run sync-host-secrets first." >&2
  exit 1
fi

for key in "$@"; do
  # Match KEY=... on its own line; value must be non-empty (allows multiline continuation)
  if ! grep -qE "^${key}=." "$ENV_FILE"; then
    echo "$key"
    failed=1
  fi
done

if [[ "$failed" -ne 0 ]]; then
  echo "ERROR: one or more required keys missing or empty in $ENV_FILE" >&2
  echo "Run sync-host-secrets for this environment/service." >&2
  exit 1
fi

echo "ok env keys present"
