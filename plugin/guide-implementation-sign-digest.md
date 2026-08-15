# Guía de implementación: endpoint `sign-digest` en el plugin ethsign

Esta guía documenta cómo se agregó un endpoint **`sign-digest`** al plugin
`kaleido-io/vault-plugin-secrets-ethsign` para que OpenBao pueda firmar un **digest crudo de
32 bytes** con secp256k1 (sin envolverlo en una transacción ni aplicar prefijo EIP-191),
devolviendo la firma `r||s||v`.

## ¿Por qué hizo falta?

El cliente `client-ssi-vc` necesita firmar el `credentialHash` de una Verifiable Credential
directamente (firma cruda sobre el digest), de modo que `ecrecover(credentialHash, firma) == issuer`.

- El endpoint que ya trae el plugin (`/accounts/<addr>/sign`) firma una **transacción completa**
  (hace `keccak256(rlp(tx))` y devuelve `signed_transaction`). No sirve para firmar un hash.
- El motor **Transit** de OpenBao firma digests crudos, pero **no soporta secp256k1** (solo
  curvas NIST P-256/384/521), así que no sirve para Ethereum.

Solución: agregar un path nuevo al propio plugin ethsign (que ya custodia la llave secp256k1 y ya
usa go-ethereum) que llame directamente a `crypto.Sign(hash, privKey)`.

---

## Requisitos previos

- El repo `openbao-lnet` (este) clonado y funcionando con `docker-compose`.
- El `BAO_TOKEN` (root token) y la unseal key.

---

## Paso 1 — Clonar el plugin y posicionarse en el commit pineado

El `Dockerfile` fija el plugin al commit `efdc481c29f9eb9a04c8c47e0636bdddc98b9163`. Para que tu
cambio sea el **único** delta, parte exactamente de ese commit:

```sh
git clone https://github.com/kaleido-io/vault-plugin-secrets-ethsign.git
cd vault-plugin-secrets-ethsign
git checkout efdc481c29f9eb9a04c8c47e0636bdddc98b9163
```

> **Por qué el checkout:** tu bao actual fue compilado desde ese commit. Si te quedas en `main`
> estarías mezclando "actualizar el plugin" con "agregar el endpoint", y ante un fallo no sabrías
> cuál lo causó. Partir del commit pineado deja un solo cambio, fácil de razonar y de auditar.

---

## Paso 2 — Crear el archivo del endpoint

Crea `backend/path_sign_digest.go` con este contenido:

```go
package backend

import (
	"context"
	"fmt"

	"github.com/ethereum/go-ethereum/common/hexutil"
	"github.com/ethereum/go-ethereum/crypto"
	"github.com/hashicorp/vault/sdk/framework"
	"github.com/hashicorp/vault/sdk/logical"
)

func pathSignDigest(b *backend) *framework.Path {
	return &framework.Path{
		Pattern:      "accounts/" + framework.GenericNameRegex("name") + "/sign-digest",
		HelpSynopsis: "Sign a raw 32-byte digest (no tx wrapping, no EIP-191 prefix).",
		Fields: map[string]*framework.FieldSchema{
			"name": {Type: framework.TypeString},
			"hash": {Type: framework.TypeString, Description: "0x-prefixed 32-byte digest to sign."},
		},
		ExistenceCheck: b.pathExistenceCheck,
		Callbacks: map[logical.Operation]framework.OperationFunc{
			logical.CreateOperation: b.signDigest,
		},
	}
}

func (b *backend) signDigest(ctx context.Context, req *logical.Request, data *framework.FieldData) (*logical.Response, error) {
	from := data.Get("name").(string)

	digest, err := hexutil.Decode(data.Get("hash").(string))
	if err != nil {
		return nil, fmt.Errorf("invalid 'hash': %v", err)
	}
	if len(digest) != 32 {
		return nil, fmt.Errorf("'hash' must be exactly 32 bytes, got %d", len(digest))
	}

	account, err := b.retrieveAccount(ctx, req, from)
	if err != nil || account == nil {
		return nil, fmt.Errorf("error retrieving signing account %s", from)
	}

	privateKey, err := crypto.HexToECDSA(account.PrivateKey)
	if err != nil {
		return nil, fmt.Errorf("error reconstructing private key")
	}
	defer ZeroKey(privateKey)

	sig, err := crypto.Sign(digest, privateKey) // [R||S||V], V=0/1, low-s (EIP-2)
	if err != nil {
		return nil, err
	}
	sig[64] += 27 // normalize V to 27/28 to match ethers' serialized format

	return &logical.Response{
		Data: map[string]interface{}{"signature": hexutil.Encode(sig)},
	}, nil
}
```

