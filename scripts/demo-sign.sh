#!/usr/bin/env bash
#
# End-to-end demo: create an Ethereum account and sign a transaction
# against the ethsign engine over the OpenBao HTTP API.
#
# Usage:
#   BAO_TOKEN=<token> ./scripts/demo-sign.sh
#
set -euo pipefail

BAO_ADDR="${BAO_ADDR:-http://127.0.0.1:8200}"
MOUNT_PATH="${MOUNT_PATH:-ethereum}"
: "${BAO_TOKEN:?Set BAO_TOKEN}"

hdr=(-H "X-Vault-Token: ${BAO_TOKEN}" -H "Content-Type: application/json")

echo "==> Creating a new account"
ACCOUNT_JSON="$(curl -s "${hdr[@]}" -d '{}' "${BAO_ADDR}/v1/${MOUNT_PATH}/accounts")"
echo "${ACCOUNT_JSON}"
ADDRESS="$(echo "${ACCOUNT_JSON}" | sed -n 's/.*"address":"\([^"]*\)".*/\1/p')"
echo "    address=${ADDRESS}"

echo "==> Signing a sample transaction (chainId override supported via 'chainId')"
curl -s "${hdr[@]}" \
  -d '{
        "to": "0x9aef1bf4d1c5a261a5c5dd9c826b53e6e7c7f9d8",
        "data": "0x",
        "value": "0",
        "nonce": "0x0",
        "gas": 21000,
        "gasPrice": 0,
        "chainId": "648529"
      }' \
  "${BAO_ADDR}/v1/${MOUNT_PATH}/accounts/${ADDRESS}/sign"
echo
echo "==> The 'signed_transaction' field above is RLP-encoded and ready to broadcast."
