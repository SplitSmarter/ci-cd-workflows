#!/usr/bin/env bash
set -euo pipefail
# Startup step 1 of 2 (host): run once as root on a new Droplet (or via cloud-init).
#
# Order:
#   1) bootstrap.sh  → Docker, deploy user, dirs, ownership, nginx edge, UFW
#   2) sync-host-secrets (CI) → copies scripts + writes env/<service>.env as deploy
#   3) app deploy (CI) → compose pull/up + health (+ /mail/ edge check)
#
# Staging kit (run from here after scp as deploy):
#   /tmp/deploy/bootstrap.sh
#   /tmp/deploy/ensure-edge.sh
#   /tmp/deploy/nginx/...
#
# If /tmp/deploy is missing before first scp, as root:
#   bash prepare-staging.sh
#   # or: mkdir -p /tmp/deploy && chown deploy:deploy /tmp/deploy && chmod 755 /tmp/deploy

DEPLOY_USER="${DEPLOY_USER:-deploy}"
DEPLOY_HOME="/home/${DEPLOY_USER}"
ROOT="${DEPLOY_PATH:-/opt/splitsmarter}"
STAGING_DIR="${STAGING_DIR:-/tmp/deploy}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HARDEN_SSH="${HARDEN_SSH:-1}"
# Optional: UFW_HTTP_ALLOW_FROM="10.0.0.5 10.116.0.8" for internal-only :80

fail() { echo "ERROR: $*" >&2; exit 1; }

[[ "$(id -u)" -eq 0 ]] || fail "bootstrap.sh must run as root (e.g. sudo bash bootstrap.sh)"

export DEBIAN_FRONTEND=noninteractive

echo "==> bootstrap as root → DEPLOY_PATH=${ROOT} DEPLOY_USER=${DEPLOY_USER} STAGING_DIR=${STAGING_DIR}"

# Staging dir for bootstrap/edge kit uploads (deploy user must be able to scp here)
echo "==> ensuring staging ${STAGING_DIR} (owner ${DEPLOY_USER})"
mkdir -p "$STAGING_DIR"
chmod 755 "$STAGING_DIR"

# Edge kit must be present next to this script (scp full droplet/ into staging first)
[[ -f "${SCRIPT_DIR}/ensure-edge.sh" ]] || fail "missing ${SCRIPT_DIR}/ensure-edge.sh — scp ensure-edge.sh into ${STAGING_DIR}/"
[[ -d "${SCRIPT_DIR}/nginx" ]] || fail "missing ${SCRIPT_DIR}/nginx/ — scp -r nginx into ${STAGING_DIR}/"
[[ -f "${SCRIPT_DIR}/nginx/splitsmarter.conf" ]] || fail "missing ${SCRIPT_DIR}/nginx/splitsmarter.conf"
[[ -d "${SCRIPT_DIR}/nginx/locations" ]] || fail "missing ${SCRIPT_DIR}/nginx/locations/"
echo "ok edge kit present under ${SCRIPT_DIR}"

apt-get update
apt-get install -y --no-install-recommends ca-certificates curl gnupg ufw

# Docker Engine + Compose plugin
if ! command -v docker >/dev/null 2>&1; then
  echo "==> installing Docker Engine + Compose plugin"
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
  . /usr/lib/os-release 2>/dev/null || . /etc/os-release
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${VERSION_CODENAME} stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
fi

systemctl enable --now docker

if ! id "$DEPLOY_USER" >/dev/null 2>&1; then
  echo "==> creating user ${DEPLOY_USER}"
  useradd -m -s /bin/bash "$DEPLOY_USER"
fi
usermod -aG docker "$DEPLOY_USER"
echo "==> ${DEPLOY_USER} in groups: $(id -nG "$DEPLOY_USER")"

# Optional: refresh authorized_keys only if caller passes a key (SSH may already be configured)
mkdir -p "${DEPLOY_HOME}/.ssh"
chmod 700 "${DEPLOY_HOME}/.ssh"
if [[ -n "${DEPLOY_SSH_PUBLIC_KEY:-}" ]]; then
  echo "==> writing ${DEPLOY_HOME}/.ssh/authorized_keys from DEPLOY_SSH_PUBLIC_KEY"
  echo "$DEPLOY_SSH_PUBLIC_KEY" > "${DEPLOY_HOME}/.ssh/authorized_keys"
  chmod 600 "${DEPLOY_HOME}/.ssh/authorized_keys"
