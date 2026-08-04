# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A POC that packages [OpenBao](https://openbao.org) as a Docker image with the
[`kaleido-io/vault-plugin-secrets-ethsign`](https://github.com/kaleido-io/vault-plugin-secrets-ethsign)
Ethereum signing plugin baked in. The vault acts like a cloud HSM: secp256k1
private keys are generated/stored inside OpenBao and **never leave it**. Clients
POST unsigned transactions and get back RLP-encoded signed transactions (EIP-155
replay protection via `chainId`). This repo contains **no application source
code** — it is a Dockerfile, config, and helper scripts around an upstream plugin.

## Architecture

Two moving parts, connected at container build/run time:

1. **The image (`Dockerfile`)** — multi-stage. Stage 1 clones the `ethsign` repo
   at a pinned commit (`ETHSIGN_REF`) and compiles it with `CGO_ENABLED=0` so
   go-ethereum uses its pure-Go secp256k1 impl and the binary is fully static
   (runs unchanged on the musl-based OpenBao image). Stage 2 copies the binary
   into `/openbao/plugins/` — the `plugin_directory`, which must not be
   world-writable and holds an executable binary.

2. **The running server (`config/openbao.hcl` + `docker-compose.yml`)** —
   **Integrated Storage (Raft)** at `/openbao/file` (persisted in the
   `openbao-data` volume; single-node in this POC), TCP listener on `:8200` with
   TLS disabled (local only). `api_addr` **must** be set: the plugin process
   talks back to the server at mount time. Raft also **requires `cluster_addr`**
   and the cluster port `8201` exposed. Container gets `IPC_LOCK` cap and
   `disable_mlock = true`. Rationale for Raft over PostgreSQL, plus the K8s
   production shape (3/5-node StatefulSet, one PVC per pod), is in
   [`docs/storage.md`](docs/storage.md).

The plugin is registered into OpenBao's catalog and mounted as a secrets engine
at `ethereum/` **after** the server is unsealed. Registration persists in file
storage, so it survives restarts — but the server re-seals on every restart and
must be unsealed again.

## Lifecycle (order matters)

```bash
docker compose build              # compiles ethsign plugin + bakes image (slow first time)
docker compose up -d              # server starts SEALED — this is expected

# First time only — init prints unseal key + root token ONCE:
docker compose exec openbao bao operator init -key-shares=1 -key-threshold=1
docker compose exec openbao bao operator unseal <UNSEAL_KEY>
export BAO_TOKEN=<INITIAL_ROOT_TOKEN>

BAO_TOKEN="$BAO_TOKEN" ./scripts/register-plugin.sh   # register + mount engine at ethereum/
BAO_TOKEN="$BAO_TOKEN" ./scripts/demo-sign.sh         # create account + sign a tx (end-to-end check)
```

- **`bao status` returns exit code 2 while sealed** — not an error, just `Sealed: true`.
- **After any restart:** only `unseal` (NOT `init` — re-initializing wipes keys). The engine and accounts persist in the `openbao-data` volume.
- **`register-plugin.sh` is idempotent** — it skips the mount if `ethereum/` already exists.
- Override the plugin/OpenBao versions via build args: `OPENBAO_VERSION`, `ETHSIGN_REF` (both wired through `docker-compose.yml` env vars too).

## Gotchas

- **Never name the init-output file `.env`.** Docker Compose auto-loads `.env`
  and parses it as `KEY=VALUE`; the `Unseal Key 1: ...` line has spaces, which
  makes **every** `docker compose` command fail with `key cannot contain a
  space`. Save secrets to something else (e.g. `vault-init.txt`, already
  git-ignored). `.gitignore` also covers `file/`, `init.json`, `unseal-keys*.txt`, `root-token*.txt`.
- This POC only **signs** — it does not broadcast. Sending the `signed_transaction` needs a real RPC (`eth_sendRawTransaction`).
- `docker compose down -v` deletes the data volume → all keys gone.

## Engine API (mounted at `ethereum/`, base `http://127.0.0.1:8200/v1/ethereum`)

| Operation | Method | Path |
|-----------|--------|------|
| Create account | `POST` | `/accounts` (empty body `{}`) |
| Import private key | `POST` | `/accounts` (body `{"privateKey":"0x..."}`) |
| List accounts | `LIST` | `/accounts` |
| Read account | `GET` | `/accounts/<address>` |
| Export private key | `GET` | `/export/accounts/<address>` |
| Sign transaction | `POST` | `/accounts/<address>/sign` |

Sign payload fields: `to` (omit to deploy a contract), `data` (hex `0x…`),
`value`, `nonce` (hex string, e.g. `"0x0"`), `gas`, `gasPrice`, `chainId`
(EIP-155 — e.g. LACChain networks). Auth header on every call: `X-Vault-Token: $BAO_TOKEN`.

## Production & DR (planned, not implemented)

The POC runs single-node with manual Shamir unseal, but the production/Kubernetes
path is designed and documented (Spanish):

- [`docs/storage.md`](docs/storage.md) — storage backend decision: **Raft**
  (chosen) vs Cloud SQL PostgreSQL, with the durability/backup analysis. Key
  insights it establishes: the backend only stores **encrypted blobs** (what
  prevents key loss is unseal-key custody + OpenBao snapshots, backend-independent);
  and the **RPO** distinction — backups do NOT contain a key created seconds ago;
  only **live replication** (Raft quorum / Cloud SQL sync HA) does, giving RPO≈0
  for node/zone failure. App-level mitigation: pre-generate a pool of addresses.
- [`docs/dr-plan.md`](docs/dr-plan.md) — **a plan, not implemented**: auto-unseal
  with Cloud KMS + a CronJob taking `raft snapshot save` to GCS. Config blocks
  there are illustrative sketches, not deploy-ready manifests.
- [`docs/throughput.md`](docs/throughput.md) — high-volume signing. Two
  non-obvious truths: **HA ≠ throughput** (only the active node serves requests;
  add nodes for failover, not TPS) and the real bottleneck is **nonce
  coordination** — `ethsign` does NOT manage nonces, the client must serialize
  them per account. Scale vertically + shard accounts, never add cluster nodes for
  read throughput.

If asked to "set up production" or "implement DR", start from these two docs —
they hold the rationale and the intended shape (3/5-node StatefulSet, one PVC per
pod, KMS auto-unseal, snapshot CronJob).

## HA cluster (local, for learning only)

`docker-compose.ha.yml` + `config/ha/openbao-{1,2,3}.hcl` bring up a 3-node Raft
cluster to observe quorum/join/failover — **not real HA** (single host). The
single-node POC (`docker-compose.yml`) is untouched. Bring-up order is delicate:
init ONE node, unseal all three with the **same** key (joins are auto via
`retry_join`), register the plugin once against the leader. Full procedure:
[`docs/ha-cluster.md`](docs/ha-cluster.md).

## Docs

`README.md` (English) and `docs/quickstart.md` (Spanish, based on a real POC run)
are the authoritative references — keep them in sync when changing the lifecycle,
scripts, or API. `docs/storage.md` and `docs/dr-plan.md` cover the production/DR
architecture (see the section above). `docs/CONFIGURE.md` is the reference for all
config knobs — build args (`ETHSIGN_REF` = pinned plugin commit, `OPENBAO_VERSION`),
`openbao.hcl` keys, and compose options.
