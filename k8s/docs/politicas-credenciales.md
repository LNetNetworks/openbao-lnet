# Políticas y credenciales — cómo se autoriza cada cosa

> Esta guía responde una pregunta concreta: **¿con qué comando se le asigna una
> política a una cuenta?** La respuesta corta es que **no existe ese comando**,
> porque las políticas no se asignan a cuentas. Se asignan a **tokens**, a través
> de un **rol de auth**. La cuenta solo aparece *dentro* del texto de la política,
> como un path.
>
> Entender esa distinción es lo que evita los dos errores que costaron caro el
> 2026-08-17: creer que una cuenta "es de `sign-digest`" (no lo es: lo dice la
> política), y escribir una política sin crear su rol (queda inutilizable).

---

## 1. El modelo mental: tres eslabones

```
  cuenta 0x2242…          ← NO tiene tipo ni política. Es una llave secp256k1.
       │                     Solo aparece como un path en el texto de la política.
       ▼
  POLÍTICA                ← texto HCL: qué paths, con qué capabilities
  ethsign-credentials
       │  policies=…
       ▼
  ROL de auth k8s         ← pega la política a una ServiceAccount concreta
  ethsign-credentials
       │  bound_service_account_names / _namespaces
       ▼
  ServiceAccount          ← openbao/ethsign-credentials
       │  kubectl create token  →  auth/kubernetes/login
       ▼
  TOKEN                   ← lo único que el vault mira al autorizar una request
```

**El vault autoriza mirando el token, nunca la cuenta.** Cuando llega un
`POST /v1/ethereum/accounts/0x2242…/sign-digest`, OpenBao resuelve las políticas
del token y las compara contra ese path literal. La cuenta no opina.

### Consecuencias que hay que tener presentes

- **Las cuentas no tienen tipo.** La de `/sign` y la de `sign-digest` se crean con
  el mismo comando y son indistinguibles. Con un token administrativo, cualquiera
  puede hacer las dos cosas.
- **Una política sin rol es papel mojado.** Nadie puede obtener un token que la
  lleve. Es exactamente lo que dejó `sign-digest` inutilizable: la política
  `ethsign-credentials` existía, el rol no, y cuando se quiso crear ya no había
  token administrativo ([`admin-access-recovery.md`](admin-access-recovery.md)).
- **La separación de cuentas sigue valiendo**, pero por razones que sí son de la
  cuenta, no de la autorización: la cuenta de digests **no tiene saldo ni nonce en
  ninguna red** (una firma filtrada no mueve fondos), y una address distinta hace
  que el audit log distinga sin ambigüedad quién pidió qué.

---

## 2. Cómo se crean las cuentas

Las dos, con el mismo comando. `bao write -f` es un POST con cuerpo vacío: el
plugin genera la llave secp256k1 **dentro** del vault y devuelve solo la address.

```bash
export POD=$(kubectl -n openbao get pods -l openbao-active=true \
  -o jsonpath='{.items[0].metadata.name}')

kubectl -n openbao exec -i $POD -- env BAO_TOKEN="$BAO_TOKEN" \
  bao write -f -format=json ethereum/accounts | jq -r .data.address
```

Equivalente por HTTP:

```bash
curl -s -H "X-Vault-Token: $BAO_TOKEN" -H "Content-Type: application/json" \
  -d '{}' https://vault.l-net.io/v1/ethereum/accounts | jq -r .data.address
```

Para **importar** una llave generada afuera (renuncia a la propiedad de que la
llave nunca salió del vault — aceptable para un deployer de testnet, inaceptable
para la cuenta de `credentialHash`):

```bash
curl -s -H "X-Vault-Token: $BAO_TOKEN" -H "Content-Type: application/json" \
  -d '{"privateKey":"0x…"}' https://vault.l-net.io/v1/ethereum/accounts
```

⚠️ **Dos cosas del `exec`:**

- Tiene que ir al **nodo activo**. El plugin solo responde en el líder de Raft;
  contra un standby, `ethereum/*` falla con `* internal error` pelado — sin 307 y
  sin explicación. Por HTTP no pasa porque el Ingress apunta al Service
  `openbao-active`.
