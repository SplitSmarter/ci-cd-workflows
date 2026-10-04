#!/usr/bin/env bash
set -euo pipefail
# Run once as root before the deploy user scp's the edge kit.
# Creates /tmp/deploy owned by deploy so:
#   scp bootstrap.sh ensure-edge.sh + nginx/ → deploy@host:/tmp/deploy/
# then as root:
#   cd /tmp/deploy && bash bootstrap.sh

DEPLOY_USER="${DEPLOY_USER:-deploy}"
STAGING_DIR="${STAGING_DIR:-/tmp/deploy}"

fail() { echo "ERROR: $*" >&2; exit 1; }
[[ "$(id -u)" -eq 0 ]] || fail "prepare-staging.sh must run as root"

if ! id "$DEPLOY_USER" >/dev/null 2>&1; then
  fail "user ${DEPLOY_USER} does not exist yet. Create it / install SSH key first, or run a full bootstrap as root from a copied kit."
fi

echo "==> creating ${STAGING_DIR} for ${DEPLOY_USER}"
mkdir -p "$STAGING_DIR"
chown "${DEPLOY_USER}:${DEPLOY_USER}" "$STAGING_DIR"
chmod 755 "$STAGING_DIR"

echo "ok ${STAGING_DIR} ready — scp as ${DEPLOY_USER}:"
echo "  bootstrap.sh  ensure-edge.sh  nginx/"
echo "then as root:  cd ${STAGING_DIR} && bash bootstrap.sh"