**Notas del código:**
- `crypto.Sign` (go-ethereum) firma el digest de 32 bytes **tal cual**: sin prefijo EIP-191, sin
  re-hashear. Devuelve `[R||S||V]` (65 bytes) con `V = 0/1` y ya normalizada low-s (EIP-2).
- `sig[64] += 27` lleva la `V` a 27/28, que es el formato que produce
  `ethers.Signature.serialized` en el cliente (así `ecrecover` recupera el issuer).
- Reutiliza `b.retrieveAccount`, `ZeroKey` y `b.pathExistenceCheck` que ya existen en el plugin.

---

## Paso 3 — Registrar el path

En `backend/accounts.go`, en la función `paths()`, agrega `pathSignDigest(b),`:

```go
func paths(b *backend) []*framework.Path {
	return []*framework.Path{
		pathCreateAndList(b),
		pathReadAndDelete(b),
		pathSign(b),
		pathSignDigest(b),   // <-- NUEVO
		pathExport(b),
	}
}
```

---

## Paso 4 — Copiar el plugin dentro de openbao-lnet y ajustar el Dockerfile

El `COPY` de Docker solo puede leer archivos dentro de su **build context** (la carpeta
`openbao-lnet`). Copia la fuente modificada adentro:

```sh
cp -r ~/path-clone-repository-plugin/vault-plugin-secrets-ethsign \
      ~/path-repository-openbao/openbao-lnet/ethsign-src
rm -rf ~/path-repository-openbao/openbao-lnet/ethsign-src/.git   # opcional, para que no pese
```

Edita la **etapa 1** del `Dockerfile` para construir desde ese código local en vez de clonar de git.

Antes:

```dockerfile stage 1
FROM golang:1.23-alpine AS builder

RUN apk add --no-cache git

ARG ETHSIGN_REPO=https://github.com/kaleido-io/vault-plugin-secrets-ethsign.git
ARG ETHSIGN_REF=efdc481c29f9eb9a04c8c47e0636bdddc98b9163

WORKDIR /src
RUN git clone "${ETHSIGN_REPO}" . && git checkout "${ETHSIGN_REF}"

RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o /out/ethsign .
```

Después:

```dockerfile
FROM golang:1.23-alpine AS builder

WORKDIR /src
COPY ethsign-src/ .

RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o /out/ethsign .
```

La **etapa 2 no cambia** (ya hace `COPY --from=builder /out/ethsign /openbao/plugins/ethsign`).

> `CGO_ENABLED=0` es a propósito: con CGO deshabilitado, go-ethereum usa su implementación pura-Go
> de secp256k1 y produce un binario estático que corre en la imagen (musl) de OpenBao.

---

## Paso 5 — Build y arranque

```sh
cd ~/path-repository-openbao/openbao-lnet
docker-compose up -d --build
```

Si el `up` falla al recrear el contenedor (ver **Problema 1**), baja y vuelve a subir:

```sh
docker-compose down       # NO usar -v: conserva el volumen de datos openbao-data
docker-compose up -d
```

Como el contenedor es nuevo, el bao arranca **sellado**. Deséllalo:

```sh
docker-compose exec openbao bao status                          # Sealed: true
docker-compose exec openbao bao operator unseal <UNSEAL_KEY>
```

---

## Paso 6 — Re-registrar el plugin con el nuevo sha256 y recargar

El binario cambió, así que su sha256 cambió. El catálogo del bao (persistido en el volumen)
todavía tiene el sha viejo, y por eso el mount `ethereum/` no carga (ver **Problema 2**).
Re-regístralo calculando el sha **dentro del mismo shell del contenedor** para que no se
desincronice:

```sh
export BAO_TOKEN=<tu-root-token>

docker exec -e BAO_TOKEN=$BAO_TOKEN openbao-lnet sh -c \
  'bao plugin register -sha256=$(sha256sum /openbao/plugins/ethsign | cut -d" " -f1) -command=ethsign secret ethsign'
```

Verifica que el catálogo quedó con el sha completo (64 caracteres) y que coincide con el binario:

```sh
echo "BINARIO :"; docker exec openbao-lnet sha256sum /openbao/plugins/ethsign
echo "CATALOGO:"; docker exec -e BAO_TOKEN=$BAO_TOKEN openbao-lnet bao read -field=sha256 sys/plugins/catalog/secret/ethsign
```

Reinicia el contenedor para que el mount se re-monte con el sha corregido (un `reload` a veces no
revive un backend que arrancó "nil") y deséllalo de nuevo:

```sh
docker restart openbao-lnet
docker exec -T openbao-lnet bao status
docker exec -T openbao-lnet bao operator unseal <unseal-key>
```

Revisa los logs — **no** debe aparecer "checksums did not match":

```sh
docker logs --tail 30 openbao-lnet
```

---

## Paso 7 — Probar y verificar

Firma un hash de prueba (usa una cuenta que exista en tu bao):

```sh
curl -s -H "X-Vault-Token: $BAO_TOKEN" -H "Content-Type: application/json" \
  -d '{"hash":"0x8f1a036772604741d9e44b9a3a2b7e900f062873850b7fe2a5b00351e9b14f5c"}' \
  http://127.0.0.1:8200/v1/ethereum/accounts/<ADDRESS>/sign-digest
```

Debe devolver algo como:

```json
{ "data": { "signature": "0x....(65 bytes = 132 chars hex)...." } }
```

**Verificación con ethers** (`recoverAddress` debe devolver la address de la cuenta):

```js
const { ethers } = require('ethers')
const hash = '0x8f1a036772604741d9e44b9a3a2b7e900f062873850b7fe2a5b00351e9b14f5c'
const signature = '0x....'   // la firma devuelta por el bao
console.log(ethers.recoverAddress(hash, signature))  // debe ser la address de la cuenta
```

Si el `recoverAddress` coincide con la cuenta → el endpoint funciona correctamente.

---

## Problemas que tuvimos y cómo salvarlos



### Problema 1 — `KeyError: 'ContainerConfig'` al recrear el contenedor

Con `docker-compose` v1.29.2 + imágenes hechas por BuildKit, al recrear el contenedor falla con
`KeyError: 'ContainerConfig'`. La **imagen se construye bien**; el error es solo al recrear.
Solución: `docker-compose down` (sin `-v`, para conservar el volumen `openbao-data`) y luego
`docker-compose up -d`. Alternativa: forzar el modo legacy antes de reintentar:

```sh
export DOCKER_BUILDKIT=0
export COMPOSE_DOCKER_CLI_BUILD=0
```

### Problema 2 — `backend is nil` / `checksums did not match`

Tras el rebuild, `list accounts` (y cualquier ruta del mount) devolvía:

```
"no handler for route \"ethereum/accounts/\". route entry found, but backend is nil."
```

y en los logs:

```
failed to create mount entry: path=ethereum/  error= invalid backend version: checksums did not match
```

Causa: el catálogo tenía el **sha256 del binario viejo**; al no coincidir con el binario nuevo, el
bao se niega a instanciar el backend. Solución: re-registrar el plugin con el sha nuevo (Paso 6),
calculándolo dentro del mismo shell del contenedor para evitar copiados truncados, y **reiniciar**
el contenedor (no solo `reload`) para que el mount se re-monte.

### Problema 3 — El bao queda sellado tras cada recreación/reinicio

La config usa storage de archivo sin auto-unseal, así que cada `up`/`restart` deja el bao
**sealed**. Hay que desellarlo con la unseal key (`docker-compose exec openbao bao operator unseal <UNSEAL_KEY>`). Guardá la unseal
key y el root token de cuando inicializaste; sin ellos habría que re-inicializar y se perdería la
cuenta.


---

## Iteración rápida (alternativa sin rebuild)

Si solo estás iterando en el código del plugin, en vez de reconstruir la imagen podés compilar el
binario aparte e inyectarlo en el contenedor que ya corre:

```sh
# en el repo del plugin (con tus cambios)
docker run --rm -v "$PWD":/src -w /src golang:1.23-alpine \
  sh -c 'CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o ethsign .'

# inyectar en el contenedor
docker cp ethsign openbao-lnet:/openbao/plugins/ethsign
docker exec -u root openbao-lnet chmod 755 /openbao/plugins/ethsign

# re-registrar sha + reiniciar (Paso 6)
```

