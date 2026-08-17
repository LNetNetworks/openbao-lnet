# Redespliegue limpio — reemplazar el cluster actual por uno nuevo

> **Cuándo se usa esto:** el despliegue actual **todavía no está en uso**. No hay
> llaves privadas que importe conservar, así que en vez de actualizar el plugin
> in-place ([`plugin-update.md`](plugin-update.md)) se tira todo y se levanta de
> cero: imagen que **ya trae `sign-digest`**, **KMS key de sellado nueva**,
> `operator init` nuevo, recovery keys nuevas y root token nuevo.
>
> Es el camino más simple y el que deja el sistema en el estado más limpio:
> **desaparece la ventana del `sha256`** (el binario se registra por primera vez,
> no se re-registra) y **desaparece el `generate-root`** (el init entrega un root
> token fresco).

---

## 0. La única pregunta que hay que contestar antes

**¿Hay una sola address de este vault que valga algo?** Si la respuesta es sí, no
sigas: este procedimiento **borra todas las llaves privadas y son
irrecuperables** — no hay backup que las traiga de vuelta, porque el snapshot
viejo queda cifrado con una root key que se descarta.

"Valer algo" incluye, y no es solo saldo:

- una address con fondos, aunque sean de testnet que costó conseguir;
- una address registrada como *issuer* de VCs, en un DID, en un contrato, en una
  allowlist o en la configuración de cualquier consumidor;
- cualquier cuenta que algún cliente tenga hardcodeada.

Verificación objetiva antes de empezar (con un token administrativo):

```bash
export POD=$(kubectl -n openbao get pods -l openbao-active=true -o jsonpath='{.items[0].metadata.name}')
kubectl -n openbao exec -i $POD -- env BAO_TOKEN=$BAO_TOKEN bao list ethereum/accounts
```

Si lo que sale son las cuentas que creó `smoke-test.sh`, adelante. Si no
reconocés alguna, averiguá de quién es antes de borrar.

> Si aparece **una sola** cuenta que no se pueda perder: cerrá esta guía y usá
> [`plugin-update.md`](plugin-update.md), que actualiza el plugin conservando el
> estado.

---

## 1. Qué se destruye y qué sobrevive

