#!/usr/bin/env bash
set -euo pipefail
# Run once as root on a new DigitalOcean Droplet (or via cloud-init).

DEPLOY_USER="${DEPLOY_USER:-deploy}"
DEPLOY_HOME="/home/${DEPLOY_USER}"
ROOT="${DEPLOY_PATH:-/opt/splitsmarter}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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

mkdir -p "${ROOT}/scripts"
cp -f "${SCRIPT_DIR}/deploy-service.sh" "${ROOT}/scripts/"
cp -f "${SCRIPT_DIR}/sync-env.sh" "${ROOT}/scripts/"
cp -f "${SCRIPT_DIR}/validate-env.sh" "${ROOT}/scripts/"
cp -f "${SCRIPT_DIR}/check-host.sh" "${ROOT}/scripts/"
cp -f "${SCRIPT_DIR}/docker-compose.yml" "${ROOT}/docker-compose.yml"
chmod 755 "${ROOT}/scripts/"*.sh

# Fail fast if docker is still unavailable after install
command -v docker >/dev/null 2>&1 || { echo "ERROR: docker missing after install" >&2; exit 1; }
docker compose version >/dev/null 2>&1 || { echo "ERROR: docker compose plugin missing after install" >&2; exit 1; }
systemctl is-active --quiet docker || { echo "ERROR: docker service is not active" >&2; exit 1; }

if [[ ! -f "${ROOT}/.env" ]]; then
  umask 077
  touch "${ROOT}/.env"
  chmod 600 "${ROOT}/.env"
fi

chown -R "${DEPLOY_USER}:${DEPLOY_USER}" "$ROOT"

ufw allow OpenSSH
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable || true

echo "Bootstrap complete."
echo "Next: set GitHub Variables DEVELOPMENT_INSTANCE_1 + DEVELOPMENT_APPSECRET_MAILSERVICE,"
echo "then run sync-host-secrets, then deploy mail-service."
