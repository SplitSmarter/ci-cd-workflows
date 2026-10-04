#!/usr/bin/env bash
set -euo pipefail
# Run as root (from bootstrap, or manually after adding a new location).
# Installs/refreshes Nginx path routing + UFW rules for the edge (port 80).
# Does NOT expose container ports (8083, etc.).
#
# Optional:
#   UFW_HTTP_ALLOW_FROM="10.0.0.5 10.116.0.8"  # only these sources to :80
#   (empty = allow 80/tcp from Anywhere — tighten for internal-only later)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NGINX_SRC="${SCRIPT_DIR}/nginx"
UFW_HTTP_ALLOW_FROM="${UFW_HTTP_ALLOW_FROM:-}"

fail() { echo "ERROR: $*" >&2; exit 1; }
step() { echo "==> $*"; }

[[ "$(id -u)" -eq 0 ]] || fail "ensure-edge.sh must run as root"

step "install nginx"
export DEBIAN_FRONTEND=noninteractive
apt-get install -y --no-install-recommends nginx

step "install nginx site + location snippets"
mkdir -p /etc/nginx/splitsmarter.d
if [[ -f "${NGINX_SRC}/splitsmarter.conf" ]]; then
  cp -f "${NGINX_SRC}/splitsmarter.conf" /etc/nginx/sites-available/splitsmarter
else
  fail "missing ${NGINX_SRC}/splitsmarter.conf (copy full deploy/droplet/ folder when bootstrapping edge)"
fi
if [[ -d "${NGINX_SRC}/locations" ]]; then
  cp -f "${NGINX_SRC}/locations/"*.conf /etc/nginx/splitsmarter.d/ 2>/dev/null || true
fi

ln -sf /etc/nginx/sites-available/splitsmarter /etc/nginx/sites-enabled/splitsmarter
rm -f /etc/nginx/sites-enabled/default

step "nginx -t && reload"
nginx -t || fail "nginx config test failed"
systemctl enable nginx
systemctl reload nginx || systemctl restart nginx

step "UFW: OpenSSH + HTTP 80 (not 8083)"
ufw allow OpenSSH
# Remove wide-open 80 if we will replace with allowlist
if [[ -n "${UFW_HTTP_ALLOW_FROM}" ]]; then
  ufw delete allow 80/tcp 2>/dev/null || true
  ufw delete allow 443/tcp 2>/dev/null || true
  for src in ${UFW_HTTP_ALLOW_FROM}; do
    step "UFW allow 80/tcp from ${src}"
    ufw allow from "${src}" to any port 80 proto tcp
  done
else
  ufw allow 80/tcp
  ufw allow 443/tcp
fi
# Container ports must stay local-only
ufw delete allow 8083/tcp 2>/dev/null || true
ufw --force enable || true

step "edge status"
systemctl is-active --quiet nginx || fail "nginx is not active"
ufw status | sed -n '1,40p' || true

echo "ok ensure-edge: nginx path routes ready (e.g. http://<host>/mail/ → 127.0.0.1:8083)"
echo "   Add more services: drop a file in ${NGINX_SRC}/locations/ and re-run ensure-edge.sh as root."
