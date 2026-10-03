#!/usr/bin/env bash
# Prepare SSH from a parsed INSTANCE KEY=VALUE file and run a remote command.
# Usage: ssh_from_instance.sh /path/to/instance.env 'remote command'
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=prepare_ssh.sh
source "${SCRIPT_DIR}/prepare_ssh.sh"

INSTANCE_FILE="${1:?instance env file required}"
shift
REMOTE_CMD="${*:?remote command required}"

prepare_ssh "$INSTANCE_FILE"
prepare_ssh_verify_connectivity

# shellcheck disable=SC2029
ssh "${SSH_OPTS[@]}" "${SSH_USER}@${SSH_HOST}" "export DEPLOY_PATH='${DEPLOY_PATH}'; ${REMOTE_CMD}"
