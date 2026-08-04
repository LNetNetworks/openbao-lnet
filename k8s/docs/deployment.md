# Despliegue de OpenBao en Kubernetes — paso a paso

> Cluster `lnet-privado` (GKE, `l-net-469615`, `us-central1-c`) · dominio
> `vault.l-net.io` · 3 nodos Raft · auto-unseal con Cloud KMS.

Esta guía va de cero a "firmando transacciones en producción". Los pasos están
en orden y **el orden importa**: el plugin no se puede registrar antes de
inicializar, y no se puede inicializar antes de que los pods arranquen.

Tiempo estimado la primera vez: ~45 minutos (la mayoría, esperar builds y syncs).

---

## Qué se despliega

```
Internet
   │  vault.l-net.io → 35.192.128.2 (Cloudflare → LB de Kong)
   ▼
Kong Gateway (ns edge-system)
   │  Ingress class kong + KongPlugin ip-restriction + rate-limiting
   ▼
Service openbao-active (ns openbao)  ── selecciona SOLO al líder de Raft
   ▼
┌──────────────── StatefulSet openbao (3 réplicas) ────────────────┐
│  openbao-0        openbao-1        openbao-2                     │
│  PVC data 10Gi    PVC data 10Gi    PVC data 10Gi   ← Raft        │
│  PVC audit 10Gi   PVC audit 10Gi   PVC audit 10Gi                │
│  imagen: openbao-ethsign (OpenBao + plugin de firma secp256k1)   │
└──────────────────────────────────────────────────────────────────┘
   │ Workload Identity
   ▼
Cloud KMS  openbao-unseal/openbao-unseal-key   ← protege la root key
GCS        gs://lnet-openbao-snapshots         ← snapshots cada 6h
```

**Diferencias con el POC de Docker Compose:**

| | POC (`docker-compose.ha.yml`) | Kubernetes |
|---|---|---|
| HA | 3 contenedores, 1 host → no es HA | 3 pods, 3 nodos (antiAffinity) |
| Unseal | manual, en cada nodo, tras cada restart | automático (Cloud KMS) |
| Storage | volúmenes de Docker | PVC por pod, retenidos |
| Acceso | `localhost:8200` | `https://vault.l-net.io` vía Kong |
| Backups | ninguno | CronJob → GCS cada 6h |
| Auth | root token a mano | ServiceAccounts de K8s + políticas |

---

## Paso 0 — Prerrequisitos

```bash
# Contexto del cluster
gcloud container clusters get-credentials lnet-privado \
  --zone us-central1-c --project l-net-469615

kubectl config current-context   # → gke_l-net-469615_us-central1-c_lnet-privado
```

Herramientas:

| Herramienta | Versión mínima | Por qué |
|---|---|---|
| `gcloud` | cualquiera reciente | + `gke-gcloud-auth-plugin` (obligatorio para GKE desde kubectl 1.26) |
| `kubectl` | **≥ 1.34** | El cluster corre **v1.35.x**. El desfase soportado es ±1 versión menor; con un cliente viejo, `wait`, `cp` y `exec` fallan de formas poco obvias justo en los pasos 5-6. Actualizar con `gcloud components update kubectl` |
| `helm` | 3.6+ | Solo para el render de verificación. Con helm < 3.10 hay que pasarle `--kube-version 1.31.0`: su versión de capabilities por defecto es menor que el `kubeVersion: >=1.30` del chart |
| `jq`, `python3` (o `yq`) | — | parsear salidas |

Permisos IAM necesarios sobre `l-net-469615`: `cloudkms.admin`, `iam.serviceAccountAdmin`,
`storage.admin`, `secretmanager.admin` (`roles/owner` los cubre todos).

APIs que deben estar habilitadas: `cloudkms`, `secretmanager`, `storage`,
`iamcredentials`, `artifactregistry`, `container`. En `l-net-469615` ya lo están,
así que el primer bloque de `setup-gcp.sh` no hará nada.

Acceso de escritura a `gitlab.com/lacnet/cloud-infra`.

---

## Paso 1 — Recursos de GCP

```bash
./k8s/gcp/setup-gcp.sh
# o, para ver primero qué haría:
DRY_RUN=1 ./k8s/gcp/setup-gcp.sh
```

Crea: key ring + key de KMS, GSA `openbao-kms`, bindings de Workload Identity
para las dos KSA (`openbao` y `openbao-snapshot`), y el bucket de snapshots con
versionado + lifecycle a 30 días.

Es idempotente. El equivalente en Terraform, por si más adelante se lleva a IaC,
está en [`k8s/gcp/terraform.tf.example`](../gcp/terraform.tf.example).

**Verificación:**

