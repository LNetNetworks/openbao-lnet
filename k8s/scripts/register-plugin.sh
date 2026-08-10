#!/usr/bin/env bash
#
# Registra el plugin `ethsign` en el catálogo de OpenBao y monta el secrets
# engine en `ethereum/`. Equivalente en Kubernetes de scripts/register-plugin.sh
# (que usa `docker compose exec`).
#
# IDEMPOTENTE: si el engine ya está montado, no hace nada.
#
# El registro se persiste en el storage de Raft, así que sobrevive a restarts y
# se replica a los 3 nodos. Solo hay que correrlo una vez por cluster... y de
# nuevo cada vez que cambie el BINARIO del plugin (el sha256 registrado tiene
# que coincidir con el del archivo, si no OpenBao se niega a ejecutarlo).
#
# Uso:
#   BAO_TOKEN=<root-token> ./k8s/scripts/register-plugin.sh
#
set -euo pipefail

NAMESPACE="${NAMESPACE:-openbao}"
PLUGIN_NAME="${PLUGIN_NAME:-ethsign}"
MOUNT_PATH="${MOUNT_PATH:-ethereum}"
PLUGIN_BIN="${PLUGIN_BIN:-/openbao/plugins/ethsign}"

: "${BAO_TOKEN:?Exportá BAO_TOKEN con un token que pueda gestionar plugins (p.ej. el root token)}"

# ---------------------------------------------------------------------------
# Todo se ejecuta contra el nodo ACTIVO. Los standby reenvían escrituras, pero
# el registro de plugins es una operación de sistema: mejor ir directo al líder.
# La label openbao-active=true la mantiene service_registration "kubernetes".
# ---------------------------------------------------------------------------
ACTIVE_POD="$(kubectl -n "${NAMESPACE}" get pods \
  -l app.kubernetes.io/name=openbao,openbao-active=true \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"

if [[ -z "${ACTIVE_POD}" ]]; then
  echo "No se encontró el pod activo (label openbao-active=true)."
  echo "¿Está inicializado y desellado el cluster? Probá:"
  echo "  kubectl -n ${NAMESPACE} exec openbao-0 -- bao status"
  exit 1
fi
echo "==> Nodo activo: ${ACTIVE_POD}"

kexec() {
  kubectl -n "${NAMESPACE}" exec -i "${ACTIVE_POD}" \
    -- env BAO_TOKEN="${BAO_TOKEN}" "$@"
}

# ---------------------------------------------------------------------------
# 1. sha256 del binario tal como está DENTRO del pod
# ---------------------------------------------------------------------------
echo "==> Calculando sha256 de ${PLUGIN_BIN}"
SHA="$(kexec sha256sum "${PLUGIN_BIN}" | awk '{print $1}')"
if [[ -z "${SHA}" ]]; then
  echo "No se pudo leer ${PLUGIN_BIN}. ¿La imagen es la correcta (openbao-ethsign)?"
  exit 1
fi
echo "    sha256=${SHA}"

# ---------------------------------------------------------------------------
# 2. Registrar en el catálogo
# ---------------------------------------------------------------------------
echo "==> Registrando el plugin '${PLUGIN_NAME}' en el catálogo"
kexec bao plugin register -sha256="${SHA}" -command="ethsign" secret "${PLUGIN_NAME}"

# ---------------------------------------------------------------------------
# 3. Montar el engine
# ---------------------------------------------------------------------------
echo "==> Habilitando el secrets engine en '${MOUNT_PATH}/'"
if kexec bao secrets list -format=json | grep -q "\"${MOUNT_PATH}/\""; then
  echo "    ya está montado en ${MOUNT_PATH}/ — skip"
  echo "    (si actualizaste el binario del plugin, recargá los backends con:"
  echo "     kubectl -n ${NAMESPACE} exec ${ACTIVE_POD} -- bao plugin reload -plugin ${PLUGIN_NAME})"
else
  kexec bao secrets enable -path="${MOUNT_PATH}" "${PLUGIN_NAME}"
fi

echo "==> Listo. Engine montado en ${MOUNT_PATH}/"
echo "    Probalo con:  ./k8s/scripts/smoke-test.sh"
