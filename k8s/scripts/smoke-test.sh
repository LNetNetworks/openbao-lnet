#!/usr/bin/env bash
#
# Verificación end-to-end del despliegue en Kubernetes.
#
# Prueba, en orden:
#   1. Salud del cluster de Raft (3 peers, 1 líder, desellado)
#   2. Auto-unseal real: mata el líder y comprueba que vuelve solo
#   3. El Ingress de Kong: HTTPS, redirect 301, y a qué backend pega
#   4. Que el ip-restriction esté viendo la IP correcta (el riesgo Cloudflare)
#   5. Firma end-to-end contra https://vault.l-net.io
#
# El paso 2 provoca un failover REAL. Se puede saltar con SKIP_FAILOVER=1.
#
# BAO_TOKEN es OPCIONAL. Lo normal en este despliegue es NO tener uno: el root
# token se revoca al terminar el bootstrap, y conseguir otro es una operación
# deliberada (rol de auth 'openbao-operator' — ver k8s/docs/admin-access-recovery.md).
# Sin token se corre todo lo que no necesita credenciales (quórum, failover,
# edge) y los dos chequeos que sí las necesitan se reportan como SALTADOS, no
# como fallos.
#
# Uso:
#   ./k8s/scripts/smoke-test.sh                      # sin token: salud del cluster
#   BAO_TOKEN=<token> ./k8s/scripts/smoke-test.sh    # completo, con firma real
#   SKIP_FAILOVER=1 ./k8s/scripts/smoke-test.sh      # sin tocar el liderazgo
#
set -euo pipefail

NAMESPACE="${NAMESPACE:-openbao}"
HOST="${HOST:-vault.l-net.io}"
BAO_ADDR="${BAO_ADDR:-https://${HOST}}"
MOUNT_PATH="${MOUNT_PATH:-ethereum}"
CHAIN_ID="${CHAIN_ID:-648529}"
SKIP_FAILOVER="${SKIP_FAILOVER:-}"
BAO_TOKEN="${BAO_TOKEN:-}"

pass() { printf '  \033[0;32m✓\033[0m %s\n' "$*"; }
fail() { printf '  \033[0;31m✗\033[0m %s\n' "$*"; FAILURES=$((FAILURES+1)); }
warn() { printf '  \033[0;33m!\033[0m %s\n' "$*"; }
skip() { printf '  \033[0;36m⊘\033[0m %s\n' "$*"; SKIPPED=$((SKIPPED+1)); }
FAILURES=0
SKIPPED=0

# Estado del token: ausente | invalido | ok. Se resuelve en el paso 1, en cuanto
# se conoce el pod activo. Validarlo ANTES de usarlo es lo que evita el fallo más
# confuso de este script: un token revocado hace que `raft list-peers` devuelva
# 403, la salida quede vacía, y el conteo de peers dé 0 — que se lee como pérdida
# de quórum cuando el cluster está perfecto.
TOKEN_STATE=ausente

operator_token_hint() {
  cat <<EOF
      Para un token administrativo, emitilo por el rol de auth de Kubernetes
      'openbao-operator' (NO por generate-root: desde OpenBao 2.6.0 ese endpoint
      es autenticado y las recovery keys no alcanzan solas):

          JWT=\$(kubectl -n ${NAMESPACE} create token openbao-operator --duration=1800s)
          export BAO_TOKEN=\$(curl -s \\
            -d "{\\"role\\":\\"openbao-operator\\",\\"jwt\\":\\"\$JWT\\"}" \\
            ${BAO_ADDR}/v1/auth/kubernetes/login | jq -r .auth.client_token)

      Revocalo al terminar:  bao token revoke -self
      Detalle: k8s/docs/admin-access-recovery.md
EOF
}

active_pod() {
  kubectl -n "${NAMESPACE}" get pods \
    -l app.kubernetes.io/name=openbao,openbao-active=true \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null
}

# ===========================================================================
echo
echo "[1/5] Salud del cluster de Raft"
# ===========================================================================
READY="$(kubectl -n "${NAMESPACE}" get pods -l app.kubernetes.io/name=openbao \
  -o jsonpath='{range .items[*]}{.status.containerStatuses[0].ready}{"\n"}{end}' | grep -c true || true)"
[[ "${READY}" -eq 3 ]] && pass "3/3 pods Ready" || fail "solo ${READY}/3 pods Ready"

ACTIVE="$(active_pod)"
[[ -n "${ACTIVE}" ]] && pass "líder: ${ACTIVE}" || fail "no hay pod con openbao-active=true"

# --- Estado del token, antes de usarlo para nada -------------------------------
if [[ -z "${BAO_TOKEN}" ]]; then
  TOKEN_STATE=ausente