- La llave **no se puede exportar** (`ethereum/export/*` está denegado en todas
  las políticas), así que estas addresses **no sobreviven a una
  re-inicialización**. Todo lo que las hardcodee se rompe.

---

## 3. Los tres comandos que asignan una política

Ejemplo completo con `ethsign-credentials`, tal como está en producción.

### Paso 1 — Escribir la política

Acá es donde la address entra en juego: como un path literal.

```bash
export POD=$(kubectl -n openbao get pods -l openbao-active=true \
  -o jsonpath='{.items[0].metadata.name}')
CRED=0x22422474e66c3c642f5b8394426d9ebcf65773c8   # la cuenta dedicada

kubectl -n openbao exec -i $POD -- env BAO_TOKEN="$BAO_TOKEN" \
  bao policy write ethsign-credentials - <<EOF
path "ethereum/accounts/${CRED}/sign-digest" { capabilities = ["create", "update"] }
path "ethereum/accounts/${CRED}"             { capabilities = ["read"] }
path "ethereum/export/accounts/*"            { capabilities = ["deny"] }
path "ethereum/accounts/+/sign"              { capabilities = ["deny"] }
path "auth/token/renew-self"                 { capabilities = ["update"] }
path "auth/token/revoke-self"                { capabilities = ["update"] }
EOF
```

Notas del contenido:

- **`create` y `update` las dos.** Qué operación lógica le toca a un `POST`
  depende del `ExistenceCheck` del plugin; no conviene depender de ese detalle.
- **`+` matchea un segmento; `*` matchea el resto del path.** `accounts/+/sign`
  **no** cubre `accounts/<addr>/sign-digest`, porque `sign-digest` es otro
  segmento distinto de `sign`. Ese fue el `deny` implícito original — correcto
  pero frágil, porque depende de cómo uno lea el path matching. Hoy está
  explícito.
- **`deny` siempre gana** en OpenBao, sin importar el orden ni lo específico que
  sea el path que permite.

### Paso 2 — Crear la ServiceAccount

```bash
kubectl -n openbao create serviceaccount ethsign-credentials
```

### Paso 3 — Crear el rol: **este es el comando que asigna la política**

```bash
kubectl -n openbao exec -i $POD -- env BAO_TOKEN="$BAO_TOKEN" \
  bao write auth/kubernetes/role/ethsign-credentials \
    bound_service_account_names=ethsign-credentials \
    bound_service_account_namespaces=openbao \
    policies=ethsign-credentials \
    ttl=1h max_ttl=4h
```

`policies=` es la asignación. Se la asigna al **rol**, o sea a todo token que
nazca de él. `bound_service_account_*` es el control de acceso real: solo un JWT
de esa SA en ese namespace se puede canjear.

### Paso 4 — Obtener un token

```bash
JWT=$(kubectl -n openbao create token ethsign-credentials --duration=3600s)

CT=$(curl -s -d "{\"role\":\"ethsign-credentials\",\"jwt\":\"$JWT\"}" \
  https://vault.l-net.io/v1/auth/kubernetes/login | jq -r .auth.client_token)
```

El control de acceso queda delegado en el **RBAC de Kubernetes**: quien pueda
`kubectl create token` sobre esa SA obtiene la credencial. Es auditable y
revocable, a diferencia de un token estático en un `.env`.

---

## 4. Lo que hay en producción

Cuatro políticas, cuatro roles. Estado real al 2026-08-17.

| Política | Rol | ServiceAccounts habilitadas | TTL / máx |
|---|---|---|---|
| `ethsign-signer` | `ethsign-signer` | **cualquiera** (`*`) de `naas`, `ppr`, `lnet-tools` | 1h / 4h |
| `ethsign-credentials` | `ethsign-credentials` | `ethsign-credentials` en `openbao` | 1h / 4h |
| `openbao-operator` | `openbao-operator` | `openbao-operator` en `openbao` | 30m / 2h |
| `snapshot` | `snapshot` | `openbao-snapshot` en `openbao` | 15m / 30m |

