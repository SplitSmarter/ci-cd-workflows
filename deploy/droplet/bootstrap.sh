#!/usr/bin/env bash
set -euo pipefail
# Startup step 1 of 2 (host): run once as root on a new Droplet (or via cloud-init).
#
# Order:
#   1) bootstrap.sh  → Docker, deploy user, dirs, ownership, nginx edge, UFW
#   2) sync-host-secrets (CI) → copies scripts + writes env/<service>.env as deploy
#   3) app deploy (CI) → compose pull/up + health (+ /mail/ edge check)
#
# Prefer copying the full deploy/droplet/ directory so nginx/ + ensure-edge.sh are present.

DEPLOY_USER="${DEPLOY_USER:-deploy}"
DEPLOY_HOME="/home/${DEPLOY_USER}"
ROOT="${DEPLOY_PATH:-/opt/splitsmarter}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HARDEN_SSH="${HARDEN_SSH:-1}"
# Optional: UFW_HTTP_ALLOW_FROM="10.0.0.5 10.116.0.8" for internal-only :80

export DEBIAN_FRONTEND=noninteractive

echo "==> bootstrap as root → DEPLOY_PATH=${ROOT} DEPLOY_USER=${DEPLOY_USER}"

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

mkdir -p "${DEPLOY_HOME}/.ssh"
chmod 700 "${DEPLOY_HOME}/.ssh"
if [[ -n "${DEPLOY_SSH_PUBLIC_KEY:-}" ]]; then
  echo "$DEPLOY_SSH_PUBLIC_KEY" > "${DEPLOY_HOME}/.ssh/authorized_keys"
  chmod 600 "${DEPLOY_HOME}/.ssh/authorized_keys"
fi
chown -R "${DEPLOY_USER}:${DEPLOY_USER}" "${DEPLOY_HOME}/.ssh"

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

# Nginx path edge + UFW (no Caddy). Prefer full droplet/ tree so nginx/ exists.
if [[ -f "${SCRIPT_DIR}/ensure-edge.sh" && -d "${SCRIPT_DIR}/nginx" ]]; then
  echo "==> installing nginx edge (path routes, UFW 80)"
  chmod +x "${SCRIPT_DIR}/ensure-edge.sh" || true
  bash "${SCRIPT_DIR}/ensure-edge.sh"
else
  echo "==> WARN: ensure-edge.sh / nginx/ missing — install edge later:"
  echo "    copy full deploy/droplet/ then: sudo bash ensure-edge.sh"
  ufw allow OpenSSH
  ufw allow 80/tcp
  ufw allow 443/tcp
  ufw --force enable || true
fi

echo ""
echo "Bootstrap complete (startup step 1/2)."
echo "  DEPLOY_PATH=${ROOT}  owner=${DEPLOY_USER}:${DEPLOY_USER}"
echo "  edge: nginx /mail/ → 127.0.0.1:8083 (containers stay localhost-only)"
echo ""
echo "Next (startup step 2/2): run GitHub Action sync-host-secrets"
echo "Then: deploy mail-service. Health: http://127.0.0.1:8083/health and http://127.0.0.1/mail/health"
echo "Prefer Managed Postgres in the same VPC; never expose 5432 or 8083 publicly."
