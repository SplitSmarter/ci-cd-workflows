#!/usr/bin/env bash
# Parse KEY=VALUE payload (supports multiline PEM values for SSH_KEY).
# Usage:
#   source parse_kv.sh
#   parse_kv_file /path/to/payload.env
#   # exports SSH_HOST, SSH_USER, SSH_KEY, etc.
#
# Important: OpenSSH PEM base64 lines can end with "=" (e.g. ECAwQ=).
# Those must NOT be treated as new KEY=VALUE entries while inside a PEM block.
set -euo pipefail

parse_kv_file() {
  local file="$1"
  local key="" value="" line="" in_pem=0

  key=""
  value=""
  in_pem=0

  while IFS= read -r line || [[ -n "$line" ]]; do
    # Inside PEM: append every line until END marker (do not parse KEY=)
    if [[ "$in_pem" -eq 1 ]]; then
      value+=$'\n'"$line"
      if [[ "$line" == -----END* ]]; then
        in_pem=0
      fi
      continue
    fi

    if [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
      if [[ -n "$key" ]]; then
        printf -v "$key" '%s' "$value"
        export "$key"
      fi
      key="${BASH_REMATCH[1]}"
      value="${BASH_REMATCH[2]}"
      if [[ "$value" == -----BEGIN* ]]; then
        in_pem=1
      fi
    elif [[ -n "$key" ]]; then
      value+=$'\n'"$line"
      if [[ "$line" == -----BEGIN* ]]; then
        in_pem=1
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
  # stdout: only those keys (preserving multiline / PEM values)
  local -a wanted=("$@")
  local tmp
  tmp="$(mktemp)"
  cat > "$tmp"
  local key
  for key in "${wanted[@]}"; do
    awk -v k="$key" '
      BEGIN { printing=0; in_pem=0 }
      $0 ~ "^"k"=" {
        printing=1
        print
        if ($0 ~ /-----BEGIN/) in_pem=1
        next
      }
      printing {
        if (in_pem) {
          print
          if ($0 ~ /^-----END/) { in_pem=0; printing=0 }
          next
        }
        if ($0 ~ /^[A-Za-z_][A-Za-z0-9_]*=/) {
          printing=0
          next
        }
        print
      }
    ' "$tmp"
  done
  rm -f "$tmp"
}