### `ethsign-signer` — firmar transacciones

```hcl
path "ethereum/accounts"              { capabilities = ["create", "update", "list"] }
path "ethereum/accounts/*"            { capabilities = ["read"] }
path "ethereum/accounts/+/sign"       { capabilities = ["create", "update"] }
path "ethereum/accounts/+/sign-digest"{ capabilities = ["deny"] }   # ← explícito
path "ethereum/export/*"              { capabilities = ["deny"] }
path "auth/token/renew-self"          { capabilities = ["update"] }
path "auth/token/revoke-self"         { capabilities = ["update"] }
```

Es la que usan los clientes. Puede crear cuentas y firmar transacciones sobre
**cualquiera**; no puede exportar llaves ni firmar digests.

> El rol tiene `bound_service_account_names=*`: **cualquier** SA de esos tres
> namespaces sirve, incluida la `default`. Es cómodo (permite `kubectl create
> token default -n lnet-tools` para desbloquear un cliente) y es laxo. Si algún
> día esos namespaces alojan cargas de terceros, hay que acotarlo.

### `ethsign-credentials` — firmar digests crudos

Ver §3. Acotada a **una** address, con `deny` cruzado sobre `/sign` y `export`.

Existe porque firmar un digest arbitrario es **más poderoso** que firmar una
transacción: el hash de una tx es `keccak256(RLP(tx))`, calculable off-chain, así
que quien pueda pedir la firma de un digest cualquiera puede armar una transacción
válida y saltearse toda restricción que dependa de que el vault construya la tx.

### `openbao-operator` — administrar sin root token

```hcl
path "sys/health"            { capabilities = ["read", "sudo"] }
path "sys/leader"            { capabilities = ["read"] }
path "sys/seal-status"       { capabilities = ["read"] }
path "sys/storage/raft/*"    { capabilities = ["read", "list", "sudo"] }
path "sys/mounts"            { capabilities = ["read", "list"] }
path "sys/mounts/*"          { capabilities = ["create", "read", "update", "delete", "list", "sudo"] }
path "sys/auth"              { capabilities = ["read", "list"] }
path "sys/auth/*"            { capabilities = ["create", "read", "update", "delete", "sudo"] }
path "sys/policies/acl/*"    { capabilities = ["create", "read", "update", "delete", "list"] }
path "sys/plugins/catalog/*" { capabilities = ["create", "read", "update", "list", "sudo"] }
path "auth/kubernetes/role/*"{ capabilities = ["create", "read", "update", "delete", "list"] }
path "sys/audit"             { capabilities = ["read", "list", "sudo"] }
path "sys/audit/*"           { capabilities = ["create", "update", "sudo"] }
```

**No toca `ethereum/*`**: operar no es firmar. Un token de operador recibe 403 al
intentar crear una cuenta, y eso es correcto.

Es el camino de vuelta cuando no hay root token — imprescindible, porque desde
OpenBao 2.6.0 las recovery keys **no** acuñan uno
([`admin-access-recovery.md`](admin-access-recovery.md)).

### `snapshot` — solo backups

```hcl
path "sys/storage/raft/snapshot" { capabilities = ["read"] }
```

La usa el CronJob de `k8s/backup/snapshot-cronjob.yaml`.

---

## 5. Verificar que una política hace lo que dice

Escribirla no es verificarla. El chequeo es emitir un token real y probar **los
cruces**, no solo el camino feliz:

```bash
JWT=$(kubectl -n openbao create token ethsign-credentials --duration=600s)
CT=$(curl -s -d "{\"role\":\"ethsign-credentials\",\"jwt\":\"$JWT\"}" \
  https://vault.l-net.io/v1/auth/kubernetes/login | jq -r .auth.client_token)

B=https://vault.l-net.io/v1
CRED=0x22422474e66c3c642f5b8394426d9ebcf65773c8
OTRA=<otra address del vault>
H=0x8f1a036772604741d9e44b9a3a2b7e900f062873850b7fe2a5b00351e9b14f5c

code() { curl -s -o /dev/null -w '%{http_code}' "$@"; }

code -H "X-Vault-Token: $CT" -d "{\"hash\":\"$H\"}" "$B/ethereum/accounts/$CRED/sign-digest"
code -H "X-Vault-Token: $CT" -d "{\"hash\":\"$H\"}" "$B/ethereum/accounts/$OTRA/sign-digest"
code -H "X-Vault-Token: $CT" -d '{"to":"0x…","data":"0x","value":"0","nonce":"0x0","gas":21000,"gasPrice":0,"chainId":"648529"}' "$B/ethereum/accounts/$CRED/sign"
code -H "X-Vault-Token: $CT" "$B/ethereum/export/accounts/$CRED"
code -H "X-Vault-Token: $CT" -d '{}' "$B/ethereum/accounts"
code -H "X-Vault-Token: $CT" "$B/ethereum/accounts/$CRED"
code -X LIST -H "X-Vault-Token: $CT" "$B/ethereum/accounts"
```

Resultado esperado, verificado en producción el 2026-08-17:

| Operación | Esperado |
|---|---|
| `sign-digest` en la cuenta dedicada | **200** |
| `sign-digest` en otra cuenta | 403 |
| `sign` (tx) en la cuenta dedicada | 403 |
| `export` de la llave | 403 |
| crear una cuenta | 403 |
| leer la cuenta dedicada | **200** |
| listar cuentas | 403 |

Y con `ethsign-signer`, el complemento: `sign` → 200, `sign-digest` → 403.

---

## 6. Conectar un consumidor real

Hoy `ethsign-credentials` está atada a una SA del namespace `openbao`, que sirve
para operar y probar. Cuando el consumidor real exista:

```bash
kubectl -n openbao exec -i $POD -- env BAO_TOKEN="$BAO_TOKEN" \
  bao write auth/kubernetes/role/ethsign-credentials \
    bound_service_account_names=ethsign-credentials,ssi-vc-digest \
    bound_service_account_namespaces=openbao,agroweb3 \
    policies=ethsign-credentials ttl=1h max_ttl=4h
```

⚠️ **`bound_service_account_names` × `bound_service_account_namespaces` es un
producto cruzado, no una lista de pares.** Con ese ejemplo, una SA llamada
`ethsign-credentials` en `agroweb3` **también** quedaría habilitada. Si necesitás
parejas exactas, hacen falta **roles separados**.

⚠️ **Nunca atar a la SA `default` de un namespace.** Todos los pods de ese
namespace la comparten: `agroweb3` corre `ssi-vc-api` y `ssi-pkd-api`, y ninguno
declara `serviceAccountName`, así que atar el rol a `agroweb3/default` le daría la
firma de digests a los dos. El consumidor necesita SA propia, lo que implica
editar su Deployment.

---

## 7. Dónde vive esto en el repo

| Qué | Dónde |
|---|---|
| `ethsign-signer`, `snapshot`, `openbao-operator` + sus roles | [`k8s/scripts/bootstrap-auth.sh`](../scripts/bootstrap-auth.sh) — idempotente |
| Plantilla de `ethsign-credentials` | [`plan-digest/policies/ethsign-digest.hcl`](../../plan-digest/policies/ethsign-digest.hcl) |
| `ethsign-credentials` + su rol | ⚠️ **solo en el cluster** — ningún script los recrea |

> Esa última fila es deuda: un re-init reconstruye tres de las cuatro políticas y
> hay que rehacer la cuarta a mano, con la address nueva. Si se automatiza, va en
> `bootstrap-auth.sh` tomando la address por variable de entorno.

---

## Ver también

- [`admin-access-recovery.md`](admin-access-recovery.md) — cómo obtener un token administrativo, y qué dejó de hacer `generate-root`
- [`plugin-update.md` §6](plugin-update.md#6-políticas-sin-esto-el-endpoint-queda-403) — por qué `sign-digest` necesita su propia política
- [`deployment.md`](deployment.md) — el despliegue paso a paso
- [`../../plan-digest/README.md`](../../plan-digest/README.md) — el contrato del endpoint `sign-digest`
