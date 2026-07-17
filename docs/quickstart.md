# Quickstart — openbao-lnet

Guía paso a paso, basada en un arranque real de la POC, para levantar OpenBao con
el plugin de firma Ethereum (`ethsign`), inicializarlo y probar la API.

> La API queda expuesta en `http://127.0.0.1:8200`. El motor de firma se monta en
> `ethereum/`.

---

## 1. Construir la imagen

```bash
cd /Users/edumar111/lnet/pocs/openbao-lnet
docker compose build
```

La primera vez tarda varios minutos: compila el plugin `ethsign` desde Go
(`CGO_ENABLED=0`, binario estático) y lo hornea en la imagen oficial `openbao/openbao`.

## 2. Levantar el servidor

```bash
docker compose up -d
docker compose ps          # STATUS debe ser "running"
```

Comprobar el estado (un vault nuevo arranca **sellado**, es lo esperado):

```bash
docker compose exec openbao bao status
```

> `bao status` devuelve `exit code 2` mientras está sellado — no es un error,
> solo indica `Sealed: true`.

## 3. Inicializar y desellar (solo la primera vez)

```bash
docker compose exec openbao bao operator init -key-shares=1 -key-threshold=1
```

De la salida, **copia y guarda** la `Unseal Key 1` y el `Initial Root Token`
(se muestran una sola vez). Luego desella y exporta el token:

```bash
docker compose exec openbao bao operator unseal <UNSEAL_KEY>
docker compose exec openbao bao status      # "Sealed" debe ser false

export BAO_TOKEN=<INITIAL_ROOT_TOKEN>
```

> ⚠️ **No guardes la salida del init en un archivo llamado `.env`.** Docker Compose
> carga automáticamente cualquier `.env` de la carpeta y lo parsea como `KEY=VALUE`;
> como la línea `Unseal Key 1: ...` tiene espacios, **todos** los comandos
> `docker compose` fallan con `key cannot contain a space`. Guarda los secretos en
> un archivo con otro nombre, p. ej. `vault-init.txt` (está en `.gitignore`).

## 4. Registrar y habilitar el motor Ethereum

```bash
BAO_TOKEN="$BAO_TOKEN" ./scripts/register-plugin.sh
```

Esto calcula el SHA256 del binario, lo registra en el catálogo y monta el motor
en `ethereum/`. Salida esperada:

```
==> Computing SHA256 of /openbao/plugins/ethsign
    sha256=<hash>
==> Registering plugin 'ethsign' in the catalog
Success! Registered plugin: ethsign
==> Enabling secrets engine at 'ethereum/'
Success! Enabled the ethsign secrets engine at: ethereum/
==> Done. Engine mounted at ethereum/
```

El plugin queda registrado de forma **persistente** (file storage): no hay que
volver a registrarlo tras un reinicio.

## 5. Demo end-to-end (crear cuenta + firmar)

```bash
BAO_TOKEN="$BAO_TOKEN" ./scripts/demo-sign.sh
```

Crea una cuenta Ethereum y firma una transacción de ejemplo. Respuesta real:

```json
{ "data": { "address": "0x07a8e4a5ce771cb40c3bf95293f64eb5a4b9557d" } }
```
```json
{ "data": {
    "signed_transaction": "0xf8628080825208949aef1bf4d1c5a261a5c5dd9c826b53e6e7c7f9d880808313cac6...",
    "transaction_hash": "0x71545cbe56d382115ed6c8e7369b2bb8388c88738eaaf08786862cff0445a8f5"
} }
```

El campo `signed_transaction` viene RLP-encoded, listo para difundir con
`eth_sendRawTransaction`.

---

## Reinicios posteriores

Tras reiniciar el contenedor el vault vuelve a quedar **sellado**. Solo hay que
**desellar** (NO re-inicializar — eso borraría las claves):

```bash
docker compose exec openbao bao operator unseal <UNSEAL_KEY>
```

El motor `ethsign` y las cuentas creadas siguen ahí (persisten en el volumen
`openbao-data`).

---

## Probar el resto de la API

Engine montado en `ethereum/`. Cabecera común:

```bash
H=(-H "X-Vault-Token: $BAO_TOKEN" -H "Content-Type: application/json")
BAO=http://127.0.0.1:8200/v1/ethereum
```

| Operación | Método | Path |
|-----------|--------|------|
| Crear cuenta | `POST` | `/v1/ethereum/accounts` |
| Importar clave privada | `POST` | `/v1/ethereum/accounts` (body `{"privateKey":"0x..."}`) |
| Listar cuentas | `LIST` | `/v1/ethereum/accounts` |
| Leer cuenta | `GET` | `/v1/ethereum/accounts/<address>` |
| Exportar clave privada | `GET` | `/v1/ethereum/export/accounts/<address>` |
| Firmar transacción | `POST` | `/v1/ethereum/accounts/<address>/sign` |

Ejemplos:

```bash
# Listar cuentas
curl -s "${H[@]}" -X LIST "$BAO/accounts"

# Leer una cuenta
curl -s "${H[@]}" "$BAO/accounts/<ADDRESS>"

# Importar una clave privada existente
curl -s "${H[@]}" -d '{"privateKey":"0x<32-bytes-hex>"}' "$BAO/accounts"

# Exportar la clave privada de una cuenta
curl -s "${H[@]}" "$BAO/export/accounts/<ADDRESS>"

# Firmar el deploy de un contrato (se omite "to")
curl -s "${H[@]}" -d '{
  "data": "0x<bytecode>",
  "value": "0",
  "nonce": "0x0",
  "gas": 500000,
  "gasPrice": 0,
  "chainId": "648529"
}' "$BAO/accounts/<ADDRESS>/sign"
```

**Campos del payload de firma:** `to` (omitir para desplegar contrato), `data`
(hex `0x…`), `value`, `nonce` (hex string, p. ej. `"0x0"`), `gas`, `gasPrice` y
`chainId` (protección anti-replay EIP-155, p. ej. redes LACChain).

### Más allá de la API

- **UI web:** `http://127.0.0.1:8200/ui` (login con el token root).
- **Difundir** la transacción firmada requiere un RPC de una red real
  (`eth_sendRawTransaction`); la POC solo firma, no envía.
- **Mínimo privilegio:** crear políticas + tokens acotados para el cliente
  firmador en vez de usar el token root.

---

## Teardown

```bash
docker compose down        # parar, conservar el volumen de datos
docker compose down -v     # parar y BORRAR el volumen (¡las claves se pierden!)
```
