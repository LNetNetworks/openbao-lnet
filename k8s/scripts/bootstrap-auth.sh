#!/usr/bin/env bash
#
# Configuración post-init de OpenBao: audit device, autopilot, método de auth
# de Kubernetes, políticas y roles. Al final ofrece REVOCAR el root token.
#
# IDEMPOTENTE: se puede correr de nuevo tras un cambio de políticas.
#
# El script PRUEBA el camino de vuelta antes de sugerir la revocación: emite un
# token por el rol de operador y comprueba que puede leer sys/mounts. Si eso
# falla, aborta. En OpenBao ≥2.6.0 las recovery keys NO acuñan un root token por
# sí solas (`generate-root` pasó a ser un endpoint autenticado), así que ese rol
# es la única vía de administración cuando no hay root token.
# Ver k8s/docs/admin-access-recovery.md.
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
# ServiceAccount (en el namespace de OpenBao) que da acceso administrativo.
# Quien pueda `kubectl create token` sobre ella es operador del vault.
OPERATOR_SA="${OPERATOR_SA:-openbao-operator}"

red() { printf '\033[0;31m%s\033[0m\n' "$*" >&2; }

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
echo "==> Política 'ethsign-signer' (crear cuentas y firmar txs; NO exportar ni firmar digests)"
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

# FIRMAR DIGESTS CRUDOS ESTÁ EXPLÍCITAMENTE DENEGADO.
# El hash de una tx es keccak256(RLP(tx)), calculable off-chain: quien pueda
# firmar un digest arbitrario puede armar cualquier transacción. Va en su propia
# política (ethsign-credentials, ver k8s/docs/plugin-update.md §6), no acá.
path "${MOUNT_PATH}/accounts/+/sign-digest" {
  capabilities = ["deny"]
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
# 4b. Rol de OPERADOR — el camino de vuelta cuando no hay root token
#
# ESTO NO ES OPCIONAL. Desde OpenBao 2.6.0 `bao operator generate-root` usa un
# endpoint AUTENTICADO (`sys/generate-root-token`): las recovery keys por sí
# solas NO acuñan un root token. Sin un rol que entregue la política
# `openbao-operator`, revocar el root token deja el vault sin ninguna vía de
# administración — no se puede crear una política, un rol, ni montar un engine.
# Pasó en producción el 2026-08-17. Ver k8s/docs/admin-access-recovery.md.
#
# El control de acceso se delega en el RBAC de Kubernetes: quien pueda hacer
# `kubectl create token openbao-operator -n openbao` obtiene un token de
# operador. Eso es auditable y ya existe, a diferencia de un token estático.
# ---------------------------------------------------------------------------
echo "==> ServiceAccount '${OPERATOR_SA}' en ${NAMESPACE} (identidad del operador)"
kubectl -n "${NAMESPACE}" create serviceaccount "${OPERATOR_SA}" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null

echo "==> Rol '${OPERATOR_SA}' (TTL corto: es acceso administrativo)"
kexec bao write "auth/kubernetes/role/${OPERATOR_SA}" \
  bound_service_account_names="${OPERATOR_SA}" \
  bound_service_account_namespaces="${NAMESPACE}" \
  policies=openbao-operator \
  ttl=30m \
  max_ttl=2h

# --- Auto-test: el camino de vuelta se PRUEBA antes de ofrecer revocar --------
# La lección del 2026-08-17: verificar que la revocación funcionó no sirve de
# nada si no se verificó primero que se puede volver a entrar.
echo "==> Probando el camino de vuelta (login por auth/kubernetes con ${OPERATOR_SA})"
OPERATOR_JWT="$(kubectl -n "${NAMESPACE}" create token "${OPERATOR_SA}" --duration=600s 2>/dev/null || true)"
OPERATOR_TOKEN=""
if [[ -n "${OPERATOR_JWT}" ]]; then
  OPERATOR_LOGIN="$(kexec sh -c "BAO_TOKEN= bao write -format=json auth/kubernetes/login \
    role=${OPERATOR_SA} jwt='${OPERATOR_JWT}'" 2>/dev/null || true)"
  OPERATOR_TOKEN="$(printf '%s' "${OPERATOR_LOGIN}" \
    | sed -n 's/.*"client_token": *"\([^"]*\)".*/\1/p' | head -1)"
fi

if [[ -z "${OPERATOR_TOKEN}" ]]; then
  red "El login del rol '${OPERATOR_SA}' NO funcionó."
  echo "NO revoques el root token: te quedarías sin acceso administrativo y en"
  echo "este build las recovery keys no lo devuelven (ver"
  echo "k8s/docs/admin-access-recovery.md). Revisá auth/kubernetes/config y la"
  echo "ServiceAccount ${NAMESPACE}/${OPERATOR_SA} antes de seguir."
  exit 1
fi

# Que el token exista no alcanza: tiene que poder hacer trabajo de operador.
if kexec sh -c "BAO_TOKEN='${OPERATOR_TOKEN}' bao read sys/mounts" >/dev/null 2>&1; then
  echo "    OK — el token de operador lee sys/mounts. El camino de vuelta existe."
  kexec sh -c "BAO_TOKEN='${OPERATOR_TOKEN}' bao token revoke -self" >/dev/null 2>&1 || true
else
  red "El token de operador se emitió pero NO puede leer sys/mounts."
  echo "La política 'openbao-operator' no está haciendo efecto. NO revoques el"
  echo "root token hasta resolverlo."
  exit 1
fi

# ---------------------------------------------------------------------------
# 5. Revocación del root token
# ---------------------------------------------------------------------------
cat <<EOF

==============================================================================
Bootstrap completo. Resumen:

  audit device   → /openbao/audit/audit.log
  autopilot      → cleanup_dead_servers, min_quorum=3
  políticas      → ethsign-signer, snapshot, openbao-operator
  auth k8s       → roles ethsign-signer, snapshot, ${OPERATOR_SA}
  camino de vuelta PROBADO → login de ${OPERATOR_SA} + read sys/mounts OK

ÚLTIMO PASO RECOMENDADO: revocar el root token.

Un root token vivo e indefinido es la peor deuda de seguridad de un vault. Y
ahora es seguro revocarlo, porque el camino de vuelta se acaba de verificar:

    JWT=\$(kubectl -n ${NAMESPACE} create token ${OPERATOR_SA} --duration=1800s)
    BAO_TOKEN=\$(kubectl -n ${NAMESPACE} exec -i ${ACTIVE_POD} -- sh -c \\
      "BAO_TOKEN= bao write -field=token auth/kubernetes/login \\
         role=${OPERATOR_SA} jwt='\$JWT'")

⚠️ NO cuentes con 'bao operator generate-root'. Desde OpenBao 2.6.0 ese comando
   usa un endpoint AUTENTICADO: las 5 recovery keys NO alcanzan para acuñar un
   root token — hace falta un token válido ADEMÁS de los shares. El rol
   '${OPERATOR_SA}' de arriba es la única vía práctica de administración sin
   root token. Detalle en k8s/docs/admin-access-recovery.md.

Para revocar el root token ahora:

    kubectl -n ${NAMESPACE} exec -i ${ACTIVE_POD} -- \\
      env BAO_TOKEN="\$BAO_TOKEN" bao token revoke -self

(No lo hace este script automáticamente: querés correr antes el smoke-test.)
==============================================================================
EOF
