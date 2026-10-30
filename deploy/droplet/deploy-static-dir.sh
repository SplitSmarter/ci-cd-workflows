#!/usr/bin/env bash
set -euo pipefail
# Usage: deploy-static-dir.sh <tarball> <dest-dir-name> <container-port> <health-path>
# Copies a static site into DEPLOY_PATH/<dest> without replacing that directory,
# then checks the website container and the host edge both serve the guide.

TARBALL="${1:?tarball required}"
DEST_NAME="${2:?destination directory name required}"
PORT="${3:?container port required}"
HEALTH_PATH="${4:?health path required}"
ROOT="${DEPLOY_PATH:-/opt/splitsmarter}"
DEST="${ROOT}/${DEST_NAME}"
STAGING="${ROOT}/${DEST_NAME}-staging"

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

step() {
  echo "==> $*"
}

[[ "$HEALTH_PATH" == /* ]] || HEALTH_PATH="/${HEALTH_PATH}"
[[ -f "$TARBALL" ]] || fail "tarball not found: ${TARBALL}"
mkdir -p "$DEST"
[[ -w "$DEST" ]] || fail "${DEST} is not writable by $(id -un). On the host as root: chown -R $(id -un):$(id -un) ${DEST}"

step "extract ${TARBALL} into ${STAGING}"
rm -rf "$STAGING"
mkdir -p "$STAGING" "$DEST"
tar -xzf "$TARBALL" -C "$STAGING"

step "sync into ${DEST} (keep directory inode for the container mount)"
cp -a "${STAGING}/." "${DEST}/"
while IFS= read -r -d '' path; do
  rel="${path#"${DEST}/"}"
  if [[ ! -e "${STAGING}/${rel}" ]]; then
    rm -rf "$path"
  fi
done < <(find "$DEST" -mindepth 1 -depth -print0)
rm -rf "$STAGING"
chmod -R a+rX "$DEST"

check_guide() {
  local url="$1"
  local body
  body="$(curl -fsS "$url")" || fail "request failed: ${url}"
  printf '%s' "$body" | grep -q '/guide/_next/' \
    || fail "${url} did not serve the user guide (missing /guide/_next/)"
  echo "ok ${url}"
}

step "container check http://127.0.0.1:${PORT}${HEALTH_PATH}"
check_guide "http://127.0.0.1:${PORT}${HEALTH_PATH}"

step "edge check http://127.0.0.1${HEALTH_PATH}"
check_guide "http://127.0.0.1${HEALTH_PATH}"

rm -f "$TARBALL"
echo "ok static dir ${DEST_NAME} published to ${DEST}"
