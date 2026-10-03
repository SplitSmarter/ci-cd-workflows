#!/usr/bin/env bash
# Resolve an org Variable payload that was injected as an env var with the same name.
# Usage: load_payload.sh VARIABLE_NAME /path/to/out.env
set -euo pipefail

NAME="${1:?variable name required}"
OUT="${2:?output file required}"

if [[ -z "${!NAME:-}" ]]; then
  echo "ERROR: GitHub Variable/env '${NAME}' is empty or not set." >&2
  exit 1
fi

# Normalize Windows-style newlines; write payload without echoing secrets
printf '%s\n' "${!NAME}" | tr -d '\r' > "$OUT"
chmod 600 "$OUT"
echo "Loaded payload ${NAME} ($(wc -l < "$OUT") lines)"