```bash
gcloud kms keys describe openbao-unseal-key \
  --keyring=openbao-unseal --location=global --project=l-net-469615

gcloud kms keys get-iam-policy openbao-unseal-key \
  --keyring=openbao-unseal --location=global --project=l-net-469615
# debe listar openbao-kms@... con roles/cloudkms.cryptoKeyEncrypterDecrypter
```

---

## Paso 2 — Construir y publicar la imagen

La imagen es la misma del POC (`Dockerfile` de la raíz): OpenBao con el binario
de `ethsign` en `/openbao/plugins/`.

**Por pipeline** (recomendado): push a `main` → el job `build` la publica.
Ver [`k8s/ci/gitlab-ci.example.yml`](../ci/gitlab-ci.example.yml).

**A mano**, la primera vez:

```bash
export TAG=$(git rev-parse --short HEAD)
export IMG=us-central1-docker.pkg.dev/l-net-469615/l-net-docker-repo/openbao-ethsign

gcloud auth configure-docker us-central1-docker.pkg.dev

# --platform linux/amd64 es obligatorio desde un Mac con Apple Silicon:
# los nodos del cluster son e2-standard-4 (amd64).
docker buildx build --platform linux/amd64 \
  --build-arg OPENBAO_VERSION=2.6.1 \
  -t "$IMG:$TAG" --push .

echo "TAG = $TAG"
```

> `OPENBAO_VERSION` se fija a `2.6.1` porque es el `appVersion` del chart 0.28.6.
> Dejarlo en `latest` hace que la imagen y los defaults del chart se
> desincronicen sin aviso.

---

## Paso 3 — Dar de alta la Application en cloud-infra

1. Editar `k8s/argocd/openbao-application.yaml`:
   - `server.image.tag`: poner el `$TAG` del paso 2 (reemplaza `REPLACE_ME`).
   - `extraObjects` → `openbao-ip-restriction` → `config.allow`: **poner los
     CIDRs reales**. Los comentados de ejemplo no sirven.

2. Copiarlo a cloud-infra y registrarlo:

```bash
cd /Users/edumar111/lnet/devops/cloud-infra

cp ~/lnet/pocs/openbao-lnet-storage/k8s/argocd/openbao-application.yaml \
   gitops-apps/argocd-applications/openbao.yaml

# Añadir `- openbao.yaml` a la lista `resources:` de
# gitops-apps/argocd-applications/kustomization.yaml
$EDITOR gitops-apps/argocd-applications/kustomization.yaml

git add -A && git commit -m "feat(openbao): despliegue de OpenBao HA en GKE" && git push
```

La Application `apps-root` la detecta en su próximo poll (~3 min) y la crea.
Para no esperar: sincronizar `apps-root` a mano desde https://ops-console.l-net.io.

---

## Paso 4 — Verificar el arranque (los pods NO van a estar Ready)

```bash
kubectl -n openbao get pods -w
```

Lo esperado:

```
NAME         READY   STATUS    RESTARTS   AGE
openbao-0    0/1     Running   0          40s
openbao-1    0/1     Running   0          30s
openbao-2    0/1     Running   0          20s
```

**`0/1 Ready` es correcto en este punto.** El readiness probe corre
`bao status`, que sale con código 2 mientras el cluster no está inicializado.
Es el mismo comportamiento que en el POC (ver el gotcha del `CLAUDE.md`).

Si algún pod queda **Pending**: el `podAntiAffinity` exige un nodo distinto por
pod y el node pool autoescala de 2 a 5. Esperá a que suba el tercer nodo:

```bash
kubectl get nodes
kubectl -n openbao describe pod openbao-2 | tail -20
```

Si algún pod está en **CrashLoopBackOff**, casi siempre es el seal de KMS:

```bash
kubectl -n openbao logs openbao-0 | tail -30
# "failed to encrypt with GCP CKMS: permission denied"
#   → falta el binding de IAM o la annotation de Workload Identity
```

---

## Paso 5 — ★ Inicializar y generar las llaves

**Este paso se ejecuta UNA SOLA VEZ en la vida del cluster.**

```bash
./k8s/scripts/init-openbao.sh
```

Por dentro hace:

```bash
kubectl -n openbao exec -i openbao-0 -- \
  bao operator init -recovery-shares=5 -recovery-threshold=3 -format=json
```

### Qué son estas llaves exactamente

Con `seal "gcpckms"` **no salen unseal keys de Shamir**. Salen **recovery keys**.
La diferencia es sustancial:

| | Unseal keys (Shamir, el POC) | Recovery keys (KMS, producción) |
|---|---|---|
| Desellan el vault | Sí — hay que aportarlas en cada arranque | **No** — de eso se encarga Cloud KMS |
| Para qué sirven | `bao operator unseal` | `bao operator generate-root`, `rekey-recovery-key` |
| Si las perdés | El vault no vuelve a abrir | Perdés el acceso administrativo, pero el vault sigue operando |
| Si perdés la KMS key | — | **El vault no vuelve a abrir jamás** |

