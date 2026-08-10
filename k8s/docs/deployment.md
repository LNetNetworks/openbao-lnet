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
   │  Ingress class kong + KongPlugin rate-limiting
   │  (el allowlist de IPs vive en Cloudflare, no en Kong — ver paso 8)
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
# debe listar openbao-kms@... con DOS roles:
#   roles/cloudkms.cryptoKeyEncrypterDecrypter  (cifrar/descifrar la root key)
#   roles/cloudkms.viewer                       (leer metadatos de la llave)
```

⚠️ **Los dos roles son obligatorios.** `cryptoKeyEncrypterDecrypter` NO incluye
`cloudkms.cryptoKeys.get`, y el seal `gcpckms` verifica que la llave exista
*antes* de cifrar nada. Con solo el primer rol los pods arrancan y mueren en
bucle (`CrashLoopBackOff`, 0/1) con:

```
Error configuring seal "gcpckms": error checking key existence:
rpc error: code = PermissionDenied desc = Permission 'cloudkms.cryptoKeys.get' denied
```

El binding de `viewer` va **sobre el recurso de la llave**, no sobre el keyring
ni el proyecto: da lectura de metadatos de esa llave y nada más.

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
     Es el **único** valor que hay que tocar.

   > No busques un `KongPlugin/openbao-ip-restriction` que rellenar: **no
   > existe a propósito**. Kong no ve la IP del cliente en este cluster (SNAT
   > de kube-proxy), así que un allowlist de CIDRs bloquearía a todo el mundo.
   > En el Application queda un bloque comentado explicando por qué; el
   > allowlist real se configura en Cloudflare en el paso 8. Detalle completo
   > en [`edge-client-ip.md`](edge-client-ip.md).

2. Copiarlo a cloud-infra y registrarlo:

```bash
cd /Users/edumar111/lnet/devops/cloud-infra

cp ~/lnet/pocs/openbao-lnet-storage/k8s/argocd/openbao-application.yaml \
   gitops-apps/argocd-applications/openbao.yaml

# Añadir `- openbao.yaml` a la lista `resources:` de
# gitops-apps/argocd-applications/kustomization.yaml
$EDITOR gitops-apps/argocd-applications/kustomization.yaml

git add gitops-apps/argocd-applications/openbao.yaml \
        gitops-apps/argocd-applications/kustomization.yaml
git commit -m "feat(openbao): despliegue de OpenBao HA en GKE" && git push
```

> ⚠️ **Estaquear por fichero, nunca `git add -A`.** El paso 5 deja
> `seal.json` con las recovery keys y el root token **en claro** en el repo del
> POC. Ya está en `.gitignore`, pero el hábito de `-A` es el que un día lo
> sube. Ver el aviso del paso 5.

### Cómo llega el cambio al cluster (importa para diagnosticar)

La cadena tiene tres eslabones y confundirlos hace perder tiempo:

```
git (cloud-infra)
  └─ apps-root ............ app-of-apps, mira gitops-apps/argocd-applications/
       └─ Application/openbao ... mira el repo Helm de OpenBao
            └─ chart 0.28.6 → StatefulSet + ConfigMap
```

- Un cambio en `openbao.yaml` lo aplica **`apps-root`**, no la Application de
  openbao. Si `apps-root` está `OutOfSync`, tu cambio no ha llegado, por muy
  `Synced` que se vea `openbao`.
- **`Application/openbao` dice `Synced` con `revision: 0.28.6`**: esa revisión
  es la **versión del chart**, no un commit de git. Un "Synced" ahí no dice nada
  sobre si tu edición del YAML llegó.

```bash
# ESTE es el que hay que mirar:
kubectl -n argocd get application apps-root \
  -o jsonpath='{.status.sync.status} {.status.sync.revision}{"\n"}'
