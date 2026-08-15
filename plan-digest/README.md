# Plan: firmar digests crudos (32 bytes) con el bao

> **Estado (2026-08-14): el fork YA EXISTE.** El código de esta carpeta está
> mergeado en
> [`LNetNetworks/vault-plugin-secrets-ethsign@236094bd`](https://github.com/LNetNetworks/vault-plugin-secrets-ethsign/tree/feat/sign-digest)
> (rama `feat/sign-digest`, un commit sobre el `efdc481c…` de upstream), con
> `go build` y la suite completa en verde, y es el **default** de
> `Dockerfile`/`docker-compose.yml`/CI. Lo que falta es el **despliegue a
> producción**: hoy GKE sigue corriendo el binario de upstream. Procedimiento en
> [`../k8s/docs/plugin-update.md`](../k8s/docs/plugin-update.md) — o, si el
> cluster no está en uso, [`../k8s/docs/redeploy-clean.md`](../k8s/docs/redeploy-clean.md).
>
> Esta carpeta se conserva como **fuente del delta**: si hay que rehacer el fork
> o rebasarlo sobre un upstream nuevo, se parte de acá.
>
> Fecha del análisis: 2026-08-12. Verificado contra el plugin en el commit que
> hoy corre en producción: `ETHSIGN_REF=efdc481c29f9eb9a04c8c47e0636bdddc98b9163`
> (`Dockerfile:19`) e imagen `openbao-ethsign:3fd9333`
> (`k8s/argocd/openbao-application.yaml:72`).
>
> El código de `plugin/` **ya se compiló y probó** sobre un clone de ese commit
> exacto: `paths.patch` aplica limpio, y `go test ./...` pasa en verde — los dos
> tests nuevos más toda la suite upstream (go 1.21.10). Lo que queda por hacer
> es el fork, el build de la imagen y el despliegue, no escribir el endpoint.

## El pedido

Firmar un **digest crudo de 32 bytes** (un `credentialHash`) con la clave
secp256k1 que vive dentro del bao, y recibir la firma **recuperable** `r, s, v`:

- el hash se firma **tal cual**, sin envolverlo en una transacción,
- **sin** prefijo EIP-191 (`"\x19Ethereum Signed Message:\n32"`),
- **sin** re-hashear,
- **low-s** (EIP-2), con recovery id,
- de modo que `ecrecover(hash, v, r, s) == 0x67c64…` (la address de la cuenta).

Firmar transacciones ya funciona hoy con `POST /ethereum/accounts/<addr>/sign`.
Esto es lo que falta.

## Hallazgo: el plugin no tiene ese endpoint

El plugin `kaleido-io/vault-plugin-secrets-ethsign` expone exactamente cuatro
rutas — no hay ninguna para digests crudos:

| Archivo (upstream) | Pattern | Operaciones |
|---|---|---|
| `backend/path_create_list.go` | `accounts/?` | `LIST`, `POST` (crear/importar) |
| `backend/path_read_delete.go` | `accounts/<name>` | `GET`, `DELETE` |
| `backend/path_sign.go` | `accounts/<name>/sign` | `POST` — **solo transacciones** |
| `backend/path_export.go` | `export/accounts/<name>` | `GET` |

`/sign` **no se puede reusar**: recibe `to/data/value/nonce/gas/gasPrice/chainId`,
arma un `types.Transaction` y firma `keccak256(RLP(tx))` vía `types.SignTx`
(`backend/accounts.go:271-279`). El digest lo deriva él; no hay forma de
inyectar un hash arbitrario. Y devuelve `transaction_hash` +
`signed_transaction` (RLP), nunca `r/s/v` sueltos.

**El transit engine de OpenBao tampoco sirve** como plan B: solo soporta
`ecdsa-p256/p384/p521` (curvas NIST) — no secp256k1 (verificado en
`sdk/helper/keysutil/policy.go` de `openbao/openbao@main`) — y además devuelve
DER sin recovery id.

## Decisión: forkear el plugin y agregar `sign-digest`

Es el único camino que **no saca la clave privada del vault**, y es chico: un
archivo nuevo de ~110 líneas más una línea en `paths()`. El `Dockerfile` ya
compila el plugin desde fuente en la stage 1, así que encaja en el pipeline
actual sin cambios estructurales.

**Alternativa descartada:** `GET /export/accounts/<addr>` y firmar en el
cliente. Funciona hoy sin tocar nada, y rompe el único motivo por el que existe
el bao — la clave sale. Solo aceptable como prueba de 5 minutos en local, nunca
en producción.

### Contrato del endpoint

```
POST /v1/ethereum/accounts/<address>/sign-digest
X-Vault-Token: <token>

{"hash": "0x<64 hex = 32 bytes>"}     # alias aceptado: "digest"
```

Respuesta (`.data`):

| Campo | Ejemplo | Nota |
|---|---|---|
| `address` | `0x67c64…` | la cuenta que firmó |
| `hash` | `0x1111…` | el digest normalizado, como se firmó |
| `signature` | `0x…` | 65 bytes: `r(32) ‖ s(32) ‖ v(1)`, con `v ∈ {00,01}` |
| `r` | `0x…` | 32 bytes |
| `s` | `0x…` | 32 bytes, **low-s** garantizada |
| `v` | `0` o `1` | recovery id crudo |
| `v_eth` | `27` o `28` | lo que espera `ecrecover` de Solidity |

Errores: falta `hash`, hex inválido, largo distinto de 32 bytes, o cuenta
inexistente.

**Por qué cumple los requisitos:** `crypto.Sign(digest, key)` de go-ethereum
firma el digest sin tocarlo (el prefijo EIP-191 lo aplicaría
`accounts.TextHash`, que no se usa), devuelve `V ∈ {0,1}` y emite firma
canónica low-s. Con `CGO_ENABLED=0` (`Dockerfile:24`) se usa la implementación
pura-Go de secp256k1 (btcec), que también es low-s canónica — el test lo
verifica explícitamente.

## Contenido de esta carpeta

| Archivo | Qué es |
|---|---|
| `plugin/path_sign_digest.go` | El endpoint. Copiar a `backend/path_sign_digest.go` en el fork. |
| `plugin/paths.patch` | Registra `pathSignDigest(b)` en `paths()` (`backend/accounts.go:47`). |
| `plugin/path_sign_digest_test.go` | Test Go: `ecrecover` == address, low-s, y que **no** haya prefijo EIP-191 ni re-hash. Es la verificación que vale. |
| `scripts/verify-sign-digest.sh` | Smoke test HTTP end-to-end contra un bao corriendo (local o GKE). |
| `policies/ethsign-digest.hcl` | ACLs de ejemplo para separar firma-de-digests de firma-de-transacciones (ver Seguridad). |

## Seguridad: leer antes de mergear

Un endpoint que firma digests arbitrarios **es más poderoso que `/sign`**. El
hash de una transacción no es más que `keccak256(RLP(tx))`, calculable
off-chain: quien tenga un token con acceso a `sign-digest` puede pedir la firma
de ese hash y ensamblar una transacción válida que mueva fondos, saltándose
cualquier restricción que hoy dependa de que el bao sea el que construye la tx.

Mitigación (no opcional):

1. **Cuenta dedicada** para `credentialHash`, sin saldo, distinta de las que
   firman transacciones on-chain.
2. **Policies separadas**, con `deny` explícito cruzado — ver
   `policies/ethsign-digest.hcl`.
3. El audit device ya está habilitado de forma declarativa, así que cada llamada
   a `sign-digest` queda registrada; vale la pena revisar/alertar sobre ese path.

## Pasos de implementación

1. ~~**Fork** de `kaleido-io/vault-plugin-secrets-ethsign`~~ — **hecho**:
   `LNetNetworks/vault-plugin-secrets-ethsign`, rama `feat/sign-digest` desde el
   commit pineado `efdc481c…` (no desde `master`, para que el único delta sea
   este endpoint).
2. Copiar `plugin/path_sign_digest.go` → `backend/path_sign_digest.go`,
   `plugin/path_sign_digest_test.go` → `backend/path_sign_digest_test.go`, y
   `git apply plugin/paths.patch`.
3. `go build ./... && go test ./...` — ya se validó así en un clone temporal del
   commit pineado (suite completa en verde, ~24s), así que acá debería ser un
   trámite. (`go.mod` del plugin: go-ethereum `v1.10.17`, `go 1.16`; probado con
   go 1.21.10.)
4. **Probar en local con el POC** antes de tocar GKE:
   ```bash
   ETHSIGN_REPO=https://github.com/LNetNetworks/vault-plugin-secrets-ethsign.git \
   ETHSIGN_REF=<sha del fork> docker compose build
   docker compose up -d
   # unseal, ./scripts/register-plugin.sh, y:
   BAO_TOKEN=$BAO_TOKEN ./plan-digest/scripts/verify-sign-digest.sh
   ```
   `docker-compose.yml` ya pasa `ETHSIGN_REF` como build arg; hay que agregar
   `ETHSIGN_REPO` de la misma forma (o pinchar el default en `Dockerfile:17`).
5. **Producción (GKE).** El binario del plugin cambia, así que hay dos cosas que
   no se pueden olvidar:
   - Build de imagen + **bump manual** del tag en
     `.spec.source.helm.valuesObject.server.image.tag`
     (`k8s/argocd/openbao-application.yaml:72`, job manual `bump-image-tag` —
     un vault con estado no rota en cada commit).
   - **Re-registrar el plugin**: el `sha256` registrado en el catálogo tiene que
     coincidir con el del binario nuevo, si no OpenBao se niega a ejecutarlo.
     `k8s/scripts/register-plugin.sh` es idempotente y recalcula el sha; como el
     engine ya está montado, después hay que recargar:
     ```bash
     BAO_TOKEN=<root> ./k8s/scripts/register-plugin.sh
     kubectl -n openbao exec <pod-activo> -- bao plugin reload -plugin ethsign
     ```
   - Verificar: `BAO_ADDR=https://vault.l-net.io BAO_TOKEN=<token> \
     ./plan-digest/scripts/verify-sign-digest.sh`
6. **Docs a actualizar cuando esto se implemente** (hoy no mencionan
   `sign-digest`, a propósito): la tabla "Engine API" de `CLAUDE.md`,
   `README.md`, `docs/quickstart.md`, `docs/CONFIGURE.md` (el nuevo
   `ETHSIGN_REPO`) y `k8s/docs/operations.md` (el procedimiento de
   re-registro + reload al cambiar el binario).

## Riesgos y cosas a tener en cuenta

- **Se sale del upstream.** A partir de acá el plugin es un fork: los bumps de
  `ETHSIGN_REF` hay que rebasarlos. El delta es de un archivo, así que es
  manejable, pero conviene dejarlo escrito en `docs/CONFIGURE.md`.
- **Registro por `sha256`.** Si se despliega la imagen nueva y se olvida el
  re-registro, el engine `ethereum/` deja de arrancar el plugin (los pods siguen
  vivos pero toda llamada a `ethereum/*` falla). El orden correcto es: imagen →
  rollout → `register-plugin.sh` → `plugin reload`.
- **Ninguna clave se toca.** Las cuentas viven en Raft y el cambio es solo de
  código del plugin; no hay migración de datos ni riesgo para las claves
  existentes.
- **Nonces**: no aplica acá (esto no emite transacciones), pero sigue valiendo lo
  de `docs/throughput.md` para el flujo de `/sign`.
