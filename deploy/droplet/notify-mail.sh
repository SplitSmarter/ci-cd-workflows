#!/usr/bin/env bash
set -euo pipefail
# Post new notify contacts to mail-service.
# Skips the call when the contacts file is missing or empty.
# Successful contacts are recorded so the next run does not send them again.

ROOT="${DEPLOY_PATH:-/opt/splitsmarter}"
CONTACTS="${ROOT}/data/notify/contacts.jsonl"
SENT="${ROOT}/data/notify/contacts.sent"
URL_FILE="${ROOT}/scripts/notify-mail.url"

if [[ ! -s "$CONTACTS" ]]; then
  exit 0
fi

MAIL_URL="${MAIL_NOTIFY_URL:-}"
if [[ -z "$MAIL_URL" && -s "$URL_FILE" ]]; then
  IFS= read -r MAIL_URL < "$URL_FILE" || true
fi
if [[ -z "$MAIL_URL" ]]; then
  echo "ERROR: mail URL is not set" >&2
  exit 1
fi

mkdir -p "$(dirname "$SENT")"
touch "$SENT"

json_escape() {
  local value="$1"
  value=${value//\\/\\\\}
  value=${value//\"/\\\"}
  printf '%s' "$value"
}

extract_contact() {
  local line="$1"
  if [[ "$line" =~ \"contact\"[[:space:]]*:[[:space:]]*\"([^\"]*)\" ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
  fi
}

while IFS= read -r line || [[ -n "$line" ]]; do
  [[ -n "${line//[[:space:]]/}" ]] || continue
  contact="$(extract_contact "$line")"
  [[ -n "$contact" ]] || continue
  if grep -Fxq -- "$contact" "$SENT"; then
    continue
  fi
  payload="$(printf '{"contact":"%s"}' "$(json_escape "$contact")")"
  code="$(
    curl -sS -o /dev/null -w '%{http_code}' \
      -X POST \
      -H 'Content-Type: application/json' \
      --data "$payload" \
      "$MAIL_URL"
  )" || continue
  if [[ "$code" == 2* ]]; then
    printf '%s\n' "$contact" >> "$SENT"
  fi
done < "$CONTACTS"
