#!/usr/bin/env bash
#
# Prerrequisitos GCP para OpenBao en GKE. IDEMPOTENTE: se puede correr N veces.
#
# Crea:
#   1. Key ring + crypto key de Cloud KMS  → protege la root key (auto-unseal)
#   2. GSA `openbao-kms`                   → identidad de los pods
#   3. Binding de Workload Identity        → KSA openbao/openbao ⇄ GSA
#   4. Bucket GCS para snapshots           → versionado + lifecycle
#   5. IAM: encrypt/decrypt sobre la key, objectAdmin sobre el bucket
#
# NO crea el secret de recovery keys — eso lo hace scripts/init-openbao.sh
# después del `bao operator init`.
#
# Uso:
#   ./k8s/gcp/setup-gcp.sh            # aplica
#   DRY_RUN=1 ./k8s/gcp/setup-gcp.sh  # solo imprime lo que haría
#
# Requiere: gcloud autenticado con permisos de cloudkms.admin, iam.admin y
# storage.admin sobre el proyecto.
#
set -euo pipefail

PROJECT_ID="${PROJECT_ID:-l-net-469615}"
KMS_LOCATION="${KMS_LOCATION:-global}"
KMS_KEYRING="${KMS_KEYRING:-openbao-unseal}"
KMS_KEY="${KMS_KEY:-openbao-unseal-key}"
GSA_NAME="${GSA_NAME:-openbao-kms}"
GSA_EMAIL="${GSA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"
K8S_NAMESPACE="${K8S_NAMESPACE:-openbao}"
K8S_SA="${K8S_SA:-openbao}"
K8S_SA_SNAPSHOT="${K8S_SA_SNAPSHOT:-openbao-snapshot}"
BUCKET="${BUCKET:-lnet-openbao-snapshots}"
BUCKET_LOCATION="${BUCKET_LOCATION:-us-central1}"
SNAPSHOT_RETENTION_DAYS="${SNAPSHOT_RETENTION_DAYS:-30}"

DRY_RUN="${DRY_RUN:-}"

run() {
  if [[ -n "$DRY_RUN" ]]; then
    echo "    [dry-run] $*"
  else
    "$@"
  fi
}

echo "==> Proyecto: ${PROJECT_ID}"
gcloud config set project "${PROJECT_ID}" >/dev/null 2>&1 || true

# ---------------------------------------------------------------------------
# 0. APIs necesarias
# ---------------------------------------------------------------------------
echo "==> Habilitando APIs (cloudkms, iamcredentials, storage, secretmanager)"
run gcloud services enable \
  cloudkms.googleapis.com \
  iamcredentials.googleapis.com \
  storage.googleapis.com \
  secretmanager.googleapis.com \
  --project="${PROJECT_ID}"

# ---------------------------------------------------------------------------
# 1. Cloud KMS — key ring + crypto key
#
# La key NO se puede borrar (solo deshabilitar/destruir versiones). Perder esta
# key = perder la root key = OpenBao no vuelve a abrir NUNCA, ni con las
# recovery keys. Ver k8s/docs/unseal-keys.md.
# ---------------------------------------------------------------------------
echo "==> Key ring ${KMS_KEYRING} (${KMS_LOCATION})"
if gcloud kms keyrings describe "${KMS_KEYRING}" \
     --location="${KMS_LOCATION}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
  echo "    ya existe — skip"
else
  run gcloud kms keyrings create "${KMS_KEYRING}" \
    --location="${KMS_LOCATION}" --project="${PROJECT_ID}"
fi

echo "==> Crypto key ${KMS_KEY}"
if gcloud kms keys describe "${KMS_KEY}" \
     --keyring="${KMS_KEYRING}" --location="${KMS_LOCATION}" \
     --project="${PROJECT_ID}" >/dev/null 2>&1; then
  echo "    ya existe — skip"
else
  # Rotación cada 90 días: las versiones viejas se conservan, así que el
  # material cifrado con ellas se sigue pudiendo descifrar.
  run gcloud kms keys create "${KMS_KEY}" \
    --keyring="${KMS_KEYRING}" \
    --location="${KMS_LOCATION}" \
    --purpose=encryption \
    --rotation-period=90d \
    --next-rotation-time="$(date -u -v+90d '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -d '+90 days' '+%Y-%m-%dT%H:%M:%SZ')" \
    --project="${PROJECT_ID}"
fi

# ---------------------------------------------------------------------------
# 2. Service Account de Google
# ---------------------------------------------------------------------------
echo "==> GSA ${GSA_EMAIL}"
if gcloud iam service-accounts describe "${GSA_EMAIL}" \
     --project="${PROJECT_ID}" >/dev/null 2>&1; then
  echo "    ya existe — skip"
else
  run gcloud iam service-accounts create "${GSA_NAME}" \
    --display-name="OpenBao auto-unseal + snapshots" \
    --description="Usada por los pods de OpenBao (ns openbao) vía Workload Identity" \
    --project="${PROJECT_ID}"