```

`apps-root` tiene `automated: {selfHeal: true}` y sincroniza solo, pero el poll
puede tardar varios minutos. Para no esperar, sincronizarlo a mano desde
https://ops-console.l-net.io — **mirando antes qué otras Applications arrastra**,
porque sincroniza todo el directorio, no solo openbao.

---

## Paso 4 — Verificar el arranque (los pods NO van a estar Ready)

```bash
kubectl -n openbao get pods -w
```

Lo esperado:

```
NAME         READY   STATUS    RESTARTS   AGE
openbao-0    0/1     Running   0          40s
```

**Un solo pod, y `0/1 Ready`. Las dos cosas son correctas en este punto.**

- **`0/1`**: el readiness probe corre `bao status`, que sale con código 2
  mientras el cluster no está inicializado. Mismo comportamiento que en el POC
  (ver el gotcha del `CLAUDE.md`).
- **Un solo pod**: el StatefulSet usa `podManagementPolicy: OrderedReady`, así
  que Kubernetes **no crea `openbao-1` hasta que `openbao-0` esté Ready** — y
  eso no pasa hasta el `operator init` del Paso 5. No es un fallo de scheduling
  ni de anti-affinity; `kubectl -n openbao get sts openbao` va a mostrar
  `READY 0/3`.

La secuencia se destraba sola con el init: `openbao-0` queda Ready → nace
`openbao-1`, hace `retry_join` contra el líder y se desella con KMS → Ready →
nace `openbao-2`. Por eso `init-openbao.sh` espera a los 3 pods **después** de
inicializar, no antes. Los 3 `Running` juntos recién se ven al terminar el
Paso 5.

Si algún pod queda **Pending**: el `podAntiAffinity` exige un nodo distinto por
pod y el node pool autoescala de 2 a 5. Esperá a que suba el tercer nodo:

```bash
kubectl get nodes
kubectl -n openbao describe pod openbao-2 | tail -20
```

Si algún pod está en **CrashLoopBackOff**, casi siempre es el seal de KMS:

```bash
kubectl -n openbao logs openbao-0 | tail -30
```

Los dos mensajes que salen en la práctica:

```
Error configuring seal "gcpckms": error checking key existence:
  PermissionDenied: Permission 'cloudkms.cryptoKeys.get' denied
```
→ al GSA le falta **`roles/cloudkms.viewer`** sobre la key. Es el fallo del
paso 1: `cryptoKeyEncrypterDecrypter` **no** incluye `cloudkms.cryptoKeys.get`,
y el seal comprueba que la key exista *antes* de cifrar. Hacen falta los dos
roles.

```
failed to encrypt with GCP CKMS: permission denied
```
→ falta `cryptoKeyEncrypterDecrypter`, o la annotation de Workload Identity del
KSA no coincide con el GSA.

### Si el pod se reinicia solo cada ~3 minutos

Distinto de un CrashLoopBackOff: el pod queda `Running` pero el contador de
`RESTARTS` sube, y en los eventos aparece
`Container openbao failed liveness probe, will be restarted`.

Es el liveness probe matando un proceso sano. `/v1/sys/health` responde **501
sin inicializar** y **503 sellado**; si el path del probe no los mapea a un
código no-error, el kubelet lo lee como proceso colgado y reinicia — en bucle, y
justo en la ventana en la que hay que correr el `operator init`. El Application
lleva los parámetros que lo evitan:

```
/v1/sys/health?standbyok=true&uninitcode=204&sealedcode=204
```

Comprobar cuál está vivo, y que sea el path largo:

```bash
kubectl -n openbao get sts openbao \
  -o jsonpath='{.spec.template.spec.containers[0].livenessProbe.httpGet.path}{"\n"}'
```

### Si el StatefulSet no toma una plantilla nueva

Con `RollingUpdate`, el controlador **no reemplaza un pod que no está Ready**. Y
antes del init ningún pod llega a Ready. Resultado: cualquier cambio de la
plantilla del STS aplicado antes del paso 5 **se queda atascado** — ArgoCD dice
`Synced`, el STS tiene la revisión nueva, y el pod sigue con la vieja:

```bash
kubectl -n openbao get sts openbao \
  -o jsonpath='current: {.status.currentRevision}{"\n"}update:  {.status.updateRevision}{"\n"}'
