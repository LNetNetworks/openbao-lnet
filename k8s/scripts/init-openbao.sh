#!/usr/bin/env bash
#
# Inicializa el cluster de OpenBao en Kubernetes y guarda el material sensible
# en GCP Secret Manager.
#
# ██ SE CORRE UNA SOLA VEZ EN LA VIDA DEL CLUSTER ██
#
# `bao operator init` genera la root key. Correrlo dos veces sobre un cluster ya
# inicializado devuelve error (bien), pero correrlo sobre un cluster VACÍO
# después de haber borrado los PVCs genera una root key NUEVA y todas las llaves
# privadas anteriores quedan irrecuperables. Ver k8s/docs/unseal-keys.md.
#
# Como el seal es `gcpckms`, lo que imprime NO son unseal keys Shamir sino
# RECOVERY KEYS: no desellan nada (de eso se encarga KMS), sirven para
# `operator generate-root` y `operator rekey-recovery-key`.
#
# Uso:
#   ./k8s/scripts/init-openbao.sh
#
set -euo pipefail

NAMESPACE="${NAMESPACE:-openbao}"
POD="${POD:-openbao-0}"
RECOVERY_SHARES="${RECOVERY_SHARES:-5}"
RECOVERY_THRESHOLD="${RECOVERY_THRESHOLD:-3}"
PROJECT_ID="${PROJECT_ID:-l-net-469615}"
GSM_SECRET="${GSM_SECRET:-openbao-prod-recovery}"
EXPECTED_REPLICAS="${EXPECTED_REPLICAS:-3}"

kexec() { kubectl -n "${NAMESPACE}" exec -i "${POD}" -- "$@"; }

red()  { printf '\033[0;31m%s\033[0m\n' "$*"; }
bold() { printf '\033[1m%s\033[0m\n' "$*"; }

# ---------------------------------------------------------------------------
# 1. Verificaciones previas
# ---------------------------------------------------------------------------
echo "==> Contexto de kubectl: $(kubectl config current-context)"
echo "==> Pods en ${NAMESPACE}:"
kubectl -n "${NAMESPACE}" get pods -l app.kubernetes.io/name=openbao

RUNNING="$(kubectl -n "${NAMESPACE}" get pods -l app.kubernetes.io/name=openbao \
  --field-selector=status.phase=Running -o name | wc -l | tr -d ' ')"
if [[ "${RUNNING}" -lt "${EXPECTED_REPLICAS}" ]]; then
  red "Solo ${RUNNING}/${EXPECTED_REPLICAS} pods en Running."
  echo "Los pods deben estar Running (aunque 0/1 Ready — es normal antes del init)."
  echo "Si alguno está Pending, revisá que el node pool tenga 3 nodos (podAntiAffinity)."
  exit 1
fi

# `bao status` sale 2 si está sellado/no inicializado, 0 si está desellado.
INIT_STATUS="$(kexec bao status -format=json 2>/dev/null || true)"
if echo "${INIT_STATUS}" | grep -q '"initialized": *true'; then
  red "El cluster YA está inicializado. No se hace nada."
  echo "Si necesitás un root token nuevo, usá:  bao operator generate-root"
  exit 0
fi

# ---------------------------------------------------------------------------
# 2. Init
# ---------------------------------------------------------------------------
bold "==> bao operator init  (recovery-shares=${RECOVERY_SHARES}, threshold=${RECOVERY_THRESHOLD})"
echo "    El seal es gcpckms → salen RECOVERY keys, no unseal keys."

INIT_JSON="$(kexec bao operator init \
  -recovery-shares="${RECOVERY_SHARES}" \
  -recovery-threshold="${RECOVERY_THRESHOLD}" \
  -format=json)"

if [[ -z "${INIT_JSON}" ]]; then
  red "init no devolvió nada. Abortando SIN guardar."
  exit 1
fi

# ---------------------------------------------------------------------------
# 3. Guardar en Secret Manager ANTES de imprimir nada
#
# Se pasa por stdin (`--data-file=-`): el material nunca toca el disco local.
# NUNCA guardar esto en un archivo del repo, y NUNCA llamarlo `.env`
# (docker compose lo autocarga y revienta con las líneas que llevan espacios —
# ver el gotcha del CLAUDE.md).
# ---------------------------------------------------------------------------
bold "==> Guardando en GCP Secret Manager: ${GSM_SECRET}"
if gcloud secrets describe "${GSM_SECRET}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
  printf '%s' "${INIT_JSON}" | gcloud secrets versions add "${GSM_SECRET}" \
    --data-file=- --project="${PROJECT_ID}"
else
  printf '%s' "${INIT_JSON}" | gcloud secrets create "${GSM_SECRET}" \
    --data-file=- --replication-policy=automatic --project="${PROJECT_ID}"
fi
echo "    OK — guardado."

# ---------------------------------------------------------------------------
# 4. Esperar el auto-unseal del resto de los nodos
# ---------------------------------------------------------------------------
bold "==> Esperando a que los 3 nodos queden Ready (auto-unseal + retry_join)"
echo "    Ningún 'bao operator unseal' manual: de eso se encarga Cloud KMS."
kubectl -n "${NAMESPACE}" wait --for=condition=Ready pod \
  -l app.kubernetes.io/name=openbao --timeout=300s || {
    red "Timeout. Revisá los logs:  kubectl -n ${NAMESPACE} logs ${POD}"
    red "Causas típicas (todas en k8s/gcp/setup-gcp.sh):"
    red "  - 'error checking key existence: PermissionDenied' → al GSA le falta"
    red "    roles/cloudkms.viewer sobre la key. cryptoKeyEncrypterDecrypter NO"
    red "    incluye cloudkms.cryptoKeys.get; hacen falta LOS DOS roles."
    red "  - El GSA no tiene cryptoKeyEncrypterDecrypter."
    red "  - La annotation de Workload Identity no coincide con el GSA."
    exit 1
  }

echo "==> Peers de Raft:"
kexec bao operator raft list-peers 2>/dev/null || \
  echo "    (necesita token — se ve después del login, no es un error acá)"

# ---------------------------------------------------------------------------
# 5. Mostrar el material UNA vez
# ---------------------------------------------------------------------------
cat <<'EOF'

==============================================================================
  ██  ESTO SE MUESTRA UNA SOLA VEZ  ██
==============================================================================
Copialo YA a un gestor de contraseñas y repartí los shares entre custodios
distintos (ver k8s/docs/unseal-keys.md — sección "Custodia").

Ya quedó una copia en GCP Secret Manager, pero esa copia es un
single-point-of-failure: si perdés el acceso al proyecto GCP también perdés
las recovery keys. La custodia repartida es la que importa.
==============================================================================
EOF

printf '%s\n' "${INIT_JSON}"

cat <<EOF

==============================================================================
Siguientes pasos (k8s/docs/deployment.md):

  export BAO_TOKEN=\$(echo '<json de arriba>' | jq -r .root_token)

  ./k8s/scripts/register-plugin.sh     # registra ethsign + monta ethereum/
  ./k8s/scripts/bootstrap-auth.sh      # audit, k8s auth, políticas, autopilot
  ./k8s/scripts/smoke-test.sh          # end-to-end

Y al final: REVOCAR el root token (bootstrap-auth.sh lo ofrece).
Para recuperarlo: bao operator generate-root, con ${RECOVERY_THRESHOLD} de las
${RECOVERY_SHARES} recovery keys.
==============================================================================
EOF
