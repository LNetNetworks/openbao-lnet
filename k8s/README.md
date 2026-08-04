# `k8s/` — despliegue de OpenBao en Kubernetes (producción)

Migración del POC de Docker Compose a **GKE `lnet-privado`** con Helm: 3 nodos
Raft en un StatefulSet, auto-unseal con Cloud KMS, publicado en
**https://vault.l-net.io** a través del Kong existente.

> **Empezá por [`docs/deployment.md`](docs/deployment.md)** — es la guía paso a
> paso de cero a producción, incluida la generación de las llaves.

---

## Qué hay acá

```
k8s/
├── argocd/
│   └── openbao-application.yaml   ← EL archivo que se copia a cloud-infra
├── gcp/
│   ├── setup-gcp.sh               KMS + GSA + Workload Identity + bucket GCS
│   └── terraform.tf.example       lo mismo en Terraform, para llevarlo a IaC
├── backup/
│   └── snapshot-cronjob.yaml      snapshots de Raft → GCS cada 6h
├── scripts/
│   ├── init-openbao.sh            ★ init + generación y custodia de las llaves
│   ├── register-plugin.sh         registra ethsign y monta ethereum/
│   ├── bootstrap-auth.sh          audit, autopilot, políticas, auth de K8s
│   ├── snapshot.sh                snapshot manual on-demand
│   └── smoke-test.sh              verificación end-to-end (incluye failover real)
├── ci/
│   └── gitlab-ci.example.yml      build automático + deploy MANUAL
└── docs/
    ├── deployment.md              ★ paso a paso
    ├── unseal-keys.md             recovery keys: custodia, rotación, desastres
    ├── kong-ingress.md            el Ingress y sus tres puntos de atención
    ├── edge-client-ip.md          ⚠ por qué Kong no ve la IP del cliente y qué hacer
    └── operations.md              runbook: failover, restore, upgrades, escalado
```

---

## Arquitectura en una pantalla

```
Cloudflare → Kong (35.192.128.2) → Service openbao-active → líder de Raft
                                                              │
                        StatefulSet openbao × 3 (1 pod por nodo)
                        PVC data 10Gi + PVC audit 10Gi por pod
                                     │ Workload Identity
                        Cloud KMS (auto-unseal) + GCS (snapshots)
```

| | POC (Docker Compose) | Este despliegue |
|---|---|---|
| HA | 3 contenedores, 1 host → no es HA | 3 pods en 3 nodos |
| Unseal | manual tras cada restart | automático (Cloud KMS) |
| Acceso | `localhost:8200` | `https://vault.l-net.io` |
| Backups | ninguno | CronJob → GCS cada 6h |
| Auth | root token a mano | ServiceAccounts de K8s + políticas |

---

## Arranque rápido

```bash
# 1. Recursos de GCP (idempotente)
./k8s/gcp/setup-gcp.sh

# 2. Imagen
export TAG=$(git rev-parse --short HEAD)
docker buildx build --platform linux/amd64 --build-arg OPENBAO_VERSION=2.6.1 \
  -t us-central1-docker.pkg.dev/l-net-469615/l-net-docker-repo/openbao-ethsign:$TAG --push .

# 3. Poner ese $TAG y los CIDRs del allowlist en argocd/openbao-application.yaml,
#    copiarlo a cloud-infra/gitops-apps/argocd-applications/openbao.yaml y pushear.

# 4. Los pods arrancan 0/1 Ready — es correcto, falta inicializar.
./k8s/scripts/init-openbao.sh        # ★ genera las llaves. UNA SOLA VEZ.

export BAO_TOKEN=<root_token>
./k8s/scripts/register-plugin.sh
./k8s/scripts/bootstrap-auth.sh
kubectl apply -f k8s/backup/snapshot-cronjob.yaml
./k8s/scripts/smoke-test.sh
```

Cada paso, con sus verificaciones y modos de fallo, en
[`docs/deployment.md`](docs/deployment.md).

---

## Cuatro cosas que conviene saber antes de tocar nada

1. **`init-openbao.sh` se corre una sola vez en la vida del cluster.** Correrlo
   sobre PVCs vacíos genera una root key nueva y deja irrecuperables todas las
   llaves privadas anteriores.
2. **Destruir la KMS key `openbao-unseal-key` cierra el vault para siempre**, ni
   las recovery keys ayudan. Por eso lleva `prevent_destroy` en el Terraform y
   el GSA solo tiene `cryptoKeyEncrypterDecrypter`.
3. **El cluster es zonal** (`us-central1-c`). Esto tolera la caída de un *nodo*,
   no de la *zona*. Ante pérdida de zona la recuperación es restore de snapshot,
   con RPO de hasta 6h.
4. **Kong no ve la IP del cliente** — el Service `gateway-kong-proxy` tiene
   `externalTrafficPolicy: Cluster` y kube-proxy hace SNAT. Por eso **no hay
   `KongPlugin/ip-restriction`** (bloquearía a todos) y el allowlist vive en
   **Cloudflare**. Medición, consecuencias y opciones para arreglarlo en el
   edge: [`docs/edge-client-ip.md`](docs/edge-client-ip.md).

---

## El POC local sigue funcionando

Nada de esta carpeta toca `docker-compose.yml` ni `docker-compose.ha.yml`. El
POC de una máquina y el cluster de 3 nodos en Docker siguen siendo válidos para
desarrollo y para aprender el comportamiento de Raft — ver
[`../docs/ha-cluster.md`](../docs/ha-cluster.md).
