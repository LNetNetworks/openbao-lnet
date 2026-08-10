#!/usr/bin/env bash
#
# Configuración post-init de OpenBao: audit device, autopilot, método de auth
# de Kubernetes, políticas y roles. Al final ofrece REVOCAR el root token.
#
# IDEMPOTENTE: se puede correr de nuevo tras un cambio de políticas.
#
# Después de esto, ningún consumidor usa un token estático: cada pod se
# autentica con su ServiceAccount de Kubernetes y recibe un token de vida corta.
#
# Uso:
#   BAO_TOKEN=<root-token> ./k8s/scripts/bootstrap-auth.sh
#
set -euo pipefail

NAMESPACE="${NAMESPACE:-openbao}"
MOUNT_PATH="${MOUNT_PATH:-ethereum}"
# Namespaces cuyos pods pueden pedir firmas. Ajustar a los consumidores reales.
SIGNER_NAMESPACES="${SIGNER_NAMESPACES:-naas,ppr,lnet-tools}"
SIGNER_SERVICE_ACCOUNTS="${SIGNER_SERVICE_ACCOUNTS:-*}"

: "${BAO_TOKEN:?Exportá BAO_TOKEN con el root token}"

ACTIVE_POD="$(kubectl -n "${NAMESPACE}" get pods \
  -l app.kubernetes.io/name=openbao,openbao-active=true \
  -o jsonpath='{.items[0].metadata.name}')"
echo "==> Nodo activo: ${ACTIVE_POD}"

kexec() {
  kubectl -n "${NAMESPACE}" exec -i "${ACTIVE_POD}" \
    -- env BAO_TOKEN="${BAO_TOKEN}" "$@"
}
# Para pasar heredocs (políticas) por stdin.
kexec_stdin() {
  kubectl -n "${NAMESPACE}" exec -i "${ACTIVE_POD}" \
    -- env BAO_TOKEN="${BAO_TOKEN}" "$@"
}

# ---------------------------------------------------------------------------
# 1. Audit device
#
# Sin esto no hay rastro de quién pidió qué firma. Es el requisito no negociable
# de un sistema que custodia llaves privadas.
# El PVC `audit` (10Gi) ya está montado en /openbao/audit por el chart.
#
# OJO: si el audit device no puede escribir, OpenBao DEJA DE RESPONDER (a
# propósito: prefiere caerse antes que operar sin auditoría). Vigilar el uso del
# disco — hay una alerta sugerida en k8s/docs/operations.md.
# ---------------------------------------------------------------------------
echo "==> Audit device en /openbao/audit/audit.log"
if kexec bao audit list -format=json 2>/dev/null | grep -q '"file/"'; then
  echo "    activo (declarativo) — OK"
else
  red "NO hay audit device activo. Abortando ANTES de configurar auth."
  echo
  echo "Ya no se habilita por API: desde OpenBao 2.3.2 'bao audit enable' falla"
  echo "con 'cannot enable audit device via API'. El device se declara en el HCL"
  echo "del Application (bloque audit \"file\" \"file\"), y este script solo verifica."
  echo
  echo "Comprobá, en este orden:"
  echo "  1. Que el bloque esté en la config viva:"
  echo "       kubectl -n ${NAMESPACE} get cm openbao-config -o yaml | grep -A6 audit"
  echo "  2. Que los pods hayan tomado la config nueva (rollout completo):"
  echo "       kubectl -n ${NAMESPACE} rollout status sts/openbao"
  echo "  3. Que el PVC de audit esté montado y con espacio:"
  echo "       kubectl -n ${NAMESPACE} exec ${POD} -- df -h /openbao/audit"
  exit 1
fi

# ---------------------------------------------------------------------------
# 2. Autopilot de Raft
#
# No se puede poner en el HCL (`storage "raft"` no acepta un bloque autopilot),
# se configura por API.
#   - cleanup_dead_servers: saca del quórum a un nodo que no vuelve
#   - min_quorum=3: nunca reducir el cluster por debajo de 3 votantes
# ---------------------------------------------------------------------------
echo "==> Autopilot de Raft"
kexec bao operator raft autopilot set-config \
  -cleanup-dead-servers=true \
  -dead-server-last-contact-threshold=10m \
  -min-quorum=3 \
  -server-stabilization-time=30s

kexec bao operator raft autopilot state || true

# ---------------------------------------------------------------------------
# 3. Políticas
# ---------------------------------------------------------------------------
echo "==> Política 'ethsign-signer' (crear cuentas y firmar; NO exportar)"
kexec_stdin bao policy write ethsign-signer - <<EOF
# Crear cuentas nuevas y listarlas
path "${MOUNT_PATH}/accounts" {
  capabilities = ["create", "update", "list"]
}

# Leer los metadatos de una cuenta (address, etc.)
path "${MOUNT_PATH}/accounts/*" {
  capabilities = ["read"]
}