# si difieren y updatedReplicas está vacío, está atascado
```

Se desbloquea borrando el pod a mano — inocuo mientras el vault no esté
inicializado, porque no hay datos que perder:

```bash
kubectl -n openbao delete pod openbao-0
```

Después del paso 5 esto deja de pasar: los pods alcanzan Ready y el rollout
avanza solo.

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

> ⚠️ **`seal.json` queda en el working tree.** El script deja la salida del init
> en `seal.json` (y en `k8s/secrets-seal/seal.json`): **5 recovery keys y el
> root token en texto plano**. Ambas rutas están en `.gitignore`, pero un
> `git add -A` distraído las subiría igual — por eso el paso 3 insiste en
> estaquear por fichero.
>
> En cuanto verifiques que Secret Manager tiene el material, **borralas**:
>
> ```bash
> gcloud secrets versions access 1 \
>   --secret=openbao-prod-recovery --project=l-net-469615 | head -c 80
>
> rm -f seal.json k8s/secrets-seal/seal.json
> ```
>
> No las borres antes de comprobarlo: si la copia de Secret Manager estuviera
> incompleta, serían el único ejemplar de un material irrecuperable.

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
| A | `vault` | `35.192.128.2` | **Proxied (nube naranja)**, como el resto de la zona |

Y, en la misma zona de Cloudflare, **el allowlist por IP**:

- **IP Access Rules** con scope `vault.l-net.io`, o
- una **WAF Custom Rule**:
  `(http.host eq "vault.l-net.io" and not ip.src in {<IPs autorizadas>})` → Block

> **Por qué el allowlist va en Cloudflare y no en Kong.** Kong **no puede ver la
> IP del cliente** en este cluster: el Service `gateway-kong-proxy` tiene
> `externalTrafficPolicy: Cluster`, así que kube-proxy hace SNAT antes de que el
> paquete llegue a Kong. Medido: una petición desde `179.6.6.187` le llega a
> Kong como `10.3.207.227` (IP de nodo). Cambiar el DNS a *DNS only* **no lo
> arregla** — la IP se pierde en la capa L4 de Kubernetes, no en Cloudflare.
>
> En el edge de Cloudflare, en cambio, la IP del cliente es el peer TCP: el
> filtro funciona por construcción, y de paso se suman el WAF y la mitigación
> de DDoS.
>
> Por eso el `KongPlugin/openbao-ip-restriction` está deshabilitado en el
> Application. El análisis completo, con las opciones para arreglarlo en Kong y
> su coste, está en [`edge-client-ip.md`](edge-client-ip.md) — **léelo antes de
> proponer cambios en el data plane de Kong**.

**Verificación:**

```bash
dig +short vault.l-net.io
# 104.21.x.x / 172.67.x.x → proxied, correcto
# 35.192.128.2            → el registro NO está proxied: Cloudflare no está en
#                           el camino y el allowlist no se aplica

