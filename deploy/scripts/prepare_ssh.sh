#!/usr/bin/env bash
# Sourceable helper: parse instance payload and prepare SSH_OPTS + KEY_FILE.
# Usage:
#   source deploy/scripts/prepare_ssh.sh
#   prepare_ssh /path/to/instance.env
#   # sets SSH_HOST SSH_USER SSH_PORT SSH_KEY KEY_FILE SSH_OPTS[]; trap cleans KEY_FILE
#
# Optional: prepare_ssh_verify_connectivity  # quick ssh true

# shellcheck disable=SC2034
prepare_ssh() {
  local file="${1:?instance env file required}"
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # shellcheck source=parse_kv.sh
  source "${script_dir}/parse_kv.sh"
  parse_kv_file "$file"

  : "${SSH_HOST:?SSH_HOST missing in instance payload}"
  : "${SSH_USER:=deploy}"
  : "${SSH_PORT:=22}"
  : "${DEPLOY_PATH:=/opt/splitsmarter}"
  : "${SSH_KEY:?SSH_KEY missing in instance payload}"

  if [[ "$SSH_KEY" != -----BEGIN* ]]; then
    echo "ERROR: SSH_KEY does not look like a PEM private key (missing -----BEGIN)." >&2
    exit 1
  fi
  if [[ "$SSH_KEY" != *-----END* ]]; then
    echo "ERROR: SSH_KEY looks truncated (missing -----END)." >&2
    exit 1
  fi

  KEY_FILE="$(mktemp)"
  printf '%s\n' "$SSH_KEY" > "$KEY_FILE"
  chmod 600 "$KEY_FILE"
  SSH_OPTS=(-i "$KEY_FILE" -o Port="$SSH_PORT" -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/tmp/known_hosts_deploy)

  # shellcheck disable=SC2329
  _prepare_ssh_cleanup() { rm -f "${KEY_FILE:-}"; }
  trap _prepare_ssh_cleanup EXIT

  echo "==> SSH ready user=${SSH_USER} host=${SSH_HOST} port=${SSH_PORT} deploy_path=${DEPLOY_PATH}"
}

prepare_ssh_verify_connectivity() {
  : "${SSH_HOST:?}"
  : "${SSH_USER:?}"
  : "${KEY_FILE:?}"
  echo "==> verifying SSH connectivity to ${SSH_USER}@${SSH_HOST}"
  if ! ssh "${SSH_OPTS[@]}" "${SSH_USER}@${SSH_HOST}" "true"; then
    echo "ERROR: SSH connection failed to ${SSH_USER}@${SSH_HOST}:${SSH_PORT}." >&2
    echo "Check SSH_HOST, SSH_USER, SSH_PORT, and that SSH_KEY matches authorized_keys on the host." >&2
    exit 1
  fi
  echo "ok ssh connectivity"
}

remote_mkdir_deploy() {
  local path="${1:-${DEPLOY_PATH}}"
  echo "==> ensuring remote directory ${path}/scripts"
  if ! ssh "${SSH_OPTS[@]}" "${SSH_USER}@${SSH_HOST}" "mkdir -p '${path}/scripts'"; then
    echo "ERROR: cannot create ${path}/scripts as ${SSH_USER}." >&2
    echo "On the host as root: mkdir -p ${path} && chown -R ${SSH_USER}:${SSH_USER} ${path}" >&2
    echo "Or run deploy/droplet/bootstrap.sh as root." >&2
    exit 1
  fi
}

remote_check_host() {
  local path="${1:-${DEPLOY_PATH}}"
  shift || true
  local flags=("$@")
  echo "==> remote host checks (${path}) ${flags[*]}"
  if ! ssh "${SSH_OPTS[@]}" "${SSH_USER}@${SSH_HOST}" \
    "export DEPLOY_PATH='${path}'; \
     if [[ ! -x '${path}/scripts/check-host.sh' ]]; then \
       echo 'ERROR: ${path}/scripts/check-host.sh missing. Re-run sync-host-secrets or copy check-host.sh.' >&2; \
       exit 1; \
     fi; \
     '${path}/scripts/check-host.sh' ${flags[*]}"; then
    echo "ERROR: remote host checks failed for ${SSH_USER}@${SSH_HOST}." >&2
    exit 1
  fi
}