| Recurso | Qué pasa en el redespliegue |
|---|---|
| **Root key + todas las cuentas de `ethereum/`** | **Se pierden.** Es el objetivo del procedimiento. |
| **PVCs `data-openbao-{0,1,2}` y `audit-openbao-{0,1,2}`** | **Hay que borrarlos a mano.** El Application tiene `persistentVolumeClaimRetentionPolicy: Retain` — sobreviven a que se borre el StatefulSet. Ver [§4 paso 2](#paso-2--borrar-el-estado-los-pvcs-no-se-van-solos). |
| **KMS key `openbao-unseal-key`** | **No se puede borrar** (GCP no permite borrar keys ni key rings). Se crea una key **nueva** y la vieja queda deshabilitada. Ver [§2](#2-la-key-de-sellado-nueva). |
| **Recovery keys + root token actuales** | Quedan obsoletos: no abren el vault nuevo. Hay que retirarlos de la custodia y del Secret Manager. |
| **Secret `openbao-prod-recovery`** | `init-openbao.sh` le agrega una **versión nueva**. La versión vieja sigue ahí y es material muerto — destruirla. Ver [§4 paso 4](#paso-4--secret-manager-que-no-queden-dos-materiales-vivos). |
| **Snapshots en `gs://lnet-openbao-snapshots`** | Pertenecen al linaje viejo y **no se pueden restaurar** en el cluster nuevo (otra root key, otra KMS key). Borrarlos o archivarlos para no restaurar por error. |
| **CronJob de snapshots + KSA `openbao-snapshot`** | No lo gestiona ArgoCD (se aplica con `kubectl apply`): si se borra el namespace, hay que volver a aplicarlo. |
| **GSA `openbao-kms`, bindings de Workload Identity, bucket GCS** | **Sobreviven.** No hay que rehacerlos (salvo darle permisos a la key nueva, que hace `setup-gcp.sh`). |
| **Ingress de Kong, DNS de Cloudflare, allowlist, certificado** | **Sobreviven.** Misma URL `https://vault.l-net.io`, misma IP del LB. No se toca nada del edge. |
| **Políticas, roles de auth de K8s, audit device** | Se recrean con `bootstrap-auth.sh` y el HCL del Application. |

---

## 2. La key de sellado nueva

Lo que más confunde de este paso: **en GCP no se puede borrar una crypto key ni
un key ring.** Solo se pueden *deshabilitar* o *destruir versiones*. Así que
"generar una llave de sellado nueva" significa **crear otra crypto key** y
apuntar el HCL a ella.

Recomendado: **la misma key ring, key nueva `openbao-unseal-key-v2`**. El key
ring ya tiene los permisos y la estructura; el sufijo deja explícito el linaje.

```bash
KMS_KEY=openbao-unseal-key-v2 ./k8s/gcp/setup-gcp.sh
```

`setup-gcp.sh` es idempotente y acepta `KMS_KEY` por entorno: crea la key nueva
con rotación a 90 días y le agrega al GSA **los dos roles obligatorios**
(`cryptoKeyEncrypterDecrypter` **y** `viewer` — sin el segundo los pods entran en
`CrashLoopBackOff` con `error checking key existence: PermissionDenied`). El
resto de recursos ya existen y los saltea.

**Verificación:**

```bash
gcloud kms keys get-iam-policy openbao-unseal-key-v2 \
  --keyring=openbao-unseal --location=global --project=l-net-469615
# debe listar openbao-kms@... con los DOS roles
```

Y en el Application:

```hcl
seal "gcpckms" {
  project    = "l-net-469615"
  region     = "global"
  key_ring   = "openbao-unseal"
  crypto_key = "openbao-unseal-key-v2"     # ← el cambio
}
```

> **La key vieja se deshabilita al final, no ahora** ([§5](#5-limpieza-posterior)).
> Mientras exista, los snapshots viejos siguen siendo técnicamente restaurables:
> es la única red de seguridad si a mitad del procedimiento aparece algo que sí
> había que conservar. Destruir sus versiones es irreversible.
>
> Si en algún momento esto se lleva a Terraform: `k8s/gcp/terraform.tf.example`
> declara la key con `prevent_destroy = true`. La key nueva es un **recurso
> nuevo** en el archivo; la vieja se queda declarada, deshabilitada.

---

## 3. Antes de empezar: la imagen

El redespliegue solo tiene sentido si la imagen que se va a levantar **ya trae el
endpoint `sign-digest`**. El fork del plugin, los build args y la validación local
están en [`plugin-update.md`](plugin-update.md) §1-§2 — hay que hacer **todo eso
igual**, incluida la decisión sobre la variante del endpoint y el `go test`.

Lo que **no** hay que hacer de esa guía es el §4 (rollout + re-registro del
`sha256`): acá el plugin se registra por primera vez, con `register-plugin.sh`, en
el paso normal del despliegue.

```bash
export TAG=$(git rev-parse --short HEAD)
export IMG=us-central1-docker.pkg.dev/l-net-469615/l-net-docker-repo/openbao-ethsign

# El fork y su commit ya son el default del Dockerfile (ETHSIGN_REPO/ETHSIGN_REF).
docker buildx build --platform linux/amd64 \
  --build-arg OPENBAO_VERSION=2.6.1 \
  -t "$IMG:$TAG" --push .

# comprobación barata de que el endpoint está en el binario
docker run --rm --entrypoint sh "$IMG:$TAG" -c 'grep -c "sign-digest" /openbao/plugins/ethsign'
```

---

## 4. Procedimiento

### Paso 0 — Congelar lo que corre solo

```bash
# El CronJob de snapshots seguiría intentando (y fallando) durante el proceso.
kubectl -n openbao patch cronjob openbao-snapshot -p '{"spec":{"suspend":true}}'
```

No lo gestiona ArgoCD, así que este patch no se revierte solo.

### Paso 1 — Bajar la Application (por git, es el único camino confiable)

**No alcanza con `kubectl delete`.** La Application `openbao` tiene
`automated: {selfHeal: true, prune: true}`, y **`apps-root` —que también tiene
selfHeal— la recrea** si la borrás del cluster. Lo mismo pasa con cualquier
parche local: bajar réplicas, quitar el `syncPolicy`, borrar el StatefulSet. Todo
vuelve en el próximo poll.

El camino es sacarla del repo:

```bash
cd /Users/edumar111/lnet/devops/cloud-infra

# Quitar la línea `- openbao.yaml` de la lista `resources:`
# (dejar el archivo openbao.yaml en su lugar: se vuelve a agregar en el paso 6)
$EDITOR gitops-apps/argocd-applications/kustomization.yaml

git add gitops-apps/argocd-applications/kustomization.yaml
git commit -m "chore(openbao): baja temporal para redespliegue limpio" && git push
```

⚠️ **Sacarla de git no la borra sola.** `apps-root` está declarado con
`prune: false` (`gitops-apps/argocd-applications/root-apps.yaml`), así que quitar
la línea del `kustomization.yaml` deja a `apps-root` `OutOfSync` con un recurso
"de más" y la Application `openbao` **sigue viva**. El commit es igual
imprescindible: es lo que le quita el estado deseado, para que `selfHeal` no la
recree cuando la borres.

Con el commit ya pusheado, borrala a mano — el finalizer
(`resources-finalizer.argocd.argoproj.io`) borra en cascada StatefulSet,
Services, Ingress, ServiceMonitor, KongPlugin, PDB y RBAC:

```bash
kubectl -n argocd delete application openbao     # bloquea hasta que el finalizer termina
kubectl -n argocd get application openbao        # → NotFound
kubectl -n openbao get sts,svc,ingress           # → vacío
```

**No sincronices `apps-root` a mano** para forzar esto: sincroniza *todo* el
directorio y arrastra cualquier otra Application que esté `OutOfSync` en ese
momento (al 2026-08-17 eran `db-backups`, `dev-keycloak` y `edge-system`). Con
`prune: false` tampoco serviría de nada.

> Si algún día `root-apps.yaml` pasa a `prune: true`, el `kubectl delete` deja de
> ser necesario: el push solo alcanza. Verificalo antes de asumirlo:
> `kubectl -n argocd get application apps-root -o jsonpath='{.spec.syncPolicy.automated}'`

### ⚠️ La trampa del `kubectl delete namespace openbao`

Esto no es específico del redespliegue: aplica a **cualquier** borrado del
namespace, incluido el de un re-init. Vale leerlo antes.

**Si ArgoCD tiene una sync en curso cuando borrás el namespace, el despliegue
queda muerto y no se recupera solo.** Pasó el 2026-08-17: una sync de `selfHeal`
—disparada por drift en `RoleBinding/openbao-discovery-rolebinding`— estaba
corriendo, alcanzó a re-aplicar el Namespace mientras estaba en `Terminating`
(`"Detected changes to resource openbao which is currently being deleted"`), y la
operación quedó colgada esperando para siempre a un namespace que ya no existía:

```
opPhase   = Running
opMessage = waiting for healthy state of /Namespace/openbao
```

Y lo que lo vuelve irrecuperable es esto, en los logs del
`argocd-application-controller`:

```
Skipping auto-sync: failed previous sync attempt to [0.28.6]
and will not retry for [0.28.6]
```

**ArgoCD no reintenta el auto-sync para la misma revisión.** Esta Application no
apunta a un commit de git sino a `targetRevision: 0.28.6` —la versión del chart de
Helm—, así que **la revisión nunca cambia** y el auto-sync queda bloqueado
indefinidamente. Esperar no sirve de nada.

**Síntoma:** `kubectl -n openbao get pods -w` no muestra nada y no da error
(porque el namespace no existe), `Application/openbao` en `OutOfSync` /
`health: Missing`, y `reconciledAt` avanzando sin que pase nada.

**Diagnóstico:**

```bash
kubectl -n argocd get application openbao \
  -o jsonpath='{.status.operationState.phase} {.status.operationState.message}{"\n"}'
kubectl -n argocd logs argocd-application-controller-0 --since=6m | grep -i openbao
```

**Destrabe** (no hay `argocd` CLI en el entorno, así que va por `kubectl`):

```bash
# 1. Cancelar la operación colgada
kubectl -n argocd patch application openbao --type=json \
  -p '[{"op":"remove","path":"/operation"}]'
kubectl -n argocd patch application openbao --type merge \
  -p '{"status":{"operationState":{"phase":"Terminating"}}}'

# 2. Esperar a que quede en Failed ("Operation terminated"), y disparar una sync
#    MANUAL — es lo que resetea la guarda del "will not retry"
kubectl -n argocd patch application openbao --type merge -p '{
  "operation": {"initiatedBy": {"username": "manual-unblock"},
    "sync": {"revision": "0.28.6", "prune": true,
             "syncOptions": ["CreateNamespace=true", "ServerSideApply=true"]}}}'
```

El paso 2 hay que hacerlo **después** de que la operación vieja quede en `Failed`:
si se dispara mientras todavía está terminando, el controller procesa la
terminación y descarta la sync nueva. Se nota porque el `phase` sigue mostrando
`Operation terminated` y el namespace no aparece — se vuelve a aplicar el patch y
listo.

**Para evitarlo:** antes de borrar el namespace, comprobá que no haya una
operación en vuelo:

```bash
kubectl -n argocd get application openbao \
  -o jsonpath='{.status.operationState.phase}{"\n"}'   # debe decir Succeeded
```

### Paso 2 — Borrar el estado (los PVCs **no** se van solos)

Este es **el paso que no se puede saltear**, y el que produce el fallo más
confuso si se olvida.

```bash
kubectl -n openbao get pvc
# data-openbao-0/1/2 y audit-openbao-0/1/2, en Bound
```

Lo más determinista es borrar el namespace entero (se lleva PVCs, KSA, secrets y
el CronJob de una vez; ArgoCD lo recrea con sus labels gracias a
`CreateNamespace=true` + `managedNamespaceMetadata`):

```bash
kubectl delete namespace openbao
kubectl get pv | grep openbao        # → nada, o Released momentáneamente
```

Si preferís conservar el namespace, borrá los PVCs uno por uno:

```bash
for i in 0 1 2; do
  kubectl -n openbao delete pvc data-openbao-$i audit-openbao-$i
done
kubectl -n openbao get pvc           # → No resources found
```

> **Qué pasa si te los olvidás.** El StatefulSet nuevo vuelve a montar los PVCs
> viejos, así que el vault arranca **ya inicializado** con los datos anteriores:
>
> - **Con la key de sellado nueva:** los pods no pueden descifrar la root key
>   vieja. Quedan `Running` pero sellados, con errores de descifrado en los logs,
>   y `init-openbao.sh` aborta con *"El cluster YA está inicializado"*. Parece un
>   problema de permisos de KMS y no lo es.
> - **Con la key vieja:** peor todavía — levanta el vault **anterior**, entero y
>   funcionando, y es fácil creer que el redespliegue salió bien cuando en
>   realidad no se reemplazó nada.
>
> En ambos casos el diagnóstico es el mismo: `bao status` dice
> `Initialized: true` *antes* de haber corrido el init.

La `storageClass standard-rwo` tiene `reclaimPolicy: Delete`, así que los PV
desaparecen detrás de los PVCs. Verificalo: un PV en `Released` que quede colgado
es disco que se sigue pagando.

### Paso 3 — Crear la key de sellado nueva

```bash
KMS_KEY=openbao-unseal-key-v2 ./k8s/gcp/setup-gcp.sh
```

Detalle y verificación en [§2](#2-la-key-de-sellado-nueva).

### Paso 4 — Secret Manager: que no queden dos materiales vivos

`init-openbao.sh` guarda la salida del init en `openbao-prod-recovery`. Como el
secret ya existe, **agrega una versión** en vez de crear uno nuevo: van a
convivir la versión vieja (muerta) y la nueva.

El riesgo es concreto: [`deployment.md`](deployment.md) documenta la verificación
como `gcloud secrets versions access 1`, que después del redespliegue devuelve el
material **viejo**. Usá siempre `latest`:

```bash
gcloud secrets versions access latest \
  --secret=openbao-prod-recovery --project=l-net-469615 | jq
```

Y en cuanto verifiques el cluster nuevo ([§5](#5-limpieza-posterior)), destruí la
versión vieja para que no quede material engañoso a mano.

> Alternativa igual de válida: `GSM_SECRET=openbao-prod-recovery-v2
> ./k8s/scripts/init-openbao.sh` y borrar el secret viejo después. Un secret por
> linaje se lee mejor; a cambio hay que actualizar las referencias de
> `unseal-keys.md` y `deployment.md`.

### Paso 5 — Actualizar el Application

En `k8s/argocd/openbao-application.yaml`, dos cambios:

```yaml
server:
  image:
    tag: "<TAG del paso §3>"          # imagen con sign-digest
```

```hcl
seal "gcpckms" {
  crypto_key = "openbao-unseal-key-v2"   # la key nueva
}
```

Nada más. Réplicas, storage, probes, Ingress, audit device y rate-limiting se
quedan como están.

### Paso 6 — Volver a dar de alta la Application

```bash
cd /Users/edumar111/lnet/devops/cloud-infra

cp ~/lnet/pocs/openbao-lnet-storage/k8s/argocd/openbao-application.yaml \
   gitops-apps/argocd-applications/openbao.yaml

# Volver a agregar `- openbao.yaml` a la lista `resources:`
$EDITOR gitops-apps/argocd-applications/kustomization.yaml

git add gitops-apps/argocd-applications/openbao.yaml \
        gitops-apps/argocd-applications/kustomization.yaml
git commit -m "feat(openbao): redespliegue limpio con sign-digest y key de sellado nueva" && git push
```

> ⚠️ Estaquear **por fichero**, nunca `git add -A`. El paso siguiente no escribe
> material sensible en el working tree (`init-openbao.sh` manda el init a Secret
> Manager por stdin), pero el hábito de `-A` en dos repos a la vez es el que
> termina subiendo algo que no va.

Y mirar `apps-root`, no `openbao` (su `revision: 0.28.6` es la versión del chart,
no un commit):

```bash
kubectl -n argocd get application apps-root \
  -o jsonpath='{.status.sync.status} {.status.sync.revision}{"\n"}'
```

### Paso 7 — De acá en adelante es un despliegue nuevo

Seguir [`deployment.md`](deployment.md) **desde el paso 4**, tal cual está. En
resumen:

```bash
kubectl -n openbao get pods -w        # 1 solo pod, 0/1 Ready: correcto (falta init)

./k8s/scripts/init-openbao.sh         # ★ recovery keys + root token NUEVOS
export BAO_TOKEN=<root_token>

./k8s/scripts/register-plugin.sh      # primer registro del binario con sign-digest
BAO_TOKEN=$BAO_TOKEN ./k8s/scripts/bootstrap-auth.sh
kubectl apply -f k8s/backup/snapshot-cronjob.yaml    # recrea KSA + CronJob (sin suspend)
BAO_TOKEN=$BAO_TOKEN ./k8s/scripts/smoke-test.sh
```

Diferencias respecto de la primera vez:

- **No hay ventana de `sha256`** ni `bao plugin reload`: el catálogo se escribe
  por primera vez, contra el binario que ya está en los pods.
- **No hay `generate-root`**: el init entrega un root token nuevo.
- **No se toca el DNS ni Cloudflare** (paso 8 de `deployment.md`): el Ingress
  vuelve con el mismo host y el mismo LB.
- **Custodia**: las recovery keys nuevas se reparten entre 5 custodios, igual que
  la primera vez, y las viejas se retiran ([`unseal-keys.md`](unseal-keys.md)).

Después, lo específico de `sign-digest`:

```bash
BAO_ADDR=https://vault.l-net.io BAO_TOKEN=$BAO_TOKEN \
  ./plan-digest/scripts/verify-sign-digest.sh
```

y las **políticas** — cuenta dedicada sin saldo, política `ethsign-credentials`,
rol de auth propio y `deny` cruzado en `ethsign-signer`:
[`plugin-update.md` §6](plugin-update.md#6-políticas-sin-esto-el-endpoint-queda-403).
Sin eso el endpoint existe pero devuelve 403.

Y al final: **revocar el root token**.

---

## 5. Limpieza posterior

Recién **después** de verificar que el cluster nuevo firma end-to-end:

```bash
# 1. Snapshot inicial del linaje nuevo
BAO_TOKEN=$BAO_TOKEN LABEL=post-redeploy ./k8s/scripts/snapshot.sh

# 2. Retirar los snapshots del linaje viejo (no se pueden restaurar acá, y
#    tenerlos a mano invita a un restore que rompería el cluster nuevo)
gcloud storage ls -r gs://lnet-openbao-snapshots/auto/
gcloud storage rm -r 'gs://lnet-openbao-snapshots/auto/**'     # o moverlos a old/

# 3. Destruir la versión muerta del secret de recovery
gcloud secrets versions list openbao-prod-recovery --project=l-net-469615
gcloud secrets versions destroy 1 --secret=openbao-prod-recovery --project=l-net-469615

# 4. Deshabilitar la key de sellado vieja (NO destruir sus versiones todavía)
gcloud kms keys versions list --key=openbao-unseal-key \
  --keyring=openbao-unseal --location=global --project=l-net-469615
gcloud kms keys versions disable 1 --key=openbao-unseal-key \
  --keyring=openbao-unseal --location=global --project=l-net-469615
```

- **Deshabilitar, no destruir.** Deshabilitar es reversible; destruir tiene 24h de
  gracia y después es definitivo. Dejá pasar unas semanas de operación normal
  antes de destruir versiones, y solo si ya borraste los snapshots viejos.
- **Retirar las recovery keys viejas de la custodia**: avisar a los 5 custodios de
  que ese material ya no abre nada, para que no quede circulando algo que parece
  sensible y no lo es (o peor: que alguien crea que sí lo es y no guarde bien las
  nuevas).

---

## 6. Síntomas y causas

| Síntoma | Causa | Arreglo |
|---|---|---|
| `bao status` dice `Initialized: true` antes de correr el init | Los PVCs viejos siguen montados | Paso 2: borrar PVCs / namespace |
| Pods `Running` pero sellados, errores de descifrado en los logs | PVCs viejos + key de sellado nueva | Paso 2 |
| Todo levanta perfecto y aparecen las cuentas viejas | PVCs viejos + key vieja: es el vault anterior | Paso 2, y revisar que el Application apunte a `openbao-unseal-key-v2` |
| `CrashLoopBackOff` con `error checking key existence: PermissionDenied` | A la key nueva le falta `roles/cloudkms.viewer` | Re-correr `KMS_KEY=… setup-gcp.sh` |
| La Application vuelve a aparecer después de borrarla | `apps-root` con selfHeal la recrea | Paso 1: sacarla de git **primero**, después `kubectl delete` |
| Se pusheó la baja pero la Application sigue ahí | `apps-root` tiene `prune: false` | Paso 1: `kubectl -n argocd delete application openbao` |
| Un solo pod y `0/1 Ready` | Normal antes del init (`OrderedReady`) | Paso 7: correr `init-openbao.sh` |
| `get pods -w` no muestra nada y el namespace no vuelve | Sync de ArgoCD colgada + `will not retry for [0.28.6]` | [La trampa del `kubectl delete namespace`](#-la-trampa-del-kubectl-delete-namespace-openbao) |
| `* internal error` en `ethereum/*` por `kubectl exec` | Ejecutaste contra un **standby**; el plugin solo responde en el líder | `exec` contra el pod con `openbao-active=true` |
| PV en `Released` colgado | El PVC se borró pero el PV no reclamó | `kubectl delete pv <nombre>` |
| `unsupported path` en `sign-digest` | La imagen no trae el endpoint | §3: verificar el `grep` en el binario |
| `403` en `sign-digest` | Falta la política/rol de digests | `plugin-update.md` §6 |

---

## 7. Checklist

**Antes**

- [ ] Confirmado que **ninguna** address del vault actual vale algo (§0)
- [ ] Fork del plugin con `sign-digest`, variante decidida, `go test ./...` en verde
- [ ] Imagen construida `--platform linux/amd64` y verificada (`grep sign-digest`)
- [ ] CronJob de snapshots suspendido
- [ ] **Ninguna sync de ArgoCD en vuelo** (`operationState.phase` = `Succeeded`) antes de borrar el namespace

**Destrucción**

- [ ] `openbao.yaml` fuera de `kustomization.yaml` en cloud-infra y pusheado
- [ ] `Application/openbao` borrada a mano (`apps-root` no prunea) → NotFound
- [ ] Namespace `openbao` (o los 6 PVCs) borrado — `get pvc` vacío
- [ ] Sin PVs colgados en `Released`

**Alta**

- [ ] `KMS_KEY=openbao-unseal-key-v2 ./k8s/gcp/setup-gcp.sh` OK, con los dos roles
- [ ] Application actualizado: `image.tag` nuevo + `crypto_key` nueva
- [ ] `openbao.yaml` de vuelta en `kustomization.yaml` y pusheado
- [ ] `init-openbao.sh` corrido **una sola vez**; material en Secret Manager (`latest`)
- [ ] Recovery keys nuevas repartidas entre 5 custodios; las viejas retiradas
- [ ] Material del init verificado en Secret Manager con `versions access latest`
      (el script no deja archivos; la exposición es el scrollback de la terminal)
- [ ] `register-plugin.sh` + `bootstrap-auth.sh` + CronJob re-aplicado
- [ ] `smoke-test.sh` en verde (incluido el failover)
- [ ] `verify-sign-digest.sh` en verde contra `https://vault.l-net.io`
- [ ] Cuenta dedicada + política `ethsign-credentials` + rol de K8s (`plugin-update.md` §6)
- [ ] Root token revocado

**Limpieza**

- [ ] Snapshot `post-redeploy` en GCS
- [ ] Snapshots del linaje viejo borrados/archivados
- [ ] Versión vieja de `openbao-prod-recovery` destruida
- [ ] Versiones de `openbao-unseal-key` **deshabilitadas** (destruir más adelante)

---

## Ver también

- [`plugin-update.md`](plugin-update.md) — la alternativa **conservando el
  estado**: fork, imagen, ventana del `sha256`, re-registro y políticas. Su §1-§2
  (fork y build) y §6 (políticas) se usan igual acá.
- [`deployment.md`](deployment.md) — el despliegue paso a paso; desde el paso 4
  aplica tal cual.
- [`unseal-keys.md`](unseal-keys.md) — recovery keys: custodia, rotación,
  escenarios de desastre.
- [`operations.md`](operations.md) — runbook del día a día.
- [`../../plan-digest/README.md`](../../plan-digest/README.md) — por qué se forkea
  el plugin y el contrato del endpoint.