# Desde una IP NO autorizada (pedírselo a alguien de fuera):
curl -s -o /dev/null -w '%{http_code}\n' https://vault.l-net.io/v1/sys/health
# 403 (bloqueo de Cloudflare) → el allowlist funciona
```

> **Si creaste el registro y `dig` sigue sin resolver, no lo toques.** Lo más
> probable es que tu resolver haya cacheado el `NXDOMAIN` de cuando consultaste
> *antes* de crearlo. La zona declara **1800s (30 min)** de caché negativa en el
> campo `minimum` del SOA.
>
> ```bash
> dig vault.l-net.io | grep -E "status:|SOA"
> # status: NXDOMAIN  +  l-net.io. 920 IN SOA ... 604800 1800
> #                                  ^^^ segundos que le quedan  ^^^^ TTL negativo
>
> dig +short @1.1.1.1 vault.l-net.io   # ¿resuelve por fuera de tu resolver?
> ```
>
> Si contra `1.1.1.1` resuelve y contra el tuyo no, es caché: esperá, o saltátela
> con `networksetup -setdnsservers Wi-Fi 1.1.1.1 1.0.0.1` (revertir con
> `... Wi-Fi empty`).

> ⚠️ **En macOS hay DOS cachés, y `dig` solo te muestra una.** Cuando expire la
> caché del resolver vas a ver esto:
>
> ```
> dig +short vault.l-net.io        → 104.21.35.194   ✓
> curl https://vault.l-net.io/...  → 000             ✗ (instantáneo, 0.001s)
> ```
>
> No es contradictorio: `dig` habla directo con el servidor DNS, mientras que
> **curl, el navegador y el resto del sistema** usan `getaddrinfo`, que pasa por
> el caché de `mDNSResponder`. Ese guarda el NXDOMAIN por su cuenta y no expira
> a la vez.
>
> ```bash
> # ¿cuál de las dos está fallando?
> dscacheutil -q host -a name vault.l-net.io   # vacío = es el caché del sistema
>
> sudo dscacheutil -flushcache
> sudo killall -HUP mDNSResponder
> ```
>
> **Consecuencia para el paso 11:** el smoke test comprueba el DNS con `dig` y
> el HTTP con curl. En este estado te dará el DNS en ✓ y el HTTP en `000` — que
> parece un problema del Ingress o de Cloudflare, y no lo es.

> ⚠️ **Hueco conocido:** quien conozca `35.192.128.2` puede saltarse Cloudflare
> pegándole directo al LB con `Host: vault.l-net.io`. La IP es pública (la
> comparten los ~40 dominios del cluster). Mientras no se resuelva, el control
> real ante ese vector es el token de OpenBao. Formas de cerrarlo en
> [`edge-client-ip.md`](edge-client-ip.md) §4.

---

## Paso 9 — Bootstrap de seguridad

```bash
BAO_TOKEN=$BAO_TOKEN ./k8s/scripts/bootstrap-auth.sh
```

Configura:

- **Audit device**: lo **verifica**, no lo crea. Desde OpenBao 2.3.2 no se puede
  habilitar por API; se declara en el HCL (ver el recuadro de abajo). Si no hay
  device activo el script **aborta antes de tocar auth**: configurar el acceso
  de los firmantes sin rastro de auditoría sería peor que fallar.
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

### El audit device es declarativo (OpenBao ≥ 2.3.2)

`bao audit enable` falla con:

```
cannot enable audit device via API; use declarative, config-based
audit device management instead
```

No es un error de configuración: es un endurecimiento deliberado. Un audit
device de tipo `file` escribe en **rutas arbitrarias** (y el de `socket`, a
sockets arbitrarios), así que un token admin filtrado permitiría exfiltrar
secretos. Existe `unsafe_allow_api_audit_creation = true` para revertirlo —
**no lo usamos**: el nombre del flag es la advertencia, y esto custodia llaves
privadas.

El device va declarado en el HCL del Application:

```hcl
audit "file" "file" {
  description = "Audit log en el PVC audit-openbao-N"
  options = {
    file_path = "/openbao/audit/audit.log"
  }
}
```

El **segundo label es el nombre del mount** → aparece como `file/` en
`bao audit list`.

Verificación sin necesidad de token:

```bash
kubectl -n openbao logs openbao-0 | grep "audit backend"
# {"@message":"enabled audit backend","path":"file/","type":"file"}

