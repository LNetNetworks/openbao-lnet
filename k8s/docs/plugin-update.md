# Actualizar el binario del plugin `ethsign` en producción (GKE)

> Caso concreto que motiva esta guía: agregar el endpoint **`sign-digest`**
> (firma de un digest crudo de 32 bytes con secp256k1, sin envolverlo en una
> transacción ni aplicar prefijo EIP-191, devolviendo `r‖s‖v`).
>
> El procedimiento sirve igual para **cualquier** cambio del binario del plugin
> (bump de `ETHSIGN_REF`, parche de seguridad de go-ethereum, etc.): lo que
> importa no es qué cambió en el código, sino que **cambia el `sha256`** que
> OpenBao tiene registrado en su catálogo.

> ⚠️ **¿El cluster todavía no está en uso?** Entonces esta guía es el camino
> difícil. Si no hay ninguna address que valga conservar, sale mucho más barato
> **redesplegar limpio** —imagen con `sign-digest` desde el arranque, key de
> sellado nueva, init nuevo—: se evitan la ventana del `sha256` y el
> `generate-root`. Ver [`redeploy-clean.md`](redeploy-clean.md). De esta guía
> seguís necesitando **§1-§2** (fork, variante del endpoint, build args) y **§6**
> (políticas).

**Entradas de esta guía:**

| Fuente | Qué aporta |
|---|---|
| [`../../plugin/guide-implementation-sign-digest.md`](../../plugin/guide-implementation-sign-digest.md) | Cómo se implementó y se probó en el **POC local** (Docker + Compose) |
| [`../../plan-digest/`](../../plan-digest/README.md) | El paquete listo para forkear: código, **test Go**, script de verificación, políticas |
| [`operations.md`](operations.md) | Runbook general (esta guía es el detalle de su sección *Upgrades*) |

---

## 0. TL;DR — el orden importa

```bash
# ANTES: anotar el sha256 actual (lo necesitás para el rollback) y snapshotear
kubectl -n openbao exec -i $POD -- env BAO_TOKEN=$BAO_TOKEN \
  bao read -field=sha256 sys/plugins/catalog/secret/ethsign     # ← guardalo
BAO_TOKEN=$BAO_TOKEN LABEL=pre-plugin-update ./k8s/scripts/snapshot.sh

# 1. Fork del plugin con el endpoint + `go test ./...` en verde
# 2. Build/push de la imagen con ETHSIGN_REPO/ETHSIGN_REF apuntando al fork
# 3. Bump del tag en cloud-infra (job manual `bump-image-tag`) → rollout
# 4. Esperar a que los TRES pods corran la imagen nueva
# 5. Re-registrar el sha256 + recargar el plugin      ← sin esto ethereum/ se rompe
BAO_TOKEN=$BAO_TOKEN ./k8s/scripts/register-plugin.sh
kubectl -n openbao exec -i $POD -- env BAO_TOKEN=$BAO_TOKEN \
  bao plugin reload -plugin=ethsign -scope=global
# 6. Políticas: `ethsign-signer` NO habilita sign-digest (§6)
# 7. Verificar + revocar el token administrativo temporal
```

