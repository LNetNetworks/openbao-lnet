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
# RECOVERY KEYS: no desellan nada (de eso se encarga KMS). Son el quórum de
# entrada de `sys/rotate/root/*` y `sys/rotate/recovery/*`, que desde OpenBao
# 2.6.0 son endpoints AUTENTICADOS: los shares NO alcanzan solos para acuñar un
# root token. Ver k8s/docs/admin-access-recovery.md.
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

# Antes del init solo puede existir UN pod: el StatefulSet usa
# podManagementPolicy OrderedReady, así que openbao-1 no se crea hasta que
# openbao-0 esté Ready, y eso no pasa hasta que este script lo inicialice.
# Exigir 3 pods acá sería una precondición imposible de cumplir. Los otros dos
# se verifican DESPUÉS del init, en el paso 4.
POD_PHASE="$(kubectl -n "${NAMESPACE}" get pod "${POD}" \
  -o jsonpath='{.status.phase}' 2>/dev/null || true)"
if [[ "${POD_PHASE}" != "Running" ]]; then
  red "${POD} está en '${POD_PHASE:-inexistente}', se necesita Running."
  echo "0/1 Ready es normal antes del init; Running es lo que hace falta."
  echo "  - Pending      → el podAntiAffinity pide un nodo por pod; revisá que"
  echo "                   el node pool haya escalado (kubectl get nodes)."
  echo "  - Terminating  → esperá a que se recree y volvé a correr esto."
  echo "  - CrashLoop    → kubectl -n ${NAMESPACE} logs ${POD} --previous"
  exit 1
fi

# `bao status` sale 2 si está sellado/no inicializado, 0 si está desellado.
INIT_STATUS="$(kexec bao status -format=json 2>/dev/null || true)"
if echo "${INIT_STATUS}" | grep -q '"initialized": *true'; then
  red "El cluster YA está inicializado. No se hace nada."
  echo "Para un token administrativo NO uses generate-root (autenticado desde"
  echo "2.6.0). Emitilo por el rol de auth de K8s 'openbao-operator':"
  echo "  JWT=\$(kubectl -n ${NAMESPACE} create token openbao-operator --duration=1800s)"
  echo "  bao write -field=token auth/kubernetes/login role=openbao-operator jwt=\$JWT"
  echo "Detalle: k8s/docs/admin-access-recovery.md"
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
bold "==> Esperando a que los ${EXPECTED_REPLICAS} nodos queden Ready (auto-unseal + retry_join)"
echo "    Ningún 'bao operator unseal' manual: de eso se encarga Cloud KMS."
echo "    Con OrderedReady los pods nacen de a uno: openbao-0 Ready → se crea"
echo "    openbao-1 → retry_join + auto-unseal → Ready → se crea openbao-2."

# OJO: `kubectl wait -l app...` NO sirve acá. Solo espera a los pods que existen
# en el momento de invocarlo, y en este punto existe únicamente openbao-0 — daría
# éxito con 1/3 nodos arriba. Hay que esperar sobre readyReplicas del StatefulSet.
WAIT_TIMEOUT="${WAIT_TIMEOUT:-420}"
DEADLINE=$((SECONDS + WAIT_TIMEOUT))
READY=0
while (( SECONDS < DEADLINE )); do
  READY="$(kubectl -n "${NAMESPACE}" get sts openbao \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)"
  READY="${READY:-0}"
  printf '\r    Ready: %s/%s  (%ss)' "${READY}" "${EXPECTED_REPLICAS}" "${SECONDS}"
  [[ "${READY}" -ge "${EXPECTED_REPLICAS}" ]] && break
  sleep 5
done
echo
if [[ "${READY}" -lt "${EXPECTED_REPLICAS}" ]]; then
  red "Timeout: ${READY}/${EXPECTED_REPLICAS} nodos Ready tras ${WAIT_TIMEOUT}s."
  red "El init YA se hizo y el material está guardado — NO vuelvas a correr"
  red "este script. Esto es un problema de arranque de los nodos restantes."
  red "Revisá los logs:  kubectl -n ${NAMESPACE} logs ${POD}"
  red "Causas típicas (todas en k8s/gcp/setup-gcp.sh):"
  red "  - 'error checking key existence: PermissionDenied' → al GSA le falta"
  red "    roles/cloudkms.viewer sobre la key. cryptoKeyEncrypterDecrypter NO"
  red "    incluye cloudkms.cryptoKeys.get; hacen falta LOS DOS roles."
  red "  - El GSA no tiene cryptoKeyEncrypterDecrypter."
  red "  - La annotation de Workload Identity no coincide con el GSA."
  red "  - Un cambio de plantilla del STS pendiente: el rollout se atasca si un"
  red "    pod no llega a Ready. kubectl -n ${NAMESPACE} delete pod ${POD}"
  exit 1
fi

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

Y al final: REVOCAR el root token (bootstrap-auth.sh lo ofrece, y antes prueba
el camino de vuelta).
Para administrar sin root token: el rol de auth de K8s 'openbao-operator'.
Las ${RECOVERY_SHARES} recovery keys NO acuñan un root token por sí solas en
OpenBao >=2.6.0 — ver k8s/docs/admin-access-recovery.md.
==============================================================================
EOF
