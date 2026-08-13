#!/usr/bin/env bash
#
# Smoke test end-to-end del endpoint sign-digest (una vez implementado):
# crea/usa una cuenta, firma un digest crudo de 32 bytes y verifica que
# ecrecover(digest, firma) devuelva la misma address.
#
# Uso:
#   BAO_TOKEN=<token> ./plan-digest/scripts/verify-sign-digest.sh
#   BAO_TOKEN=<token> ADDRESS=0x67c64... ./plan-digest/scripts/verify-sign-digest.sh
#   BAO_TOKEN=<token> BAO_ADDR=https://vault.l-net.io ./plan-digest/scripts/verify-sign-digest.sh
#
# Variables:
#   BAO_ADDR   default http://127.0.0.1:8200 (el POC local)
#   MOUNT_PATH default ethereum
#   ADDRESS    si se omite, crea una cuenta nueva
#   DIGEST     0x + 64 hex. Si se omite, usa un digest fijo de prueba.
#
# La verificación de ecrecover necesita node con `ethers` v6 instalado
# (`npm i ethers`, o exportar NODE_PATH). Si no está, el script imprime la
# firma y avisa que no pudo verificar — no falla silenciosamente.
set -euo pipefail

BAO_ADDR="${BAO_ADDR:-http://127.0.0.1:8200}"
MOUNT_PATH="${MOUNT_PATH:-ethereum}"
DIGEST="${DIGEST:-0x1111111111111111111111111111111111111111111111111111111111111111}"
: "${BAO_TOKEN:?Exportá BAO_TOKEN}"

hdr=(-H "X-Vault-Token: ${BAO_TOKEN}" -H "Content-Type: application/json")

jqget() { # jqget <json> <ruta jq> — usa jq si está, si no cae a sed
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$1" | jq -r "$2"
  else
    printf '%s' "$1" | sed -n "s/.*\"${2##*.}\":\"\([^\"]*\)\".*/\1/p"
  fi
}

ADDRESS="${ADDRESS:-}"
if [[ -z "${ADDRESS}" ]]; then
  echo "==> Creando una cuenta nueva"
  ACCOUNT_JSON="$(curl -sS "${hdr[@]}" -d '{}' "${BAO_ADDR}/v1/${MOUNT_PATH}/accounts")"
  ADDRESS="$(jqget "${ACCOUNT_JSON}" '.data.address')"
  [[ -n "${ADDRESS}" ]] || { echo "No se pudo crear la cuenta: ${ACCOUNT_JSON}"; exit 1; }
fi
echo "    address=${ADDRESS}"

echo "==> Firmando el digest crudo ${DIGEST}"
SIGN_JSON="$(curl -sS "${hdr[@]}" \
  -d "{\"hash\":\"${DIGEST}\"}" \
  "${BAO_ADDR}/v1/${MOUNT_PATH}/accounts/${ADDRESS}/sign-digest")"
echo "${SIGN_JSON}"

SIG="$(jqget "${SIGN_JSON}" '.data.signature')"
if [[ -z "${SIG}" || "${SIG}" == "null" ]]; then
  echo
  echo "FALLO: no vino 'signature'. Si el error es 'unsupported path', el binario"
  echo "del plugin no tiene el endpoint (ver plan-digest/README.md, paso 5:"
  echo "re-registrar el sha256 nuevo y 'bao plugin reload')."
  exit 1
fi

echo
echo "==> Verificando ecrecover"
if node -e 'require("ethers")' >/dev/null 2>&1; then
  node -e '
    const { recoverAddress } = require("ethers");
    const [hash, sig, expected] = process.argv.slice(1);
    const got = recoverAddress(hash, sig);
    const ok = got.toLowerCase() === expected.toLowerCase();
    console.log("    recovered=" + got);
    console.log("    expected =" + expected);
    console.log(ok ? "    OK: ecrecover(hash, sig) == address" : "    FALLO: no coincide");
    process.exit(ok ? 0 : 1);
  ' "${DIGEST}" "${SIG}" "${ADDRESS}"
else
  echo "    (omitido: no encontré node con 'ethers' v6 instalado)"
  echo "    Verificalo a mano con:"
  echo "      node -e 'console.log(require(\"ethers\").recoverAddress(\"${DIGEST}\",\"${SIG}\"))'"
  echo "      cast --version >/dev/null && echo 'o con el test Go del fork: go test ./...'"
fi