El script guarda la salida en GCP Secret Manager (`openbao-prod-recovery`) antes
de mostrarla, y la imprime una única vez.

### Custodia — no saltearse esto

El JSON contiene 5 recovery keys y el `root_token`. Ver
[`unseal-keys.md`](unseal-keys.md) para el procedimiento completo. En corto:

- Repartir los 5 shares entre **5 custodios distintos** (gestor de contraseñas
  personal, no un canal compartido). Con 3 se reconstruye el acceso.
- La copia en Secret Manager es una red de seguridad, **no** la custodia: quien
  pueda leer ese secret tiene 3 de 3 shares.
- **Nunca** guardar esto en un archivo del repo. Y nunca llamarlo `.env` —
  Docker Compose lo autocarga y revienta con las líneas que llevan espacios
  (gotcha documentado en `CLAUDE.md`).

---

## Paso 6 — Verificar el auto-unseal (la prueba que importa)

Sin tocar nada, los tres pods deberían quedar `1/1 Ready`:

```bash
kubectl -n openbao get pods
# openbao-0   1/1   Running
# openbao-1   1/1   Running
# openbao-2   1/1   Running

export BAO_TOKEN=<root_token del paso 5>

kubectl -n openbao exec -i openbao-0 -- \
  env BAO_TOKEN=$BAO_TOKEN bao operator raft list-peers
```

```
Node        Address                        State       Voter
----        -------                        -----       -----
openbao-0   openbao-0.openbao-internal:8201  leader    true
openbao-1   openbao-1.openbao-internal:8201  follower  true
openbao-2   openbao-2.openbao-internal:8201  follower  true
```

Los nodos 1 y 2 se unieron solos por los `retry_join` del HCL y se desellaron
solos contra KMS. **En ningún momento se corre `bao operator unseal`.** Esa es
la diferencia práctica con el POC.

---

## Paso 7 — Registrar el plugin ethsign

```bash
BAO_TOKEN=$BAO_TOKEN ./k8s/scripts/register-plugin.sh
```

Calcula el sha256 del binario dentro del pod, lo registra en el catálogo y monta
el engine en `ethereum/`. Es idempotente y se ejecuta contra el nodo activo.

El registro vive en el storage de Raft → se replica a los tres nodos y sobrevive
a restarts.

> **Cuándo hay que repetirlo:** cada vez que cambie el *binario* del plugin
> (bump de `ETHSIGN_REF`). El sha256 registrado tiene que coincidir con el del
> archivo o OpenBao se niega a ejecutarlo.

---

## Paso 8 — DNS

Crear en Cloudflare, zona `l-net.io`:

| Tipo | Nombre | Contenido | Proxy |
|------|--------|-----------|-------|
| A | `vault` | `35.192.128.2` | **DNS only (nube gris)** |

> ⚠️ **`vault` es la excepción de la zona: va SIN proxy, a propósito.**
>
> Todo el resto de `l-net.io` está proxied — `stats`, `api-ppr`, `naas`, `auth`
> y compañía resuelven a `104.21.35.194` / `172.67.178.218`, IPs del edge de
> Cloudflare. Y el data plane de Kong **no** tiene `KONG_TRUSTED_IPS` ni
> `KONG_REAL_IP_HEADER` configurados, así que ve la IP de Cloudflare como IP de
> origen, nunca la del cliente.
>
> Con `vault` proxied, el `KongPlugin/openbao-ip-restriction` compararía CIDRs
> de oficina contra IPs de Cloudflare y **bloquearía a todo el mundo** (o, si se
> añadieran los rangos de Cloudflare al allowlist, dejaría pasar a todo internet
> aparentando que hay control — que es peor).
>
> Con **DNS only**, Kong ve la IP real y el allowlist funciona sin tocar nada
> compartido. El coste: se pierden el WAF de Cloudflare y el ocultamiento de la
> IP de origen — pero `35.192.128.2` ya es pública para las otras ~40 apps del
> cluster, así que no se revela nada nuevo.
>
> Las alternativas (configurar `real_ip` en Kong para todo el cluster, o mover
> el allowlist al WAF de Cloudflare) están evaluadas en
> [`kong-ingress.md`](kong-ingress.md) → "Punto de atención 1".

**Verificación:**

```bash
dig +short vault.l-net.io
# 35.192.128.2                     → correcto (DNS only)
# 104.21.x.x / 172.67.x.x          → está proxied: el allowlist NO funciona
```

---

## Paso 9 — Bootstrap de seguridad

