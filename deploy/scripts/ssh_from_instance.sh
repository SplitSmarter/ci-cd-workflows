#!/usr/bin/env bash
# Prepare SSH from a parsed INSTANCE KEY=VALUE file and run a remote command.
# Usage: ssh_from_instance.sh /path/to/instance.env 'remote command'
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=parse_kv.sh
source "${SCRIPT_DIR}/parse_kv.sh"

INSTANCE_FILE="${1:?instance env file required}"
shift
REMOTE_CMD="${*:?remote command required}"

parse_kv_file "$INSTANCE_FILE"

: "${SSH_HOST:?SSH_HOST missing in instance payload}"
: "${SSH_USER:=deploy}"
: "${SSH_PORT:=22}"
: "${DEPLOY_PATH:=/opt/splitsmarter}"
: "${SSH_KEY:?SSH_KEY missing in instance payload}"

KEY_FILE="$(mktemp)"
printf '%s\n' "$SSH_KEY" > "$KEY_FILE"
chmod 600 "$KEY_FILE"

SSH_OPTS=(-i "$KEY_FILE" -o Port="$SSH_PORT" -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/tmp/known_hosts_deploy)

cleanup() { rm -f "$KEY_FILE"; }
trap cleanup EXIT

# shellcheck disable=SC2029
ssh "${SSH_OPTS[@]}" "${SSH_USER}@${SSH_HOST}" "export DEPLOY_PATH='${DEPLOY_PATH}'; ${REMOTE_CMD}"
