# openbao-lnet

[OpenBao](https://openbao.org) packaged as a Docker image with an **Ethereum
transaction-signing plugin**, so the vault behaves like a cloud HSM: private
keys are generated and stored inside OpenBao and **never leave it** — you submit
unsigned transactions and get back signed, RLP-encoded transactions ready to
broadcast.

The signing engine is [`kaleido-io/vault-plugin-secrets-ethsign`](https://github.com/kaleido-io/vault-plugin-secrets-ethsign)
(secp256k1 / EIP-155), built from source and baked into the image.

## What's in this repo

| Path | Purpose |
|------|---------|
| `Dockerfile` | Multi-stage build: compiles the `ethsign` plugin, then bakes it into the official `openbao/openbao` image. |
| `config/openbao.hcl` | OpenBao server config (TCP listener, Raft integrated storage, `plugin_directory`). |
| `docker-compose.yml` | Brings up the server with the plugin available. |
| `scripts/register-plugin.sh` | Registers + enables the `ethsign` engine in a running, unsealed server. |
| `scripts/demo-sign.sh` | End-to-end demo: create an account and sign a transaction. |

> The plugin is compiled with `CGO_ENABLED=0`, so go-ethereum uses its pure-Go
> secp256k1 implementation and the resulting binary is fully static — it runs
> unchanged on the OpenBao image.

## Prerequisites

- Docker + Docker Compose v2
- `curl` and `python3` (used by the helper scripts / examples)

## 1. Build the image

```bash
docker compose build
# or: docker build -t openbao-lnet:latest .
```

Optional build args (defaults shown):

```bash
docker build -t openbao-lnet:latest \
  --build-arg OPENBAO_VERSION=latest \
  --build-arg ETHSIGN_REF=efdc481c29f9eb9a04c8c47e0636bdddc98b9163 \
  .
```

## 2. Start the server

```bash
docker compose up -d
docker compose logs -f openbao   # Ctrl-C to stop following
```

The API is exposed on `http://127.0.0.1:8200`.

## 3. Initialize & unseal

A fresh server is **sealed** and uninitialized. For local use:

```bash
# Initialize with a single unseal key (use more shares/threshold in production)
docker compose exec openbao bao operator init -key-shares=1 -key-threshold=1

# Copy the "Unseal Key 1" and "Initial Root Token" from the output, then:
docker compose exec openbao bao operator unseal <UNSEAL_KEY>

# Sanity check (Sealed should be false)
docker compose exec openbao bao status
```

Export the root token in your host shell for the next steps:

```bash
export BAO_TOKEN=<INITIAL_ROOT_TOKEN>
```

> ⚠️ The unseal key and root token are shown **once**. Store them safely. They
> are git-ignored if you save them in this folder.

## 4. Register & enable the Ethereum engine

```bash
BAO_TOKEN="$BAO_TOKEN" ./scripts/register-plugin.sh
```

This computes the plugin's SHA256, registers it in the catalog, and mounts the
engine at `ethereum/`. Equivalent manual commands:

```bash
SHA=$(docker compose exec -T openbao sha256sum /openbao/plugins/ethsign | awk '{print $1}')
docker compose exec -e BAO_TOKEN="$BAO_TOKEN" openbao \
  bao plugin register -sha256="$SHA" -command=ethsign secret ethsign
docker compose exec -e BAO_TOKEN="$BAO_TOKEN" openbao \
  bao secrets enable -path=ethereum ethsign
```

## 5. Create an account & sign a transaction

Quick demo:

```bash
BAO_TOKEN="$BAO_TOKEN" ./scripts/demo-sign.sh
```

Or via the HTTP API directly:

```bash
# Create a new key/account (returns its address)
curl -s -H "X-Vault-Token: $BAO_TOKEN" -d '{}' \
  http://127.0.0.1:8200/v1/ethereum/accounts

# Sign a transaction with that account
curl -s -H "X-Vault-Token: $BAO_TOKEN" -H "Content-Type: application/json" \
  -d '{
        "to": "0x9aef1bf4d1c5a261a5c5dd9c826b53e6e7c7f9d8",
        "data": "0x",
        "value": "0",
        "nonce": "0x0",
        "gas": 21000,
        "gasPrice": 0,
        "chainId": "648529"
      }' \
  http://127.0.0.1:8200/v1/ethereum/accounts/<ADDRESS>/sign
```

The response contains `signed_transaction` (RLP-encoded, ready to broadcast via
`eth_sendRawTransaction`) and `transaction_hash`.

## API reference (engine mounted at `ethereum/`)

| Operation | Method | Path |
|-----------|--------|------|
| Create account | `POST` | `/v1/ethereum/accounts` |
| Import private key | `POST` | `/v1/ethereum/accounts` (body: `{"privateKey":"0x..."}`) |
| List accounts | `LIST` | `/v1/ethereum/accounts` |
| Read account | `GET` | `/v1/ethereum/accounts/<address>` |
| Export private key | `GET` | `/v1/ethereum/export/accounts/<address>` |
| Sign transaction | `POST` | `/v1/ethereum/accounts/<address>/sign` |

**Sign payload fields:** `to` (omit to deploy a contract), `data` (hex `0x…`),
`value`, `nonce` (hex string, e.g. `"0x0"`), `gas`, `gasPrice`, and `chainId`
(for EIP-155 replay protection — e.g. LACChain networks).

## Teardown

```bash
docker compose down        # stop, keep data volume
docker compose down -v     # stop and DELETE the data volume (keys are gone!)
```

## Production notes

- **Unseal shares:** use a realistic `-key-shares` / `-key-threshold` (e.g. 5/3),
  or configure auto-unseal.
- **TLS:** this config uses `tls_disable = true` for local convenience. Enable
  TLS on the listener for any real deployment.
- **mlock:** `disable_mlock = true` is set for containers; the compose file also
  grants `IPC_LOCK`. Review per your threat model.
- **Storage:** this POC uses **Integrated Storage (Raft)** — OpenBao's
  recommended production backend, with native HA and no external database. In
  Kubernetes, run a 3/5-node StatefulSet (one PVC per pod). See
  [`docs/storage.md`](docs/storage.md) for the Raft-vs-PostgreSQL rationale.
- **Backups:** the Raft data lives in the `openbao-data` volume — back it up,
  and protect your unseal keys/root token.
- **Least privilege:** create scoped policies + tokens for signing clients
  instead of handing out the root token.
