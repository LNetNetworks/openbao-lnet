# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A POC that packages [OpenBao](https://openbao.org) as a Docker image with the
[`kaleido-io/vault-plugin-secrets-ethsign`](https://github.com/kaleido-io/vault-plugin-secrets-ethsign)
Ethereum signing plugin baked in. The vault acts like a cloud HSM: secp256k1
private keys are generated/stored inside OpenBao and **never leave it**. Clients
POST unsigned transactions and get back RLP-encoded signed transactions (EIP-155
replay protection via `chainId`), or a **raw 32-byte digest** and get back
`r‖s‖v` (the `sign-digest` endpoint, added locally — see below). Apart from that
endpoint's source in [`plan-digest/plugin/`](plan-digest/README.md), this repo is
a Dockerfile, config, and helper scripts around an upstream plugin.

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
| Sign raw digest ★ | `POST` | `/accounts/<address>/sign-digest` (body `{"hash":"0x<64 hex>"}`) |

Sign payload fields: `to` (omit to deploy a contract), `data` (hex `0x…`),
`value`, `nonce` (hex string, e.g. `"0x0"`), `gas`, `gasPrice`, `chainId`
(EIP-155 — e.g. LACChain networks). Auth header on every call: `X-Vault-Token: $BAO_TOKEN`.

### ★ `sign-digest` — not upstream, live in production since 2026-08-17

Signs a **32-byte digest as-is**: no transaction wrapping, no EIP-191 prefix, no
re-hashing. Returns a recoverable, canonical low-s (EIP-2) signature —
`signature` = 65 bytes `r‖s‖v` — so `ecrecover(digest, v, r, s)` yields the
account address. Exists because `/sign` derives its own digest
(`keccak256(RLP(tx))`) and OpenBao's **Transit engine does not support
secp256k1** (NIST curves only). Use case: signing a VC's `credentialHash`.

Four things to know before touching it:

- **The plugin is a fork now.** Default build args point at
  [`LNetNetworks/vault-plugin-secrets-ethsign`](https://github.com/LNetNetworks/vault-plugin-secrets-ethsign),
  commit `236094bd56298a86364f397febd58644042256a8` — one commit over upstream
  `efdc481c…`, reachable from `master`, from branch `feat/sign-digest` and from
  the annotated tag `v0.1.0-sign-digest`. **The repo must stay public**
  (`Dockerfile` stage 1 clones without credentials) and **the tag must not be
  moved** — it is what keeps the pinned commit alive. Upstream bumps are rebased,
  then `ETHSIGN_REF` moves.
- **Byte 64 of `signature` is the raw recovery id (`0`/`1`)**, with `v_eth`
  (`27`/`28`) as a separate field — that is variant **A**
  ([`plan-digest/plugin/path_sign_digest.go`](plan-digest/plugin/path_sign_digest.go),
  the one with the Go test). The other variant, in
  [`plugin/guide-implementation-sign-digest.md`](plugin/guide-implementation-sign-digest.md),
  normalizes byte 64 to `27`/`28` instead; it is **not** what the fork ships.
  Changing this later means another image and another rollout.
- **It is more powerful than `/sign`.** A transaction hash is just
  `keccak256(RLP(tx))`, computable off-chain, so digest-signing rights ⇒ ability
  to sign any transaction. Mitigation is not optional: dedicated account with no
  balance, separate policies with cross-`deny`
  ([`plan-digest/policies/ethsign-digest.hcl`](plan-digest/policies/ethsign-digest.hcl)).
- **The `ethsign-signer` policy denies it explicitly.** `path "…/accounts/+/sign"`
  has no trailing `*`, so `sign-digest` was already denied implicitly; since
  2026-08-17 `bootstrap-auth.sh` also writes an explicit
  `path "…/accounts/+/sign-digest" { capabilities = ["deny"] }` so the protection
  no longer rests on how path matching is read. Consumers need their own policy +
  K8s auth role.

Status: **in production** since 2026-08-17, image tag `4ebe987`, deployed via a
clean redeploy ([`k8s/docs/redeploy-clean.md`](k8s/docs/redeploy-clean.md)) rather
than an in-place plugin update — the old cluster held only test accounts, so
throwing it away avoided both the `sha256` window and the `generate-root`.
Verified end-to-end against `https://vault.l-net.io` (`ecrecover` matches).

What exists in production, and what does not:

- **Dedicated account** `0x0617d688a3fe34f15d514357f54d5e1bc9cb7f8f` — for
  `credentialHash` signing, **must never hold funds**.
- **Policy `ethsign-credentials`** — scoped to that one address, with cross-`deny`
  on `/sign`, `export/*`, account creation and listing. Verified against a real
  token in seven cases. ⚠️ It lives **only in the cluster**: no script recreates
  it, so a rebuild from the repo would not restore it.
- **No K8s auth role yet** — a deliberate choice: no consumer is wired up, so the
  endpoint is reachable only with an administrative token. Wiring a consumer means
  adding a role bound to *its own* ServiceAccount, never `agroweb3/default`
  (which every pod in that namespace shares).

Where things live — [`plugin/`](plugin/guide-implementation-sign-digest.md) (how it
was built and the three problems hit locally),
[`plan-digest/`](plan-digest/README.md) (fork package: source, Go test,
`scripts/verify-sign-digest.sh`, policies),
[`k8s/docs/plugin-update.md`](k8s/docs/plugin-update.md) (changing the binary from
here on — a live cluster means the `sha256` window is back).

## Production on Kubernetes — `k8s/` (implemented)

Production runs on **GKE `lnet-privado`** (`l-net-469615`, us-central1-c),
published at **`https://vault.l-net.io`**. Everything lives under
[`k8s/`](k8s/README.md); the step-by-step is
[`k8s/docs/deployment.md`](k8s/docs/deployment.md).

Shape: OpenBao Helm chart `0.28.6` (appVersion `v2.6.1`, repo
`https://openbao.github.io/openbao-helm`) → StatefulSet of 3 Raft nodes, one
`data` + one `audit` PVC per pod, **auto-unseal via Cloud KMS**, Ingress through
the existing Kong, snapshots to GCS every 6h.

**Deploy model.** One ArgoCD `Application` with the chart + inline
`helm.valuesObject` — the same pattern as `kong.yaml` and
`kube-prometheus-stack.yaml` in `cloud-infra` (ArgoCD has no `--enable-helm`, so
Kustomize `helmCharts` is not an option). `k8s/argocd/openbao-application.yaml`
is **the only file copied** into
`cloud-infra/gitops-apps/argocd-applications/openbao.yaml`.

**Things that bite (all documented, but worth knowing here):**

- `disable_mlock = true` is **mandatory**: the chart runs as uid 100 with
  `SKIP_SETCAP=true`, so `mlock()` would fail.
- `plugin_directory = "/openbao/plugins"` must be in the HCL — the chart doesn't
  add it and `bao plugin register` fails without it.
- `storage "raft"` does **not** accept an `autopilot { }` block (only
  `autopilot_reconcile_interval`/`_update_interval`). Autopilot is set via API in
  `k8s/scripts/bootstrap-auth.sh`.
- The Ingress points at the `openbao-active` Service (`activeService: true`), not
  the round-robin one — writes only go to the Raft leader, avoiding 307s.
- Pods sit at **`0/1 Ready` until `operator init`** — expected, same as the POC
  (`bao status` exits 2).
- With KMS auto-unseal, `operator init` yields **recovery keys**, not Shamir
  unseal keys. They don't unseal; they regenerate the root token.
  **Destroying the KMS key closes the vault permanently** — recovery keys don't help.
  The live seal key is **`openbao-unseal-key-v2`** (the original
  `openbao-unseal-key` is `DISABLED` — it protects a vault that no longer exists;
  GCP does not allow deleting keys or key rings, only disabling them).
- **The builtin `gcpckms` seal is deprecated.** OpenBao 2.6.1 logs that it *"will
  be removed from the main OpenBao distribution in the next minor release"*, in
  favour of a drop-in external plugin. **A bump to 2.7 breaks auto-unseal unless
  the seal is migrated first** — check this before any chart/appVersion upgrade.
- The `root_token` stored in `openbao-prod-recovery` is **revoked**: after the
  bootstrap the token is always revoked, so that field is dead material. Getting
  an administrative token means `generate-root` with 3 of the 5 recovery keys.
- The cluster is **zonal**: 3 replicas tolerate node loss, **not zone loss**.
  Zone loss ⇒ snapshot restore, RPO up to 6h.
- CI builds the image automatically but **the tag bump is a manual job** —
  a stateful vault must not roll on every commit.
- Changing the plugin **binary** means re-registering its `sha256`. Between the
  rollout finishing and the re-register, every call to `ethereum/*` fails with
  `checksums did not match` **while the pods still report `1/1 Ready`** (readiness
  probes `bao status`, not the engine). And with the root token revoked, you need
  `generate-root` with 3 recovery keys *before* starting. See
  [`k8s/docs/plugin-update.md`](k8s/docs/plugin-update.md).

### Background docs (Spanish, the rationale)

- [`docs/storage.md`](docs/storage.md) — why **Raft** over Cloud SQL PostgreSQL.
  Key insights: the backend only stores **encrypted blobs** (what prevents key
  loss is unseal-key custody + snapshots, backend-independent); and the **RPO**
  distinction — backups do NOT contain a key created seconds ago, only live
  replication does. App-level mitigation: pre-generate a pool of addresses.
  ⚠️ Its "RPO≈0 for zone failure" claim assumes a *regional* cluster; the real
  one is zonal — corrected in-doc.
- [`docs/dr-plan.md`](docs/dr-plan.md) — was the DR plan, **now implemented**;
  header maps each part to the file that implements it.
- [`docs/throughput.md`](docs/throughput.md) — **HA ≠ throughput** (only the
  active node serves requests; add nodes for failover, not TPS) and the real
  bottleneck is **nonce coordination** — `ethsign` does NOT manage nonces, the
  client must serialize them per account. Scale vertically + shard accounts.

If asked to change the production deployment, edit under `k8s/` — never hand-edit
the copy in `cloud-infra` without syncing it back.

## HA cluster (local, for learning only)

`docker-compose.ha.yml` + `config/ha/openbao-{1,2,3}.hcl` bring up a 3-node Raft
cluster to observe quorum/join/failover — **not real HA** (single host). The
single-node POC (`docker-compose.yml`) is untouched. Bring-up order is delicate:
init ONE node, unseal all three with the **same** key (joins are auto via
`retry_join`), register the plugin once against the leader. Full procedure:
[`docs/ha-cluster.md`](docs/ha-cluster.md).

## Docs

`README.md` (English) and `docs/quickstart.md` (Spanish, based on a real POC run)
are the authoritative references **for the local POC** — keep them in sync when
changing the lifecycle, scripts, or API. `docs/CONFIGURE.md` is the reference for
all config knobs — build args (`ETHSIGN_REF` = pinned plugin commit,
`OPENBAO_VERSION`), `openbao.hcl` keys, and compose options.

For **production on Kubernetes**, the authoritative set is under `k8s/docs/`:
`deployment.md` (step by step), `unseal-keys.md` (key custody, rotation, disaster
scenarios), `kong-ingress.md` (the edge and its three gotchas), `operations.md`
(runbook: failover, restore, upgrades, scaling), `plugin-update.md` (changing the
plugin **binary** — the `sha256` window, the permissions it needs, and the
policies `sign-digest` requires), `redeploy-clean.md` (throwing the cluster away
and rebuilding it with a **new seal key** — only while no keys are worth keeping). `docs/storage.md` and
`docs/dr-plan.md` hold the rationale behind those choices.