elif [[ -f "${DEPLOY_HOME}/.ssh/authorized_keys" ]]; then
  echo "==> keeping existing ${DEPLOY_HOME}/.ssh/authorized_keys"
else
  echo "WARN: no authorized_keys for ${DEPLOY_USER} and DEPLOY_SSH_PUBLIC_KEY unset — CI SSH as deploy will fail until a key is installed"
fi
chown -R "${DEPLOY_USER}:${DEPLOY_USER}" "${DEPLOY_HOME}/.ssh"

# Staging writable by deploy for future edge kit uploads
chown "${DEPLOY_USER}:${DEPLOY_USER}" "$STAGING_DIR"
chmod 755 "$STAGING_DIR"
# If we are running from staging, keep kit owned by deploy so scp can overwrite later
if [[ "$SCRIPT_DIR" == "$STAGING_DIR" ]]; then
  chown -R "${DEPLOY_USER}:${DEPLOY_USER}" "$STAGING_DIR"
  chmod 755 "${STAGING_DIR}/ensure-edge.sh" "${STAGING_DIR}/bootstrap.sh" 2>/dev/null || true
fi

echo "==> creating ${ROOT}/scripts and ${ROOT}/env (owned by ${DEPLOY_USER})"
mkdir -p "${ROOT}/scripts" "${ROOT}/env"
chown -R "${DEPLOY_USER}:${DEPLOY_USER}" "$ROOT"
chmod 755 "$ROOT" "${ROOT}/scripts"
chmod 750 "${ROOT}/env"

if [[ -f "${SCRIPT_DIR}/sync-env.sh" ]]; then
  echo "==> seeding host scripts from ${SCRIPT_DIR}"
  cp -f "${SCRIPT_DIR}/deploy-service.sh" "${ROOT}/scripts/" 2>/dev/null || true
  cp -f "${SCRIPT_DIR}/sync-env.sh" "${ROOT}/scripts/" 2>/dev/null || true
  cp -f "${SCRIPT_DIR}/validate-env.sh" "${ROOT}/scripts/" 2>/dev/null || true
  cp -f "${SCRIPT_DIR}/check-host.sh" "${ROOT}/scripts/" 2>/dev/null || true
  cp -f "${SCRIPT_DIR}/docker-compose.yml" "${ROOT}/docker-compose.yml" 2>/dev/null || true
  chmod 755 "${ROOT}/scripts/"*.sh 2>/dev/null || true
else
  echo "==> no sibling app scripts next to bootstrap.sh; CI sync/deploy will upload them"
fi

chown -R "${DEPLOY_USER}:${DEPLOY_USER}" "$ROOT"
chmod 750 "${ROOT}/env"

if [[ "$HARDEN_SSH" == "1" ]]; then
  echo "==> SSH hardening (PasswordAuthentication no)"
  mkdir -p /etc/ssh/sshd_config.d
  cat > /etc/ssh/sshd_config.d/50-splitsmarter-deploy.conf <<'EOF'
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
EOF
  systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true
fi

echo "==> installing nginx edge (path routes, UFW 80)"
chmod +x "${SCRIPT_DIR}/ensure-edge.sh" || true
bash "${SCRIPT_DIR}/ensure-edge.sh"

echo ""
echo "Bootstrap complete (startup step 1/2)."
echo "  DEPLOY_PATH=${ROOT}  owner=${DEPLOY_USER}:${DEPLOY_USER}"
echo "  STAGING_DIR=${STAGING_DIR}  owner=${DEPLOY_USER}:${DEPLOY_USER} (scp edge kit here)"
echo "  edge: nginx /mail/ → 127.0.0.1:8083 (containers stay localhost-only)"
echo ""
echo "Next: run GitHub Action sync-host-secrets, then app deploy."
echo "Prefer Managed Postgres in the same VPC; never expose 5432 or 8083 publicly."
