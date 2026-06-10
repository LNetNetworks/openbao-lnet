#!/usr/bin/env bash
#
# Register and enable the ethsign secrets engine in a running OpenBao container.
#
# Requirements:
#   - The openbao-lnet container is up, initialized and UNSEALED.
#   - BAO_TOKEN is exported (a root token, or one allowed to manage plugins).
#
# Usage:
#   BAO_TOKEN=<root-token> ./scripts/register-plugin.sh
#
set -euo pipefail

SERVICE="${SERVICE:-openbao}"
PLUGIN_NAME="${PLUGIN_NAME:-ethsign}"
MOUNT_PATH="${MOUNT_PATH:-ethereum}"
PLUGIN_BIN="/openbao/plugins/ethsign"

: "${BAO_TOKEN:?Set BAO_TOKEN to a token allowed to manage plugins (e.g. the root token)}"

exec_in() { docker compose exec -T -e "BAO_TOKEN=${BAO_TOKEN}" "$SERVICE" "$@"; }

echo "==> Computing SHA256 of ${PLUGIN_BIN}"
SHA="$(exec_in sha256sum "$PLUGIN_BIN" | awk '{print $1}')"
echo "    sha256=${SHA}"

echo "==> Registering plugin '${PLUGIN_NAME}' in the catalog"
exec_in bao plugin register -sha256="${SHA}" -command="ethsign" secret "${PLUGIN_NAME}"

echo "==> Enabling secrets engine at '${MOUNT_PATH}/'"
if exec_in bao secrets list -format=json | grep -q "\"${MOUNT_PATH}/\""; then
  echo "    already enabled at ${MOUNT_PATH}/ — skipping"
else
  exec_in bao secrets enable -path="${MOUNT_PATH}" "${PLUGIN_NAME}"
fi

echo "==> Done. Engine mounted at ${MOUNT_PATH}/"
