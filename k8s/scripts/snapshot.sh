#!/usr/bin/env bash
#
# Snapshot manual de Raft → GCS. Es lo mismo que hace el CronJob
# (k8s/backup/snapshot-cronjob.yaml) pero on-demand, desde tu máquina.
#
# CUÁNDO USARLO: siempre ANTES de un upgrade de chart/imagen, antes de tocar
# políticas a lo grande, y antes de cualquier operación sobre los PVCs.
#
# Un snapshot contiene TODO el estado de OpenBao (llaves incluidas) cifrado con
# la root key. Sin acceso a la KMS key el archivo es inútil — pero igual se
# trata como material sensible.
#
# Uso:
#   BAO_TOKEN=<token con la política 'snapshot' o root> ./k8s/scripts/snapshot.sh
#   LABEL=pre-upgrade-2.6.1 ./k8s/scripts/snapshot.sh
#
set -euo pipefail

NAMESPACE="${NAMESPACE:-openbao}"
BUCKET="${BUCKET:-lnet-openbao-snapshots}"
LABEL="${LABEL:-manual}"
TS="$(date -u '+%Y%m%dT%H%M%SZ')"
OUT="openbao-${LABEL}-${TS}.snap"

: "${BAO_TOKEN:?Exportá BAO_TOKEN (política 'snapshot' o root token)}"

ACTIVE_POD="$(kubectl -n "${NAMESPACE}" get pods \
  -l app.kubernetes.io/name=openbao,openbao-active=true \
  -o jsonpath='{.items[0].metadata.name}')"
echo "==> Nodo activo: ${ACTIVE_POD}"

# El snapshot se toma dentro del pod y se copia afuera. Se escribe en /tmp del
# contenedor (no en el PVC de datos) para no inflar el volumen de Raft.
echo "==> Tomando el snapshot"
kubectl -n "${NAMESPACE}" exec -i "${ACTIVE_POD}" \
  -- env BAO_TOKEN="${BAO_TOKEN}" \
     bao operator raft snapshot save "/tmp/${OUT}"

echo "==> Copiando fuera del pod"
kubectl -n "${NAMESPACE}" cp "${ACTIVE_POD}:/tmp/${OUT}" "/tmp/${OUT}"
kubectl -n "${NAMESPACE}" exec "${ACTIVE_POD}" -- rm -f "/tmp/${OUT}"

SIZE="$(wc -c < "/tmp/${OUT}" | tr -d ' ')"
if [[ "${SIZE}" -lt 1024 ]]; then
  echo "El snapshot pesa ${SIZE} bytes — sospechosamente chico. Abortando la subida."
  exit 1
fi
echo "    ${SIZE} bytes"

DEST="gs://${BUCKET}/manual/${TS}/${OUT}"
echo "==> Subiendo a ${DEST}"
gcloud storage cp "/tmp/${OUT}" "${DEST}"

rm -f "/tmp/${OUT}"

cat <<EOF

==> Listo: ${DEST}

Para restaurar (⚠️ SOBREESCRIBE TODO el estado del cluster):
    gcloud storage cp ${DEST} /tmp/restore.snap
    kubectl -n ${NAMESPACE} cp /tmp/restore.snap ${ACTIVE_POD}:/tmp/restore.snap
    kubectl -n ${NAMESPACE} exec -it ${ACTIVE_POD} -- \\
      bao operator raft snapshot restore -force /tmp/restore.snap

El restore requiere que el cluster destino use LA MISMA KMS key (o hay que
migrar el seal). Procedimiento completo en k8s/docs/operations.md.
EOF