fi

# ---------------------------------------------------------------------------
# 3. IAM sobre la KMS key — SOLO encrypt/decrypt + lectura, nunca admin
# ---------------------------------------------------------------------------
echo "==> Permiso encrypt/decrypt sobre ${KMS_KEY}"
run gcloud kms keys add-iam-policy-binding "${KMS_KEY}" \
  --keyring="${KMS_KEYRING}" \
  --location="${KMS_LOCATION}" \
  --member="serviceAccount:${GSA_EMAIL}" \
  --role="roles/cloudkms.cryptoKeyEncrypterDecrypter" \
  --project="${PROJECT_ID}" \
  --condition=None

# El seal gcpckms hace un check de existencia de la llave al arrancar, que
# necesita cloudkms.cryptoKeys.get — permiso que cryptoKeyEncrypterDecrypter
# NO incluye. Sin esto los pods entran en CrashLoopBackOff con
# "Error configuring seal gcpckms: error checking key existence: PermissionDenied".
# viewer va acotado al recurso de la llave: solo metadatos, nada de admin.
echo "==> Permiso de lectura (cryptoKeys.get) sobre ${KMS_KEY}"
run gcloud kms keys add-iam-policy-binding "${KMS_KEY}" \
  --keyring="${KMS_KEYRING}" \
  --location="${KMS_LOCATION}" \
  --member="serviceAccount:${GSA_EMAIL}" \
  --role="roles/cloudkms.viewer" \
  --project="${PROJECT_ID}" \
  --condition=None

# ---------------------------------------------------------------------------
# 4. Bucket de snapshots
# ---------------------------------------------------------------------------
echo "==> Bucket gs://${BUCKET}"
if gcloud storage buckets describe "gs://${BUCKET}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
  echo "    ya existe — skip"
else
  run gcloud storage buckets create "gs://${BUCKET}" \
    --location="${BUCKET_LOCATION}" \
    --uniform-bucket-level-access \
    --public-access-prevention \
    --project="${PROJECT_ID}"
fi

echo "==> Versionado + lifecycle (${SNAPSHOT_RETENTION_DAYS}d)"
run gcloud storage buckets update "gs://${BUCKET}" --versioning --project="${PROJECT_ID}"

LIFECYCLE_JSON="$(mktemp)"
cat > "${LIFECYCLE_JSON}" <<EOF
{
  "rule": [
    {
      "action": {"type": "Delete"},
      "condition": {"age": ${SNAPSHOT_RETENTION_DAYS}, "isLive": true}
    },
    {
      "action": {"type": "Delete"},
      "condition": {"daysSinceNoncurrentTime": 7}
    }
  ]
}
EOF
run gcloud storage buckets update "gs://${BUCKET}" \
  --lifecycle-file="${LIFECYCLE_JSON}" --project="${PROJECT_ID}"
rm -f "${LIFECYCLE_JSON}"

echo "==> Permiso objectAdmin sobre gs://${BUCKET}"
run gcloud storage buckets add-iam-policy-binding "gs://${BUCKET}" \
  --member="serviceAccount:${GSA_EMAIL}" \
  --role="roles/storage.objectAdmin" \
  --project="${PROJECT_ID}"

# ---------------------------------------------------------------------------
# 5. Workload Identity — dos KSA usan el mismo GSA:
#      openbao/openbao           → los servidores (auto-unseal con KMS)
#      openbao/openbao-snapshot  → el CronJob de snapshots (escribe en GCS)
# ---------------------------------------------------------------------------
for ksa in "${K8S_SA}" "${K8S_SA_SNAPSHOT}"; do
  echo "==> Workload Identity: ${K8S_NAMESPACE}/${ksa} → ${GSA_EMAIL}"
  run gcloud iam service-accounts add-iam-policy-binding "${GSA_EMAIL}" \
    --role="roles/iam.workloadIdentityUser" \
    --member="serviceAccount:${PROJECT_ID}.svc.id.goog[${K8S_NAMESPACE}/${ksa}]" \
    --project="${PROJECT_ID}" \
    --condition=None
done

# ---------------------------------------------------------------------------
# Resumen
# ---------------------------------------------------------------------------
cat <<EOF

==============================================================================
Listo. Valores que deben coincidir con k8s/argocd/openbao-application.yaml:

  seal "gcpckms" {
    project    = "${PROJECT_ID}"
    region     = "${KMS_LOCATION}"
    key_ring   = "${KMS_KEYRING}"
    crypto_key = "${KMS_KEY}"
  }

  serviceAccount.annotations:
    iam.gke.io/gcp-service-account: ${GSA_EMAIL}

  Bucket de snapshots: gs://${BUCKET}

Siguiente paso: build+push de la imagen y sync de la Application.
Ver k8s/docs/deployment.md, paso 2.
==============================================================================
EOF
