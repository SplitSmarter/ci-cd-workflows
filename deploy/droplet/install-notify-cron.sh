#!/usr/bin/env bash
set -euo pipefail
# Usage: install-notify-cron.sh <mail-url> <five-field cron schedule>
# Replaces any existing splitsmarter-notify crontab line for this user.

MAIL_URL="${1:?mail url required}"
SCHEDULE="${2:?cron schedule required}"
ROOT="${DEPLOY_PATH:-/opt/splitsmarter}"
SCRIPT="${ROOT}/scripts/notify-mail.sh"
URL_FILE="${ROOT}/scripts/notify-mail.url"
MARKER="splitsmarter-notify"

if [[ ! -x "$SCRIPT" && ! -f "$SCRIPT" ]]; then
  echo "ERROR: missing ${SCRIPT}. Copy notify-mail.sh before installing the cron." >&2
  exit 1
fi
if [[ ! "$SCHEDULE" =~ ^[0-9*/,-]+([[:space:]]+[0-9*/,-]+){4}$ ]]; then
  echo "ERROR: cron schedule must be five fields (got: ${SCHEDULE})" >&2
  exit 1
fi

mkdir -p "${ROOT}/scripts" "${ROOT}/data/notify"
printf '%s\n' "$MAIL_URL" > "$URL_FILE"
chmod 644 "$URL_FILE"
chmod 755 "$SCRIPT"

existing="$(crontab -l 2>/dev/null || true)"
filtered="$(printf '%s\n' "$existing" | grep -v "$MARKER" || true)"
{
  printf '%s\n' "$filtered" | sed -e '/^[[:space:]]*$/d'
  printf '%s %s #%s\n' "$SCHEDULE" "$SCRIPT" "$MARKER"
} | crontab -

echo "installed ${SCHEDULE} ${SCRIPT} -> ${MAIL_URL}"
crontab -l | grep -F "$MARKER"

if command -v systemctl >/dev/null 2>&1; then
  if ! systemctl is-active --quiet cron 2>/dev/null; then
    echo "WARN: cron service is not active. On the host as root: systemctl enable --now cron" >&2
  fi
fi