```bash
BAO_TOKEN=$BAO_TOKEN ./k8s/scripts/bootstrap-auth.sh
```

Configura:

- **Audit device** en `/openbao/audit/audit.log` (PVC dedicado). Sin esto no hay
  rastro de quién pidió qué firma.
- **Autopilot de Raft** (`cleanup_dead_servers`, `min_quorum=3`). Va por API
  porque `storage "raft"` no acepta un bloque `autopilot` en el HCL.
- **Políticas**: `ethsign-signer` (crear cuentas y firmar; **exportar la llave
  privada está explícitamente denegado**), `snapshot`, `openbao-operator`.
- **Método de auth de Kubernetes** + roles `ethsign-signer` y `snapshot`. Los
  consumidores se autentican con el JWT de su ServiceAccount y reciben un token
  de 1h. Sin tokens estáticos.

Ajustar `SIGNER_NAMESPACES` a los namespaces que realmente vayan a firmar:

```bash
SIGNER_NAMESPACES=naas,ppr BAO_TOKEN=$BAO_TOKEN ./k8s/scripts/bootstrap-auth.sh
```

---

## Paso 10 — Snapshots

```bash
kubectl apply -f k8s/backup/snapshot-cronjob.yaml

# Forzar una corrida de prueba (no esperar 6h)
kubectl -n openbao create job --from=cronjob/openbao-snapshot snap-test
kubectl -n openbao logs -f job/snap-test
gcloud storage ls -r gs://lnet-openbao-snapshots/
```

---

## Paso 11 — Smoke test end-to-end

```bash
BAO_TOKEN=$BAO_TOKEN ./k8s/scripts/smoke-test.sh
```

Verifica quórum, **mata al líder para comprobar que vuelve desellado solo**,
el Ingress de Kong, y crea una cuenta + firma una transacción contra
`https://vault.l-net.io`.

Para no provocar el failover: `SKIP_FAILOVER=1`.

---

## Paso 12 — Revocar el root token

```bash
kubectl -n openbao exec -i $(kubectl -n openbao get pods \
    -l openbao-active=true -o jsonpath='{.items[0].metadata.name}') -- \
  env BAO_TOKEN=$BAO_TOKEN bao token revoke -self
```

A partir de acá nadie tiene un token de administrador vivo. Cuando haga falta se
regenera con 3 de las 5 recovery keys (`bao operator generate-root`).
Procedimiento en [`unseal-keys.md`](unseal-keys.md).

---

## Consumir el servicio

### Desde fuera del cluster

```bash
curl -s -X POST https://vault.l-net.io/v1/ethereum/accounts \
  -H "X-Vault-Token: $BAO_TOKEN" -H 'Content-Type: application/json' -d '{}'
```

La API es idéntica a la del POC — ver la tabla del `CLAUDE.md`. Solo cambia la
base URL: `https://vault.l-net.io/v1/ethereum`.

### Desde un pod del cluster (recomendado)

Sin token estático, autenticándose con su ServiceAccount:

```bash
JWT=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)

TOKEN=$(curl -s -X POST \
  --data "{\"role\":\"ethsign-signer\",\"jwt\":\"$JWT\"}" \
  http://openbao-active.openbao.svc.cluster.local:8200/v1/auth/kubernetes/login \
  | jq -r .auth.client_token)

curl -s -X POST \
  -H "X-Vault-Token: $TOKEN" \
  http://openbao-active.openbao.svc.cluster.local:8200/v1/ethereum/accounts -d '{}'
```

Usar siempre `openbao-active` (apunta al líder), no `openbao`.

---

## Checklist final

- [ ] 3 pods `1/1 Running` en nodos distintos
- [ ] `raft list-peers` muestra 3 votantes y 1 líder
- [ ] Matar el líder → vuelve `Ready` **sin unseal manual**
- [ ] `https://vault.l-net.io/v1/sys/health` → 200
- [ ] Una IP fuera del allowlist recibe 403
- [ ] Firma end-to-end OK
- [ ] Recovery keys repartidas entre 5 custodios + copia en Secret Manager
- [ ] Root token revocado
- [ ] Snapshot de prueba visible en GCS
- [ ] Target `openbao` UP en Prometheus

---

## Ver también

- [`unseal-keys.md`](unseal-keys.md) — llaves: generación, custodia, rotación,
  y el camino Shamir como alternativa.
- [`kong-ingress.md`](kong-ingress.md) — el Ingress en detalle y sus trampas.
- [`operations.md`](operations.md) — runbook: failover, restore, upgrades, escalado.
- [`../../docs/storage.md`](../../docs/storage.md) — por qué Raft y no PostgreSQL.
- [`../../docs/throughput.md`](../../docs/throughput.md) — **HA ≠ throughput**, y el
  cuello de botella real (nonces).
