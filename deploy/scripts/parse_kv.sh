#!/usr/bin/env bash
# Parse KEY=VALUE payload (supports multiline values for SSH_KEY).
# Usage:
#   source parse_kv.sh
#   parse_kv_file /path/to/payload.env
#   # exports SSH_HOST, SSH_USER, SSH_KEY, etc.
set -euo pipefail

parse_kv_file() {
  local file="$1"
  local key="" value="" line=""
  key=""
  value=""
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
      if [[ -n "$key" ]]; then
        printf -v "$key" '%s' "$value"
        export "$key"
      fi
      key="${BASH_REMATCH[1]}"
      value="${BASH_REMATCH[2]}"
    else
      if [[ -n "$key" ]]; then
        value+=$'\n'"$line"
      fi
    fi
  done < "$file"
  if [[ -n "$key" ]]; then
    printf -v "$key" '%s' "$value"
    export "$key"
  fi
}

filter_kv_keys() {
  # stdin: full KEY=VALUE body
  # args: required key names
  # stdout: only those keys (preserving multiline values)
  local -a wanted=("$@")
  local tmp
  tmp="$(mktemp)"
  cat > "$tmp"
  local key
  for key in "${wanted[@]}"; do
    # Extract block starting at KEY= until next KEY= or EOF
    awk -v k="$key" '
      BEGIN { printing=0 }
      $0 ~ "^"k"=" {
        printing=1
        print
        next
      }
      printing && /^[A-Za-z_][A-Za-z0-9_]*=/ { printing=0 }
      printing { print }
    ' "$tmp"
  done
  rm -f "$tmp"
}
