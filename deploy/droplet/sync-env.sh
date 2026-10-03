#!/usr/bin/env bash
set -euo pipefail
# stdin = full .env body; atomically replaces $DEPLOY_PATH/.env
ROOT="${DEPLOY_PATH:-/opt/splitsmarter}"
mkdir -p "$ROOT"
tmp="$(mktemp "$ROOT/.env.XXXXXX")"
umask 077
cat > "$tmp"
chmod 600 "$tmp"
chown "$(id -u)":"$(id -g)" "$tmp" 2>/dev/null || true
mv -f "$tmp" "$ROOT/.env"
echo "Wrote $ROOT/.env"