elif [[ -n "${ACTIVE}" ]] && kubectl -n "${NAMESPACE}" exec -i "${ACTIVE}" \
       -- env BAO_TOKEN="${BAO_TOKEN}" bao token lookup >/dev/null 2>&1; then
  TOKEN_STATE=ok
  pass "BAO_TOKEN válido"
else
  TOKEN_STATE=invalido
  warn "BAO_TOKEN definido pero NO válido (revocado o expirado) — los chequeos que"
  warn "necesitan credenciales se saltean; el resto corre igual"
  operator_token_hint "${ACTIVE}"
fi

# --- Quórum: sin token, mirando cada réplica ----------------------------------
# `raft list-peers` necesita credenciales, pero la salud del quórum no: si los
# tres nodos están desellados y comparten el mismo Raft Applied Index, están
# replicando. Este chequeo corre SIEMPRE.
QUORUM_OK=1
INDEXES=""
for POD in $(kubectl -n "${NAMESPACE}" get pods -l app.kubernetes.io/name=openbao \
               -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'); do
  ST="$(kubectl -n "${NAMESPACE}" exec -i "${POD}" -- bao status 2>/dev/null || true)"
  MODE="$(echo "${ST}" | awk '/^HA Mode/{print $NF}')"
  IDX="$(echo "${ST}" | awk '/^Raft Applied Index/{print $NF}')"
  printf '      %-12s %-8s applied=%s\n' "${POD}" "${MODE:-?}" "${IDX:-?}"
  [[ -z "${MODE}" || -z "${IDX}" ]] && QUORUM_OK=0
  INDEXES="${INDEXES} ${IDX}"
done
UNIQ_IDX="$(echo "${INDEXES}" | tr ' ' '\n' | grep -v '^$' | sort -u | wc -l | tr -d ' ')"
if [[ "${QUORUM_OK}" -eq 1 && "${UNIQ_IDX}" -eq 1 ]]; then
  pass "los 3 nodos replicando en el mismo índice de Raft"
elif [[ "${QUORUM_OK}" -eq 1 ]]; then
  # Un índice distinto puede ser un follower atrasado unos ms: es warn, no fallo.
  warn "índices de Raft distintos (${INDEXES# }) — puede ser lag normal; repetir"
else
  fail "algún nodo no respondió a 'bao status': el quórum está comprometido"
fi

# `list-peers` aporta el rol de votante, que el chequeo de arriba no ve.
if [[ "${TOKEN_STATE}" == "ok" ]]; then
  PEERS="$(kubectl -n "${NAMESPACE}" exec -i "${ACTIVE}" \
    -- env BAO_TOKEN="${BAO_TOKEN}" bao operator raft list-peers 2>/dev/null || true)"
  echo "${PEERS}" | sed 's/^/      /'
  PEER_COUNT="$(echo "${PEERS}" | grep -c "openbao-" || true)"
  [[ "${PEER_COUNT}" -eq 3 ]] && pass "3 peers votantes en el quórum" \
    || fail "${PEER_COUNT} peers (esperaba 3)"
else
  skip "list-peers — BAO_TOKEN ${TOKEN_STATE}; el quórum ya quedó verificado arriba"
fi

SEALED="$(kubectl -n "${NAMESPACE}" exec -i "${ACTIVE}" -- bao status -format=json 2>/dev/null \
  | grep -o '"sealed": *[a-z]*' | awk '{print $2}')"
[[ "${SEALED}" == "false" ]] && pass "desellado" || fail "sealed=${SEALED}"

# ===========================================================================
echo
echo "[2/5] Auto-unseal — matar al líder y ver si vuelve SOLO"
# ===========================================================================
if [[ -n "${SKIP_FAILOVER}" ]]; then
  warn "saltado (SKIP_FAILOVER=1)"
else
  echo "      borrando ${ACTIVE}..."
  kubectl -n "${NAMESPACE}" delete pod "${ACTIVE}" --wait=false >/dev/null

  # El failover debería ser cuestión de segundos: otro nodo toma el liderazgo.
  for _ in $(seq 1 30); do
    NEW_ACTIVE="$(active_pod)"
    [[ -n "${NEW_ACTIVE}" && "${NEW_ACTIVE}" != "${ACTIVE}" ]] && break
    sleep 2
  done
  [[ -n "${NEW_ACTIVE:-}" && "${NEW_ACTIVE}" != "${ACTIVE}" ]] \
    && pass "failover a ${NEW_ACTIVE}" \
    || fail "no hubo failover (líder sigue siendo ${ACTIVE:-ninguno})"

  echo "      esperando a que ${ACTIVE} vuelva Ready sin unseal manual..."
  if kubectl -n "${NAMESPACE}" wait --for=condition=Ready "pod/${ACTIVE}" --timeout=180s >/dev/null 2>&1; then
    pass "${ACTIVE} volvió desellado solo (Cloud KMS funcionando)"
  else
    fail "${ACTIVE} no volvió Ready — revisá el binding de Workload Identity"
  fi
  ACTIVE="$(active_pod)"
fi

# ===========================================================================
echo
echo "[3/5] Ingress de Kong"
# ===========================================================================
KONG_LB="${KONG_LB:-35.192.128.2}"
DNS_IPS="$(dig +short "${HOST}" | tr '\n' ' ')"
echo "      ${HOST} → ${DNS_IPS:-<sin resolver>}"
if [[ -z "${DNS_IPS}" ]]; then
  fail "DNS no resuelve — falta el registro en Cloudflare"
elif [[ "${DNS_IPS}" == *"${KONG_LB}"* ]]; then
  # El allowlist vive en Cloudflare (Kong no ve la IP del cliente por el SNAT
  # del Service; ver k8s/docs/edge-client-ip.md). Sin proxy, Cloudflare no está
  # en el camino y no hay ningún filtro por IP.
  fail "DNS apunta directo al LB (${KONG_LB}): el registro NO está proxied → el allowlist de Cloudflare no se aplica. Ver k8s/docs/edge-client-ip.md"
else
  pass "DNS proxied por Cloudflare (${DNS_IPS}) — el allowlist del edge se aplica"
fi

HTTPS_CODE="$(curl -s -o /dev/null -w '%{http_code}' "${BAO_ADDR}/v1/sys/health" || echo 000)"
# 200 = activo y desellado. 429/473/501/503 = otros estados de sys/health.
[[ "${HTTPS_CODE}" == "200" ]] && pass "GET /v1/sys/health → 200" || fail "GET /v1/sys/health → ${HTTPS_CODE}"

REDIRECT="$(curl -s -o /dev/null -w '%{http_code}' "http://${HOST}/v1/sys/health" || echo 000)"
if [[ "${REDIRECT}" == "301" ]]; then
  pass "HTTP → 301 a HTTPS"
else
  # Si acá aparece un bucle de redirección, Cloudflare está en modo Flexible
  # (HTTP al origen) y hay que ponerlo en Full. Ver k8s/docs/kong-ingress.md.
  warn "HTTP devolvió ${REDIRECT} (esperaba 301) — revisar el modo SSL de Cloudflare"
fi

# El Ingress apunta al Service openbao-active. Comprobamos que sus endpoints
# sean exactamente el pod líder (y no los 3).
EP="$(kubectl -n "${NAMESPACE}" get endpoints openbao-active \
  -o jsonpath='{.subsets[0].addresses[*].targetRef.name}' 2>/dev/null || true)"
if [[ "${EP}" == "${ACTIVE}" ]]; then
  pass "openbao-active apunta solo al líder (${EP})"
else
  fail "openbao-active apunta a '${EP}' (esperaba solo '${ACTIVE}')"
fi

# ===========================================================================
echo
echo "[4/5] Control de acceso por IP"
# ===========================================================================
# Kong NO ve la IP del cliente: el Service gateway-kong-proxy tiene
# externalTrafficPolicy: Cluster y kube-proxy hace SNAT. Por eso el allowlist
# vive en Cloudflare y NO hay un KongPlugin/ip-restriction.
# Análisis completo: k8s/docs/edge-client-ip.md
MY_IP="$(curl -s https://ifconfig.me 2>/dev/null || echo '?')"
echo "      tu IP pública: ${MY_IP}"

# Regresión: si alguien vuelve a añadir el ip-restriction sin haber arreglado
# el edge, bloquearía a todos los clientes. Mejor detectarlo acá.
if kubectl -n "${NAMESPACE}" get kongplugin openbao-ip-restriction >/dev/null 2>&1; then
  fail "existe un KongPlugin/openbao-ip-restriction: Kong no ve la IP real del cliente, así que ese plugin bloquea a TODOS. Ver k8s/docs/edge-client-ip.md"
else
  pass "sin ip-restriction en Kong (correcto: el allowlist va en Cloudflare)"
fi

# El rate-limiting debe limitar por servicio, no por IP: con el SNAT todos los
# clientes comparten la IP de nodo y `limit_by: ip` sería un límite global
# disfrazado de límite por cliente.
LIMIT_BY="$(kubectl -n "${NAMESPACE}" get kongplugin openbao-rate-limiting \
  -o jsonpath='{.config.limit_by}' 2>/dev/null || echo '?')"
if [[ "${LIMIT_BY}" == "service" ]]; then
  pass "rate-limiting con limit_by=service"
else
  warn "rate-limiting con limit_by=${LIMIT_BY} (se espera 'service' — con SNAT, 'ip' es un límite global encubierto)"
fi

cat <<'EOF'

      VERIFICACIÓN MANUAL (no se puede automatizar desde acá):
      pedí a alguien con una IP NO autorizada en Cloudflare que corra:

          curl -s -o /dev/null -w '%{http_code}\n' https://vault.l-net.io/v1/sys/health

      Debe devolver 403 (bloqueo del edge de Cloudflare). Si devuelve 200,
      falta la IP Access Rule / WAF rule → k8s/docs/deployment.md, paso 8.
EOF

# ===========================================================================
echo
echo "[5/5] Firma end-to-end vía ${BAO_ADDR}"
# ===========================================================================
if [[ "${TOKEN_STATE}" != "ok" ]]; then
  skip "firma end-to-end — BAO_TOKEN ${TOKEN_STATE}; necesita un token administrativo"
  echo "      Lo demás ya se verificó: el cluster está sano y el edge responde."
  operator_token_hint "${ACTIVE}"
  echo
  if [[ "${FAILURES}" -eq 0 ]]; then
    printf '\033[0;32mSmoke test OK\033[0m — %d fallos, %d saltados (sin token)\n' \
      "${FAILURES}" "${SKIPPED}"
    exit 0
  else
    printf '\033[0;31mSmoke test con %d fallo(s)\033[0m, %d saltados\n' "${FAILURES}" "${SKIPPED}"
    exit 1
  fi
fi

hdr=(-H "X-Vault-Token: ${BAO_TOKEN}" -H "Content-Type: application/json")

# UNA sola llamada: el código HTTP va en la última línea (cada POST a /accounts
# genera una llave nueva, así que pedirlo dos veces ensuciaría el vault).
ACCOUNT_RAW="$(curl -s -w '\n%{http_code}' "${hdr[@]}" -d '{}' \
  "${BAO_ADDR}/v1/${MOUNT_PATH}/accounts" || echo $'\n000')"
ACCOUNT_CODE="$(printf '%s' "${ACCOUNT_RAW}" | tail -n1)"
ACCOUNT_JSON="$(printf '%s' "${ACCOUNT_RAW}" | sed '$d')"
ADDRESS="$(echo "${ACCOUNT_JSON}" | sed -n 's/.*"address":"\([^"]*\)".*/\1/p')"
if [[ -n "${ADDRESS}" ]]; then
  pass "cuenta creada: ${ADDRESS}"
elif [[ "${ACCOUNT_CODE}" == "403" ]]; then
  # El token pasó el lookup pero no tiene permisos sobre el engine: es un
  # problema de POLÍTICA, no de credencial ni de cluster.
  fail "403 al crear la cuenta: el token es válido pero su política no cubre ${MOUNT_PATH}/accounts"
  echo; printf 'Fallos: %d\n' "${FAILURES}"; exit 1
else
  fail "no se pudo crear la cuenta (HTTP ${ACCOUNT_CODE}): ${ACCOUNT_JSON}"
  echo; printf 'Fallos: %d\n' "${FAILURES}"; exit 1
fi

SIGNED="$(curl -s "${hdr[@]}" -d "{
    \"to\": \"0x9aef1bf4d1c5a261a5c5dd9c826b53e6e7c7f9d8\",
    \"data\": \"0x\",
    \"value\": \"0\",
    \"nonce\": \"0x0\",
    \"gas\": 21000,
    \"gasPrice\": 0,
    \"chainId\": \"${CHAIN_ID}\"
  }" "${BAO_ADDR}/v1/${MOUNT_PATH}/accounts/${ADDRESS}/sign" || true)"

if echo "${SIGNED}" | grep -q '"signed_transaction"'; then
  pass "transacción firmada (RLP, EIP-155 chainId=${CHAIN_ID})"
  echo "${SIGNED}" | sed 's/^/      /' | cut -c1-160
else
  fail "la firma falló: ${SIGNED}"
fi

# Y que exportar la llave esté prohibido si el token usa la política signer.
EXPORT_CODE="$(curl -s -o /dev/null -w '%{http_code}' "${hdr[@]}" \
  "${BAO_ADDR}/v1/${MOUNT_PATH}/export/accounts/${ADDRESS}" || echo 000)"
if [[ "${EXPORT_CODE}" == "403" ]]; then
  pass "export de la llave privada denegado (403)"
else
  warn "export devolvió ${EXPORT_CODE} — esperado si estás usando el ROOT token;"
  warn "con un token de la política ethsign-signer debe ser 403"
fi

# ===========================================================================
echo
if [[ "${FAILURES}" -eq 0 ]]; then
  printf '\033[0;32mSmoke test OK\033[0m — %d fallos, %d saltados\n' "${FAILURES}" "${SKIPPED}"
else
  printf '\033[0;31mSmoke test con %d fallo(s)\033[0m, %d saltados\n' "${FAILURES}" "${SKIPPED}"
  exit 1
fi
