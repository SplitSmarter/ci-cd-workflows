#!/usr/bin/env bash
set -euo pipefail
# Run once as root on a new DigitalOcean Droplet (or via cloud-init).
# Installs Docker, creates deploy user, /opt/splitsmarter/{scripts,env}, firewall.

DEPLOY_USER="${DEPLOY_USER:-deploy}"
DEPLOY_HOME="/home/${DEPLOY_USER}"
ROOT="${DEPLOY_PATH:-/opt/splitsmarter}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HARDEN_SSH="${HARDEN_SSH:-1}"

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends ca-certificates curl gnupg ufw

# Docker Engine + Compose plugin
if ! command -v docker >/dev/null 2>&1; then
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
  . /etc/os-release
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${VERSION_CODENAME} stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
fi

systemctl enable --now docker

if ! id "$DEPLOY_USER" >/dev/null 2>&1; then
  useradd -m -s /bin/bash "$DEPLOY_USER"
fi
usermod -aG docker "$DEPLOY_USER"

mkdir -p "${DEPLOY_HOME}/.ssh"
chmod 700 "${DEPLOY_HOME}/.ssh"
if [[ -n "${DEPLOY_SSH_PUBLIC_KEY:-}" ]]; then
  echo "$DEPLOY_SSH_PUBLIC_KEY" > "${DEPLOY_HOME}/.ssh/authorized_keys"
  chmod 600 "${DEPLOY_HOME}/.ssh/authorized_keys"
fi
chown -R "${DEPLOY_USER}:${DEPLOY_USER}" "${DEPLOY_HOME}/.ssh"

mkdir -p "${ROOT}/scripts" "${ROOT}/env"
cp -f "${SCRIPT_DIR}/deploy-service.sh" "${ROOT}/scripts/"
cp -f "${SCRIPT_DIR}/sync-env.sh" "${ROOT}/scripts/"
cp -f "${SCRIPT_DIR}/validate-env.sh" "${ROOT}/scripts/"
cp -f "${SCRIPT_DIR}/check-host.sh" "${ROOT}/scripts/"
cp -f "${SCRIPT_DIR}/docker-compose.yml" "${ROOT}/docker-compose.yml"
chmod 755 "${ROOT}/scripts/"*.sh
chmod 750 "${ROOT}/env"

command -v docker >/dev/null 2>&1 || { echo "ERROR: docker missing after install" >&2; exit 1; }
docker compose version >/dev/null 2>&1 || { echo "ERROR: docker compose plugin missing after install" >&2; exit 1; }
systemctl is-active --quiet docker || { echo "ERROR: docker service is not active" >&2; exit 1; }

chown -R "${DEPLOY_USER}:${DEPLOY_USER}" "$ROOT"

echo "==> verifying as ${DEPLOY_USER}"
sudo -u "$DEPLOY_USER" docker info >/dev/null \
  || { echo "ERROR: ${DEPLOY_USER} cannot run docker info (group membership / daemon)" >&2; exit 1; }
sudo -u "$DEPLOY_USER" docker compose version >/dev/null \
  || { echo "ERROR: ${DEPLOY_USER} cannot run docker compose" >&2; exit 1; }
sudo -u "$DEPLOY_USER" test -w "$ROOT" -a -w "${ROOT}/env" \
  || { echo "ERROR: ${DEPLOY_USER} cannot write ${ROOT} or ${ROOT}/env" >&2; exit 1; }

if [[ "$HARDEN_SSH" == "1" ]]; then
  echo "==> SSH hardening (PasswordAuthentication no)"
  mkdir -p /etc/ssh/sshd_config.d
  cat > /etc/ssh/sshd_config.d/50-splitsmarter-deploy.conf <<'EOF'
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
EOF
  if systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null; then
    echo "ok sshd reloaded"
  else
    echo "WARN: could not reload sshd; apply PasswordAuthentication no manually"
  fi
fi

ufw allow OpenSSH
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable || true

echo "Bootstrap complete."
echo "Layout: ${ROOT}/scripts ${ROOT}/env ${ROOT}/docker-compose.yml"
echo "Next: set GitHub Variables DEVELOPMENT_INSTANCE_1 + DEVELOPMENT_APPSECRET_MAILSERVICE,"
echo "then run sync-host-secrets (writes env/mail-service.env), then deploy mail-service."
echo "Prefer Managed Postgres in the same VPC; never expose 5432 publicly."