# Firmar
path "${MOUNT_PATH}/accounts/+/sign" {
  capabilities = ["create", "update"]
}

# EXPORTAR LA LLAVE PRIVADA ESTÁ EXPLÍCITAMENTE DENEGADO.
# Es el punto entero del diseño: la llave no sale del vault.
path "${MOUNT_PATH}/export/*" {
  capabilities = ["deny"]
}

# Renovar/revocar el propio token
path "auth/token/renew-self" {
  capabilities = ["update"]
}
path "auth/token/revoke-self" {
  capabilities = ["update"]
}
EOF

echo "==> Política 'snapshot' (solo tomar snapshots de Raft)"
kexec_stdin bao policy write snapshot - <<'EOF'
path "sys/storage/raft/snapshot" {
  capabilities = ["read"]
}
EOF

echo "==> Política 'openbao-operator' (día a día sin root token)"
kexec_stdin bao policy write openbao-operator - <<'EOF'
# Salud y estado del cluster
path "sys/health"                     { capabilities = ["read", "sudo"] }
path "sys/leader"                     { capabilities = ["read"] }
path "sys/seal-status"                { capabilities = ["read"] }
path "sys/storage/raft/*"             { capabilities = ["read", "list", "sudo"] }

# Gestión de engines, políticas y auth
path "sys/mounts"                     { capabilities = ["read", "list"] }
path "sys/mounts/*"                   { capabilities = ["create", "read", "update", "delete", "list", "sudo"] }
path "sys/auth"                       { capabilities = ["read", "list"] }
path "sys/auth/*"                     { capabilities = ["create", "read", "update", "delete", "sudo"] }
path "sys/policies/acl/*"             { capabilities = ["create", "read", "update", "delete", "list"] }
path "sys/plugins/catalog/*"          { capabilities = ["create", "read", "update", "list", "sudo"] }
path "auth/kubernetes/role/*"         { capabilities = ["create", "read", "update", "delete", "list"] }

# Auditoría
path "sys/audit"                      { capabilities = ["read", "list", "sudo"] }
path "sys/audit/*"                    { capabilities = ["create", "update", "sudo"] }
EOF

# ---------------------------------------------------------------------------
# 4. Método de auth de Kubernetes
#
# Con esto los consumidores dejan de necesitar un token estático: presentan el
# JWT de su ServiceAccount y reciben un token de OpenBao de vida corta.
# `disable_local_ca_jwt` queda en false → OpenBao usa el CA y el token del propio
# pod para validar contra la API de Kubernetes. No hay credenciales que rotar.
# ---------------------------------------------------------------------------
echo "==> Método de auth 'kubernetes'"
if kexec bao auth list -format=json | grep -q '"kubernetes/"'; then
  echo "    ya habilitado — skip"
else
  kexec bao auth enable kubernetes
fi

kexec sh -c 'bao write auth/kubernetes/config \
  kubernetes_host="https://${KUBERNETES_SERVICE_HOST}:${KUBERNETES_SERVICE_PORT}"'

echo "==> Rol 'ethsign-signer' (namespaces: ${SIGNER_NAMESPACES})"
kexec bao write auth/kubernetes/role/ethsign-signer \
  bound_service_account_names="${SIGNER_SERVICE_ACCOUNTS}" \
  bound_service_account_namespaces="${SIGNER_NAMESPACES}" \
  policies=ethsign-signer \
  ttl=1h \
  max_ttl=4h

echo "==> Rol 'snapshot' (para el CronJob de backups)"
kexec bao write auth/kubernetes/role/snapshot \
  bound_service_account_names=openbao-snapshot \
  bound_service_account_namespaces="${NAMESPACE}" \
  policies=snapshot \
  ttl=15m \
  max_ttl=30m

# ---------------------------------------------------------------------------
# 5. Revocación del root token
# ---------------------------------------------------------------------------
cat <<EOF

==============================================================================
Bootstrap completo. Resumen:

  audit device   → /openbao/audit/audit.log
  autopilot      → cleanup_dead_servers, min_quorum=3
  políticas      → ethsign-signer, snapshot, openbao-operator
  auth k8s       → roles ethsign-signer, snapshot

ÚLTIMO PASO RECOMENDADO: revocar el root token.

Un root token vivo e indefinido es la peor deuda de seguridad de un vault.
Se regenera cuando haga falta con 3 de las 5 recovery keys:

    kubectl -n ${NAMESPACE} exec -it ${ACTIVE_POD} -- bao operator generate-root -init
    # ... aportar los shares ...
    kubectl -n ${NAMESPACE} exec -it ${ACTIVE_POD} -- bao operator generate-root -decode=... -otp=...

Para revocarlo ahora:

    kubectl -n ${NAMESPACE} exec -i ${ACTIVE_POD} -- \\
      env BAO_TOKEN="\$BAO_TOKEN" bao token revoke -self

(No lo hace este script automáticamente: querés correr antes el smoke-test.)
==============================================================================
EOF