kubectl -n openbao exec openbao-0 -- ls -l /openbao/audit/audit.log
# -rw------- ... audit.log   (crece con cada petición)
```

> **OJO:** si el audit device no puede escribir, OpenBao **deja de responder** a
> propósito — prefiere caerse antes que operar sin auditoría. Antes de tocar
> nada del device, comprobar espacio: `kubectl -n openbao exec openbao-0 -- df -h
> /openbao/audit`. Hay alerta sugerida en [`operations.md`](operations.md).

---

## ★ Cambiar el HCL exige reiniciar los pods

Vale para el audit device y para **cualquier** edición del bloque `config` del
Application. Es el gotcha que más tiempo hace perder:

```sh
# PID 1 del contenedor, puesto por el chart:
cp /openbao/config/extraconfig-from-values.hcl /tmp/storageconfig.hcl
sed -Ei "s|HOST_IP|${HOST_IP}|g" /tmp/storageconfig.hcl   # y POD_IP, HOSTNAME…
bao server -config=/tmp/storageconfig.hcl
```

El entrypoint **copia** la config a `/tmp/storageconfig.hcl` al arrancar, para
sustituir las variables, y el servidor lee **esa copia**. Por lo tanto:

- Que ArgoCD actualice la ConfigMap **no basta**.
- Que el kubelet propague el fichero montado **tampoco**: el proceso no lo lee.
- Un **`SIGHUP` no sirve** — relee `/tmp/storageconfig.hcl`, que sigue siendo la
  copia vieja del arranque.

La única vía es reiniciar los pods, para que el entrypoint rehaga la copia:

```bash
kubectl -n openbao rollout restart sts/openbao
kubectl -n openbao rollout status  sts/openbao --timeout=600s

# comprobar que el cambio llegó al fichero que el proceso REALMENTE lee:
kubectl -n openbao exec openbao-0 -- grep -c 'audit "file"' /tmp/storageconfig.hcl
```

El rollout va en orden inverso (`openbao-2` → `-1` → `-0`), esperando Ready
entre cada uno, y cada pod **se desella solo con KMS**. Como el líder suele ser
`openbao-0`, cae el último: hay una elección de líder al final y el Service
`openbao-active` sigue la label sin intervención. No hace falta desellar nada a
mano.

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

**Interpretar los fallos.** Los pasos 3 y 5 pegan contra `https://vault.l-net.io`,
así que **un problema de DNS se manifiesta como tres fallos distintos**:

```
[3/5] vault.l-net.io → <sin resolver>
      ✗ DNS no resuelve
      ✗ GET /v1/sys/health → 000000
[5/5] ✗ no se pudo crear la cuenta:
Fallos: 3
```

`000000` es curl diciendo "no pude resolver el host", no un error HTTP. Una
causa, tres síntomas: arreglá el DNS (paso 8, ojo con la caché negativa) y los
tres se van juntos. Los pasos 1, 2 y 4 no dependen del DNS — si esos pasan, el
cluster está sano y lo que falla es el camino desde tu máquina.

**Variante que despista:** el DNS en ✓ pero el HTTP en `000`. El chequeo de DNS
usa `dig` y el de HTTP usa curl, que resuelven por caminos distintos — es el
caché de `mDNSResponder` de macOS. Está explicado en el paso 8; se arregla con
`sudo killall -HUP mDNSResponder`.

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
- [ ] Audit device activo: `logs | grep "audit backend"` y `audit.log` creciendo
- [ ] `https://vault.l-net.io/v1/sys/health` → 200
- [ ] `dig +short vault.l-net.io` → IPs de Cloudflare, **no** `35.192.128.2`
- [ ] Una IP fuera del allowlist recibe 403
- [ ] Firma end-to-end OK
- [ ] Recovery keys repartidas entre 5 custodios + copia en Secret Manager
- [ ] **`seal.json` y `k8s/secrets-seal/` borrados** del working tree
- [ ] Root token revocado
- [ ] Snapshot de prueba visible en GCS
- [ ] Target `openbao` UP en Prometheus

---

## Ver también

- [`unseal-keys.md`](unseal-keys.md) — llaves: generación, custodia, rotación,
  y el camino Shamir como alternativa.
- [`kong-ingress.md`](kong-ingress.md) — el Ingress en detalle y sus trampas.
- [`edge-client-ip.md`](edge-client-ip.md) — por qué Kong no ve la IP del
  cliente, por qué este despliegue necesita un allowlist, y las opciones para
  arreglarlo en el edge.
- [`operations.md`](operations.md) — runbook: failover, restore, upgrades, escalado.
- [`../../docs/storage.md`](../../docs/storage.md) — por qué Raft y no PostgreSQL.
- [`../../docs/throughput.md`](../../docs/throughput.md) — **HA ≠ throughput**, y el
  cuello de botella real (nonces).