Los pasos 4 y 5 son los que no se pueden invertir ni saltear, y entre ellos hay
una **ventana en la que `ethereum/*` devuelve error** — explicada en [§5](#5-la-ventana-del-sha256).

---

## 1. Qué se hizo en local, y qué de eso NO se puede llevar a producción

El POC local (Docker Compose) ya tiene el endpoint funcionando y verificado con
`ethers.recoverAddress`. El camino que se usó ahí fue:

1. Clonar el plugin y hacer `git checkout efdc481c…` (el commit pineado en
   `Dockerfile:19`).
2. Crear `backend/path_sign_digest.go` y agregar `pathSignDigest(b),` a `paths()`
   en `backend/accounts.go`.
3. **Copiar el árbol del plugin dentro del repo** como `ethsign-src/` y cambiar
   la stage 1 del `Dockerfile` para que en vez de `git clone` haga
   `COPY ethsign-src/ .`.
4. `docker-compose up -d --build`, unseal, re-registrar el `sha256`, `docker
   restart`, unseal otra vez, y probar con `curl`.

### El punto 3 es el que no sirve en producción

`COPY ethsign-src/ .` resuelve un problema real (Docker solo lee dentro del
build context) pero rompe cuatro cosas de las que depende este despliegue:

| Consecuencia | Por qué importa acá |
|---|---|
| **`ETHSIGN_REF` deja de decir la verdad** | El build arg sigue existiendo pero ya no se usa: la imagen no declara de qué commit salió. Es exactamente lo que `docs/CONFIGURE.md` pide evitar en un componente que firma con llaves privadas. |
| **No hay pin auditable** | `ethsign-src/` es un árbol de archivos sin historia (el guide sugiere borrar el `.git`). Nadie puede reconstruir la imagen a partir del repo + un SHA. |
| **El CI no se dispara** | El job `build` de [`../ci/gitlab-ci.example.yml`](../ci/gitlab-ci.example.yml) tiene `changes: [Dockerfile, config/**/*, scripts/**/*]`. Un cambio en `ethsign-src/**` **no construye nada** y el deploy queda silenciosamente viejo. |
| **Vendorizás un repo entero** | Con `.git` borrado, el próximo bump de upstream es un `diff` a mano. Con un fork es un `git rebase`. |

Además, el cambio del `Dockerfile` **nunca se commiteó**: en el repo la stage 1
sigue clonando de git (`git status` solo muestra `?? plugin/`). O sea: el POC
local está en un estado que la imagen de producción no puede reproducir.

**El camino para producción es el fork** (paso 1 de
[`plan-digest/README.md`](../../plan-digest/README.md)): `ETHSIGN_REPO` apunta al
fork, `ETHSIGN_REF` al commit del fork, y el `Dockerfile` sigue clonando. Cero
cambios estructurales, pin auditable, CI que se dispara.

### Los tres problemas del local, traducidos a K8s

| Problema en local | En K8s |
|---|---|
| **1.** `KeyError: 'ContainerConfig'` al recrear el contenedor (compose v1 + BuildKit) | **No aplica.** No hay docker-compose; despliega ArgoCD. |
| **2.** `checksums did not match` / `route entry found, but backend is nil` | **Aplica igual, y es el riesgo central.** Ver [§5](#5-la-ventana-del-sha256). El "no alcanza con `reload`, hay que reiniciar" se traduce en `kubectl rollout restart sts/openbao`. |
| **3.** El bao queda sellado tras cada restart | **No aplica.** Auto-unseal con Cloud KMS: cada pod vuelve desellado solo. Es la razón por la que un rollout de 3 pods es viable. |

### Antes de construir la imagen: fijar UNA variante del endpoint

Hay **dos implementaciones distintas** del mismo endpoint en el repo, y difieren
en el byte 64 de la firma. Hay que elegir una antes de compilar, porque el
contrato lo consume `client-ssi-vc`:

| | A — `plan-digest/plugin/path_sign_digest.go` | B — la del guide (`plugin/guide-implementation-sign-digest.md`) |
|---|---|---|
| Campos de respuesta | `address`, `hash`, `signature`, `r`, `s`, `v`, `v_eth` | solo `signature` |
| Byte 64 de `signature` | `0`/`1` (recovery id crudo) | `27`/`28` (`sig[64] += 27`) |
| Alias `digest` del campo `hash` | sí | no |
| Hex sin `0x` | acepta | rechaza |
| Operaciones | `Create` + `Update` | solo `Create` |
| Verificación | **test Go** (`ecrecover`, low-s, sin EIP-191, sin re-hash) — `go test ./...` en verde | `curl` + `ethers.recoverAddress` en el POC local |

**Recomendación: partir de A** (es la que tiene test, y expone `v_eth` para
Solidity), y decidir explícitamente el byte 64:

- Si `client-ssi-vc` ya está andando contra B, mantené la normalización a 27/28
  para no romperlo: en A, después de `crypto.Sign`, guardá el `v` crudo, hacé
  `sig[64] += 27`, y reportá `v` = crudo (0/1) y `v_eth` = 27/28. El test hay que
  ajustarlo en tres líneas: las aserciones de `v`/`v_eth`
  (`path_sign_digest_test.go:51-52`) y el `crypto.SigToPub(digest, sig)` de la
  línea 56, que necesita el byte 64 de vuelta en 0/1.
- Si el cliente todavía no está fijo, dejá A tal cual y que use `v_eth`.

Lo que **no** hay que hacer es construir la imagen de producción sin haber
decidido esto: cambiarlo después es otro rebuild, otro rollout y otra ventana de
sha256.

---

## 2. Preparar el binario

### 2.1 El fork — ya existe

| | |
|---|---|
| Repo | [`LNetNetworks/vault-plugin-secrets-ethsign`](https://github.com/LNetNetworks/vault-plugin-secrets-ethsign) (fork público de `kaleido-io/…`) |
| Refs | `master`, rama `feat/sign-digest` y tag `v0.1.0-sign-digest` — los tres apuntan al mismo commit |
| Commit | `236094bd56298a86364f397febd58644042256a8` ← **este es el `ETHSIGN_REF`** |
| Base | `efdc481c29f9eb9a04c8c47e0636bdddc98b9163` (HEAD de upstream al forkear) |
| Delta | `backend/path_sign_digest.go` + `backend/path_sign_digest_test.go` + 1 línea en `backend/accounts.go` |
| Estado | `go build ./...` OK y **suite completa en verde** con go 1.21.10 (~24s), incluidos `TestSignDigest` y `TestSignDigestRejectsBadInput` |

Es la **variante A**: `signature` lleva el recovery id crudo en el byte 64
(`00`/`01`) y `v_eth` (27/28) va como campo aparte.

El test es la verificación que vale: comprueba `ecrecover(digest, sig) ==
address`, que la firma es **low-s** (EIP-2) y que el digest **no** se re-hashea
ni lleva prefijo EIP-191. Con `CGO_ENABLED=0` se usa la implementación pura-Go de
secp256k1 (btcec), también low-s canónica.

**El repo tiene que seguir siendo público**: la etapa 1 del `Dockerfile` hace
`git clone` sin credenciales — verificado clonando en limpio y compilando con el
mismo comando de la stage 1 (`CGO_ENABLED=0 GOOS=linux go build -trimpath`). Y
**el tag `v0.1.0-sign-digest` no se mueve**: es lo que mantiene vivo el commit
pineado si algún día se borra la rama.

Si algún día hay que rehacerlo (o partir de otro commit de upstream), esto es lo
que se hizo:

```bash
git clone https://github.com/LNetNetworks/vault-plugin-secrets-ethsign.git
cd vault-plugin-secrets-ethsign

# Branch DESDE EL COMMIT PINEADO, no desde master: el único delta debe ser este
# endpoint. Si además subís upstream, ante un fallo no sabés cuál lo causó.
git checkout -b feat/sign-digest efdc481c29f9eb9a04c8c47e0636bdddc98b9163

cp ~/lnet/pocs/openbao-lnet-storage/plan-digest/plugin/path_sign_digest.go      backend/
cp ~/lnet/pocs/openbao-lnet-storage/plan-digest/plugin/path_sign_digest_test.go backend/
git apply ~/lnet/pocs/openbao-lnet-storage/plan-digest/plugin/paths.patch

go build ./... && go test ./...   # la suite completa, ~24s
git commit -am "feat: sign-digest endpoint (raw 32-byte secp256k1 digest)"
git push -u origin feat/sign-digest
export ETHSIGN_REF=$(git rev-parse HEAD)
```

**Bumps de upstream:** `git fetch upstream && git rebase upstream/master` sobre
`feat/sign-digest`, `go test ./...`, y recién ahí mover `ETHSIGN_REF`. El delta
es de un archivo, así que el rebase debería ser trivial.

### 2.2 El build ya apunta al fork

Estos cuatro archivos ya están cableados —no hay nada que hacer, es para saber
**dónde se bumpea** el plugin:

| Archivo | Qué tiene |
|---|---|
| `Dockerfile` (líneas 17-23) | `ETHSIGN_REPO` y `ETHSIGN_REF` por defecto = fork + commit |
| `docker-compose.yml` | los dos args, con `${VAR:-default}` para poder sobreescribir |
| `k8s/ci/gitlab-ci.example.yml` | los dos como `variables:` + en `DOCKER_BUILD_ARGS`, y **`.gitlab-ci.yml` agregado a `changes:`** — sin eso, bumpear `ETHSIGN_REF` no dispara ningún build y el deploy se queda con el binario viejo, en silencio |
| `docs/CONFIGURE.md` | qué es el fork, por qué debe ser público y cómo se rebasa |

Un bump del plugin es: rebase en el fork → nuevo sha → editar `ETHSIGN_REF` en
`.gitlab-ci.yml` (y en el `Dockerfile`, para que el build local coincida) → build
→ el resto de esta guía.

### 2.3 Probar en el POC local antes de tocar GKE

```bash
docker compose build            # ya toma el fork por defecto
docker compose up -d
docker compose exec openbao bao operator unseal <UNSEAL_KEY>

# el binario cambió → re-registrar el sha (el catálogo del volumen tiene el viejo)
docker exec -e BAO_TOKEN=$BAO_TOKEN openbao-lnet sh -c \
  'bao plugin register -sha256=$(sha256sum /openbao/plugins/ethsign | cut -d" " -f1) -command=ethsign secret ethsign'
docker restart openbao-lnet && docker compose exec openbao bao operator unseal <UNSEAL_KEY>

BAO_TOKEN=$BAO_TOKEN ./plan-digest/scripts/verify-sign-digest.sh
```

Si esto no pasa en local, no hay nada que desplegar.

---

## 3. Prerrequisitos en producción (el que frena a todo el mundo: el token)

### 3.1 Hace falta un token administrativo, y **no hay ninguno vivo**

El paso 12 de [`deployment.md`](deployment.md) revoca el root token a propósito.
`register-plugin.sh` necesita permisos sobre `sys/plugins/catalog/*`, que la
política `openbao-operator` incluye. El token se emite por su rol de auth de
Kubernetes:

```bash
JWT=$(kubectl -n openbao create token openbao-operator --duration=1800s)
export BAO_TOKEN=$(curl -s -d "{\"role\":\"openbao-operator\",\"jwt\":\"$JWT\"}" \
  https://vault.l-net.io/v1/auth/kubernetes/login | jq -r .auth.client_token)
```

⚠️ **No sirve `bao operator generate-root` con las recovery keys.** Desde OpenBao
2.6.0 ese endpoint es autenticado: los shares son necesarios pero no suficientes.
Evidencia y alternativas en
[`admin-access-recovery.md`](admin-access-recovery.md); custodia de los shares en
[`unseal-keys.md`](unseal-keys.md).

**Y revocarlo al terminar** (paso 7 de [§4](#4-despliegue-paso-a-paso)). Un root
token olvidado es la peor deuda de seguridad de un vault.

### 3.2 La política `openbao-operator` no alcanza para el `reload`

Si en vez de un root token preferís un token de operador
(`bao token create -policy=openbao-operator -ttl=2h`), tené en cuenta que esa
política **cubre `sys/plugins/catalog/*` pero no `sys/plugins/reload/backend`** →
el `bao plugin reload` del paso 5 devuelve 403. Hay que agregarle:

```hcl
path "sys/plugins/reload/backend" { capabilities = ["create", "update", "sudo"] }
```

en `k8s/scripts/bootstrap-auth.sh` (bloque de la política `openbao-operator`) y
re-correr el script — es idempotente. Nota aparte: hoy **ningún rol de auth de
Kubernetes está bindeado a `openbao-operator`**, así que ese token solo puede
emitirlo alguien que ya tenga root.

### 3.3 Snapshot y ventana de mantenimiento

```bash
BAO_TOKEN=$BAO_TOKEN LABEL=pre-plugin-update ./k8s/scripts/snapshot.sh
```

Y avisar a los consumidores: el rollout provoca **uno o dos failovers de Raft**
(las peticiones en vuelo fallan y hay que reintentarlas) y, entre el rollout y el
re-registro, **`ethereum/*` no responde** ([§5](#5-la-ventana-del-sha256)).

Anotá el `sha256` actual antes de tocar nada — es lo que necesitás para el
rollback:

```bash
kubectl -n openbao exec -i $POD -- env BAO_TOKEN=$BAO_TOKEN \
  bao read -field=sha256 sys/plugins/catalog/secret/ethsign
```

---

## 4. Despliegue paso a paso

### Paso 1 — Build y push de la imagen

Por pipeline (push a `main` con los cambios de §2.2), o a mano:

```bash
export TAG=$(git rev-parse --short HEAD)
export IMG=us-central1-docker.pkg.dev/l-net-469615/l-net-docker-repo/openbao-ethsign

gcloud auth configure-docker us-central1-docker.pkg.dev

# --platform linux/amd64 es obligatorio desde un Mac con Apple Silicon.
# ETHSIGN_REPO/ETHSIGN_REF ya vienen por defecto del Dockerfile (el fork y su
# commit). Pasalos explícitos solo si estás probando otro commit del plugin.
docker buildx build --platform linux/amd64 \
  --build-arg OPENBAO_VERSION=2.6.1 \
  -t "$IMG:$TAG" --push .
```

**Calculá ya el `sha256` del binario nuevo**, para tener el comando de registro
listo y no improvisar dentro de la ventana:

```bash
docker run --rm --platform linux/amd64 --entrypoint sha256sum "$IMG:$TAG" \
  /openbao/plugins/ethsign
```

Comprobación rápida de que la imagen **sí** trae el endpoint (el binario del
plugin lleva el pattern como string):

```bash
docker run --rm --entrypoint sh "$IMG:$TAG" -c \
  'grep -c "sign-digest" /openbao/plugins/ethsign'   # > 0
```

### Paso 2 — Bump del tag (esto ES el deploy)

Job manual `bump-image-tag` del pipeline, o a mano en cloud-infra:

```yaml
# gitops-apps/argocd-applications/openbao.yaml
.spec.source.helm.valuesObject.server.image.tag: "<TAG>"
```

Recordá que el eslabón a mirar es **`apps-root`**, no la Application `openbao`
(su `revision: 0.28.6` es la versión del chart, no un commit):

```bash
kubectl -n argocd get application apps-root \
  -o jsonpath='{.status.sync.status} {.status.sync.revision}{"\n"}'
```

### Paso 3 — Esperar el rollout COMPLETO

```bash
kubectl -n openbao rollout status statefulset/openbao --timeout=10m
kubectl -n openbao get pods -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.containers[0].image}{"\n"}{end}'
```

Los tres pods tienen que mostrar el tag nuevo. El rollout va en orden inverso
(`openbao-2` → `-1` → `-0`), de a uno, esperando Ready, y cada pod **se desella
solo con KMS**.

Verificación que realmente importa — que el binario sea idéntico en los tres:

```bash
for p in openbao-0 openbao-1 openbao-2; do
  printf '%s ' "$p"
  kubectl -n openbao exec -i $p -- sha256sum /openbao/plugins/ethsign
done
```

Si un pod quedó con el binario viejo, **no sigas**: al re-registrar el sha nuevo,
ese pod no podrá instanciar el plugin cuando le toque ser líder.

### Paso 4 — Re-registrar el `sha256` y recargar

```bash
BAO_TOKEN=$BAO_TOKEN ./k8s/scripts/register-plugin.sh
```

El script es idempotente: recalcula el sha dentro del pod activo, lo registra y
**salta el mount** porque `ethereum/` ya existe (por eso hace falta el reload).

```bash
export POD=$(kubectl -n openbao get pods -l openbao-active=true -o jsonpath='{.items[0].metadata.name}')

# Confirmar que catálogo == binario
kubectl -n openbao exec -i $POD -- sha256sum /openbao/plugins/ethsign
kubectl -n openbao exec -i $POD -- env BAO_TOKEN=$BAO_TOKEN \
  bao read -field=sha256 sys/plugins/catalog/secret/ethsign

# Recargar el backend en TODO el cluster, no solo en el nodo que atiende
kubectl -n openbao exec -i $POD -- env BAO_TOKEN=$BAO_TOKEN \
  bao plugin reload -plugin=ethsign -scope=global
```

`-scope=global` es importante en un cluster de 3 nodos: sin él, el reload afecta
solo al nodo que recibió la petición. Si tu versión del CLI no lo acepta, el
equivalente por API es:

```bash
kubectl -n openbao exec -i $POD -- env BAO_TOKEN=$BAO_TOKEN \
  bao write sys/plugins/reload/backend plugin=ethsign scope=global
```

**Si después del reload `ethereum/*` sigue devolviendo `backend is nil`**, es el
mismo caso que en local: un backend que arrancó nulo no siempre revive con un
reload. Reiniciá los pods —seguro, porque se desellan solos:

```bash
kubectl -n openbao rollout restart sts/openbao
kubectl -n openbao rollout status  sts/openbao --timeout=10m
```

### Paso 5 — Verificar

```bash
# No debe aparecer "checksums did not match" en ningún pod
for p in openbao-0 openbao-1 openbao-2; do
  kubectl -n openbao logs $p --tail=50 | grep -i "checksum\|backend is nil" && echo "^^ $p"
done

# El engine responde
kubectl -n openbao exec -i $POD -- env BAO_TOKEN=$BAO_TOKEN bao list ethereum/accounts

# Firma de transacción (lo que ya funcionaba — no debe romperse)
BAO_TOKEN=$BAO_TOKEN SKIP_FAILOVER=1 ./k8s/scripts/smoke-test.sh

# El endpoint nuevo, contra producción
BAO_ADDR=https://vault.l-net.io BAO_TOKEN=$BAO_TOKEN \
  ./plan-digest/scripts/verify-sign-digest.sh
```

`verify-sign-digest.sh` crea (o reusa, con `ADDRESS=0x…`) una cuenta, firma un
digest y verifica con `ethers.recoverAddress` que la address recuperada sea la de
la cuenta. Si falta `ethers` imprime la firma y avisa; no falla en silencio.

Si devuelve `unsupported path`, el binario en el pod no tiene el endpoint → volvé
al paso 3 (¿rolaron los tres pods?). Si devuelve `403`, es cuestión de políticas →
[§6](#6-políticas-sin-esto-el-endpoint-queda-403).

### Paso 6 — Políticas

Ver [§6](#6-políticas-sin-esto-el-endpoint-queda-403). No es opcional: sin ese
paso el endpoint existe pero ningún consumidor puede usarlo.

### Paso 7 — Revocar el token temporal

```bash
kubectl -n openbao exec -i $POD -- env BAO_TOKEN=$BAO_TOKEN bao token revoke -self
```

Y un snapshot post-deploy, para tener un punto de restore ya con el plugin nuevo:

```bash
BAO_TOKEN=<token> LABEL=post-plugin-update ./k8s/scripts/snapshot.sh   # antes de revocar
```

---

## 5. La ventana del `sha256`

OpenBao valida el `sha256` del binario **cada vez que lanza el proceso del
plugin** (al montar el engine, tras un unseal o un cambio de líder). El registro
del catálogo vive en Raft: es **estado de cluster, uno solo para los tres nodos**.
El binario, en cambio, viaja en la imagen: **uno por pod**.

De ahí sale una ventana inevitable:

```
t0  catálogo=sha_viejo   pods: [viejo viejo viejo]     ethereum/ OK
t1  catálogo=sha_viejo   pods: [nuevo viejo viejo]     rollout en curso
t2  catálogo=sha_viejo   pods: [nuevo nuevo nuevo]     ← VENTANA: el líder tiene
                                                         binario nuevo y el
                                                         catálogo el sha viejo
t3  catálogo=sha_nuevo   pods: [nuevo nuevo nuevo]     ethereum/ OK (tras reload)
```

Durante **t2**, en cuanto el líder intente instanciar el backend, toda llamada a
`ethereum/*` falla con:

```
route entry found, but backend is nil
failed to create mount entry: path=ethereum/  error= invalid backend version: checksums did not match
```

**Los pods siguen `1/1 Ready`** (el readiness probe mira `bao status`, no el
engine) y las métricas se ven sanas. Solo fallan las firmas. Es el mismo
`Problema 2` del POC local, con la diferencia de que acá hay clientes reales
pegándole.

Cómo achicarla:

- Tener el comando de registro **preparado** con el sha calculado en el paso 1,
  para ejecutarlo apenas termine el rollout.
- Correr los pasos 3 y 4 seguidos, en la misma sesión, sin ir a buscar el token
  en medio (de ahí que §3.1 sea un prerrequisito y no un paso).
- Hacerlo en ventana de mantenimiento. El vault firma; no es un servicio que
  tolere errores mudos.

> **Mejora posible, sin validar:** OpenBao soporta plugins **versionados**
> (`bao plugin register -version=v0.2.0 …` + `bao secrets tune
> -plugin-version=…`), que permitirían registrar la versión nueva antes del
> rollout y cerrar la ventana. El registro actual es **sin versión**, así que
> mezclar ambos esquemas es un cambio a ensayar en un cluster desechable antes de
> tocar producción — no lo hagas por primera vez en un upgrade.

---

## 6. Políticas: sin esto el endpoint queda 403

La política `ethsign-signer` (creada por `bootstrap-auth.sh`) habilita:

```hcl
path "ethereum/accounts/+/sign" { capabilities = ["create", "update"] }
```

`+` matchea **un segmento**, y el path no lleva `*` al final: **no cubre
`.../sign-digest`**. O sea que hoy, por defecto, todos los consumidores que usan
el rol `ethsign-signer` reciben **403** en el endpoint nuevo. Eso es lo correcto
como punto de partida, y conviene que siga así.

### Por qué NO conviene agregarlo a `ethsign-signer`

Firmar digests arbitrarios es **más poderoso** que firmar transacciones: el hash
de una transacción no es más que `keccak256(RLP(tx))`, calculable off-chain. Quien
pueda pedir la firma de un digest cualquiera puede armar una transacción válida
que mueva fondos, salteándose cualquier restricción que hoy dependa de que sea el
vault el que construye la tx.

### Lo que hay que hacer

1. **Cuenta dedicada** para los `credentialHash`, **sin saldo**, distinta de las
   que firman transacciones on-chain.

   > ⚠️ **Las cuentas no tienen "tipo".** El plugin no distingue una cuenta de
   > `/sign` de una de `sign-digest`: las dos se crean con el mismo comando y son
   > llaves secp256k1 idénticas. **Lo que las separa es la política, no la
   > cuenta.** Con un token administrativo, cualquier cuenta puede hacer las dos
   > cosas. La separación existe porque `ethsign-signer` deniega `sign-digest` y
   > `ethsign-credentials` deniega `/sign` y está acotada a **una** address.
   > Corolario: si mañana alguien escribe una política más laxa, la cuenta
   > "dedicada" deja de estar dedicada. El control es la política.

   Crear ambas cuentas es el mismo comando. Por CLI, contra el **nodo activo**
   (`bao write -f` = POST con cuerpo vacío → el plugin genera la llave adentro):

   ```bash
   export POD=$(kubectl -n openbao get pods -l openbao-active=true \
     -o jsonpath='{.items[0].metadata.name}')

   # Cuenta para firmar transacciones (la que va en el .env del cliente)
   kubectl -n openbao exec -i $POD -- env BAO_TOKEN="$BAO_TOKEN" \
     bao write -f -format=json ethereum/accounts | jq -r .data.address

   # Cuenta dedicada para credentialHash (sin saldo, nunca fondearla)
   kubectl -n openbao exec -i $POD -- env BAO_TOKEN="$BAO_TOKEN" \
     bao write -f -format=json ethereum/accounts | jq -r .data.address
   ```

   O por HTTP, equivalente:

   ```bash
   curl -s -H "X-Vault-Token: $BAO_TOKEN" -H "Content-Type: application/json" \
     -d '{}' https://vault.l-net.io/v1/ethereum/accounts | jq -r .data.address
   ```

   La llave privada **nunca sale del vault**: la respuesta trae solo `address`.
   Y **no se puede exportar** (`ethereum/export/*` está denegado en todas las
   políticas), así que estas addresses **no sobreviven a una re-inicialización** —
   ver el aviso de
   [`admin-access-recovery.md` §4](admin-access-recovery.md#opción-a--re-inicializar-recomendada-mientras-no-haya-nada-valioso).

   ⚠️ **El `exec` tiene que ir al nodo activo.** El plugin solo responde en el
   líder de Raft: contra un standby, `ethereum/*` falla con un
   `* internal error` sin más contexto (no un 307, no un redirect). Por HTTP no
   pasa, porque el Ingress apunta al Service `openbao-active`.
2. **Políticas separadas con `deny` cruzado** (`deny` siempre gana en OpenBao).
   La plantilla está en
   [`../../plan-digest/policies/ethsign-digest.hcl`](../../plan-digest/policies/ethsign-digest.hcl)
   — hay que reemplazar `0xCUENTA_CREDENCIALES` por la address real:

   ```bash
   export POD=$(kubectl -n openbao get pods -l openbao-active=true -o jsonpath='{.items[0].metadata.name}')

   kubectl -n openbao exec -i $POD -- env BAO_TOKEN=$BAO_TOKEN \
     bao policy write ethsign-credentials - <<'EOF'
   path "ethereum/accounts/0xCUENTA_CREDENCIALES/sign-digest" {
     capabilities = ["create", "update"]
   }
   path "ethereum/accounts/0xCUENTA_CREDENCIALES" {
     capabilities = ["read"]
   }
   path "ethereum/export/accounts/*" { capabilities = ["deny"] }
   path "ethereum/accounts/+/sign"   { capabilities = ["deny"] }
   path "auth/token/renew-self"  { capabilities = ["update"] }
   path "auth/token/revoke-self" { capabilities = ["update"] }
   EOF
   ```

   Las capabilities van con **`create` y `update` las dos**: qué operación
   lógica le toca a un `POST` depende del `ExistenceCheck` del plugin, y no
   conviene depender de ese detalle.

3. **Rol de auth de Kubernetes propio**, para que solo el consumidor de
   credenciales lo obtenga (y no todo el que hoy tiene `ethsign-signer`):

   ```bash
   kubectl -n openbao exec -i $POD -- env BAO_TOKEN=$BAO_TOKEN \
     bao write auth/kubernetes/role/ethsign-credentials \
       bound_service_account_names=client-ssi-vc \
       bound_service_account_namespaces=<ns-del-cliente> \
       policies=ethsign-credentials \
       ttl=1h max_ttl=4h
   ```

4. **Cerrarle `sign-digest` a `ethsign-signer`**, explícitamente, para que un
   token de firma de transacciones no lo herede nunca:

   ```hcl
   path "ethereum/accounts/+/sign-digest" { capabilities = ["deny"] }
   ```

   **Ya está en el heredoc** de la política `ethsign-signer` de
   `k8s/scripts/bootstrap-auth.sh`: se aplica solo con correr el script
   (idempotente). Que viva en el script y no solo en el cluster es lo que evita
   que el próximo bootstrap lo revierta.

5. **Auditoría.** El audit device declarativo ya registra cada llamada. Vale la
   pena mirar/alertar ese path específicamente:

   ```bash
   kubectl -n openbao exec -i $POD -- \
     sh -c 'grep -c "sign-digest" /openbao/audit/audit.log'
   ```

   Y sumar a Grafana un panel de volumen de `sign-digest` por identidad: un pico
   en ese endpoint es exactamente la señal que uno querría ver.

---

## 7. Rollback

El binario vuelve atrás con el tag; el catálogo, con el `sha256` que anotaste en
§3.3.

```bash
# 1. Revertir el tag en cloud-infra (o `git revert` del commit del bump)
#    .spec.source.helm.valuesObject.server.image.tag: "<TAG_ANTERIOR>"

# 2. Esperar el rollout completo y comprobar el binario en los 3 pods
kubectl -n openbao rollout status statefulset/openbao --timeout=10m

# 3. Volver a registrar el sha VIEJO (el que anotaste) y recargar
BAO_TOKEN=$BAO_TOKEN ./k8s/scripts/register-plugin.sh   # recalcula del binario actual
kubectl -n openbao exec -i $POD -- env BAO_TOKEN=$BAO_TOKEN \
  bao plugin reload -plugin=ethsign -scope=global
```

**No hace falta restore de snapshot.** Las cuentas viven en Raft y son
independientes del binario: esto es un cambio de código del plugin, no una
migración de datos. El snapshot está por si algo sale mal *durante* el rollout,
no por el rollback en sí.

Las políticas y el rol nuevos se pueden dejar puestos: sin el endpoint en el
binario, `sign-digest` devuelve `unsupported path` y no habilitan nada.

---

## 8. Checklist

**Antes**

- [ ] Variante del endpoint decidida (§1) y `go test ./...` en verde en el fork
- [ ] Fork pusheado, `ETHSIGN_REF` = commit del fork
- [ ] `docker-compose.yml`, `Dockerfile` y el CI pasan `ETHSIGN_REPO`/`ETHSIGN_REF` (§2.2)
- [ ] Probado end-to-end en el POC local (§2.3)
- [ ] `sha256` actual del catálogo **anotado** (para el rollback)
- [ ] Snapshot `pre-plugin-update` en GCS
- [ ] Token administrativo obtenido con 3 recovery keys (§3.1)
- [ ] Ventana avisada a los consumidores

**Durante**

- [ ] Imagen construida `--platform linux/amd64` y `sha256` del binario nuevo calculado
- [ ] `apps-root` sincronizado (no solo la Application `openbao`)
- [ ] Los **tres** pods con el tag nuevo y el **mismo** `sha256sum`
- [ ] `register-plugin.sh` corrido; catálogo == binario
- [ ] `bao plugin reload -scope=global` OK
- [ ] Ningún `checksums did not match` en los logs de los tres pods

**Después**

- [ ] `smoke-test.sh` en verde (la firma de transacciones no se rompió)
- [ ] `verify-sign-digest.sh` en verde contra `https://vault.l-net.io`
- [ ] Cuenta dedicada creada (sin saldo) + política `ethsign-credentials` + rol de K8s
- [ ] `deny` de `sign-digest` agregado a `ethsign-signer` **en `bootstrap-auth.sh`**
- [ ] Llamadas a `sign-digest` visibles en `audit.log`
- [ ] Snapshot `post-plugin-update`
- [ ] Token administrativo revocado

---

## 9. Docs que hay que actualizar cuando esto se despliegue

Hoy ninguna de estas menciona `sign-digest`, a propósito (ver
`plan-digest/README.md` §6):

| Archivo | Qué agregar |
|---|---|
| `CLAUDE.md` | Fila en la tabla *Engine API*; nota de que el plugin es un fork |
| `README.md`, `docs/quickstart.md` | El endpoint y su payload |
| `docs/CONFIGURE.md` | `ETHSIGN_REPO` apuntando al fork + política de rebase de upstream |
| `k8s/docs/operations.md` | Enlace a esta guía desde *Upgrades* |
| `k8s/scripts/bootstrap-auth.sh` | `deny` de `sign-digest` en `ethsign-signer`; `sys/plugins/reload/backend` en `openbao-operator` |
| `k8s/ci/gitlab-ci.example.yml` | Los build args del fork |
| `plan-digest/README.md` | Cambiar el estado de *PLANIFICADO* a *implementado*, o fusionarlo acá |

---

## Ver también

- [`../../plugin/guide-implementation-sign-digest.md`](../../plugin/guide-implementation-sign-digest.md) — la implementación en el POC local, con sus tres problemas reales.
- [`../../plan-digest/README.md`](../../plan-digest/README.md) — por qué se forkea el plugin, el contrato del endpoint, y por qué Transit no sirve (no soporta secp256k1).
- [`operations.md`](operations.md) — runbook general: failover, restore, upgrades, escalado.
- [`deployment.md`](deployment.md) — el despliegue desde cero (y por qué no hay root token vivo).
- [`unseal-keys.md`](unseal-keys.md) — custodia de las recovery keys y qué dejaron de poder hacer.
- [`admin-access-recovery.md`](admin-access-recovery.md) — cómo conseguir un token administrativo sin root token.
- [`../../docs/throughput.md`](../../docs/throughput.md) — HA ≠ throughput. Aplica a `/sign`; `sign-digest` no emite transacciones, así que no toca el problema de nonces.
