#!/usr/bin/env bash
set -euo pipefail
# stdin = full .env body; atomically replaces $DEPLOY_PATH/.env

ROOT="${DEPLOY_PATH:-/opt/splitsmarter}"

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

step() {
  echo "==> $*"
}

step "sync .env into ${ROOT}"

if [[ ! -d "$ROOT" ]]; then
  if ! mkdir -p "$ROOT" 2>/dev/null; then
    fail "cannot create ${ROOT} as $(id -un). Run bootstrap.sh as root, or: mkdir -p ${ROOT} && chown -R $(id -un):$(id -un) ${ROOT}"
  fi
fi

[[ -w "$ROOT" ]] || fail "${ROOT} is not writable by $(id -un). Fix: chown -R $(id -un):$(id -un) ${ROOT}"

tmp="$(mktemp "${ROOT}/.env.XXXXXX")" || fail "mktemp failed under ${ROOT} (permissions?)"
umask 077
if ! cat > "$tmp"; then
  rm -f "$tmp"
  fail "failed to write temp env file (empty stdin?)"
fi

if [[ ! -s "$tmp" ]]; then
  rm -f "$tmp"
  fail "refusing to write empty .env (stdin was empty)"
fi

chmod 600 "$tmp"
chown "$(id -u)":"$(id -g)" "$tmp" 2>/dev/null || true
mv -f "$tmp" "${ROOT}/.env" || fail "failed to replace ${ROOT}/.env"

echo "ok Wrote ${ROOT}/.env ($(wc -l < "${ROOT}/.env") lines)"
