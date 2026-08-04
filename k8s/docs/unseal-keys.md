# Llaves de OpenBao — generación, custodia y rotación

> Este documento es sobre el material criptográfico que abre el vault. Si algo
> de acá se pierde mal, se pierden **todas las llaves privadas de Ethereum** que
> custodia el sistema. No hay soporte al que llamar.

---

## Las tres capas de llaves

Es fácil confundirlas. Van de adentro hacia afuera:

```
   ┌─────────────────────────────────────────────────────────┐
   │  Llaves privadas secp256k1 (las que firman las tx)      │  ← lo que protegemos
   │  Viven en el storage de Raft, cifradas.                 │
   └─────────────────────────────────────────────────────────┘
                          ▲ cifradas con
   ┌─────────────────────────────────────────────────────────┐
   │  Encryption key  →  Root key (a.k.a. master key)        │
   │  Vive en el storage, cifrada.                           │
   └─────────────────────────────────────────────────────────┘
                          ▲ cifrada con
   ┌─────────────────────────────────────────────────────────┐
   │  Cloud KMS: openbao-unseal/openbao-unseal-key           │  ← el "seal"
   │  Vive en GCP. NUNCA sale de KMS.                        │
   └─────────────────────────────────────────────────────────┘

   Aparte, en paralelo:
   ┌─────────────────────────────────────────────────────────┐
   │  5 RECOVERY KEYS (umbral 3)                             │  ← acceso administrativo
   │  No desellan. Regeneran el root token.                  │
   └─────────────────────────────────────────────────────────┘
```

**Consecuencia práctica número uno:** con auto-unseal por KMS, lo que abre el
vault es la KMS key, no las recovery keys. Destruir la KMS key deja el vault
permanentemente cerrado aunque tengas las 5 recovery keys.

**Consecuencia práctica número dos:** el backend de almacenamiento solo guarda
blobs cifrados. Un backup de los PVCs, o de una base de datos, no expone nada —
y tampoco sirve de nada sin la KMS key. Esto es lo que ya explicaba
[`../../docs/storage.md`](../../docs/storage.md) y sigue valiendo igual acá.

---

## Generación (una sola vez)

```bash
./k8s/scripts/init-openbao.sh
```

que por dentro corre, sobre `openbao-0`:

```bash
bao operator init -recovery-shares=5 -recovery-threshold=3 -format=json
```

Salida:

```json
{
  "unseal_keys_b64": [],
  "unseal_keys_hex": [],
  "unseal_shares": 1,
  "unseal_threshold": 1,
  "recovery_keys_b64": ["...", "...", "...", "...", "..."],
  "recovery_keys_hex": ["...", "...", "...", "...", "..."],
  "recovery_keys_shares": 5,
  "recovery_keys_threshold": 3,
  "root_token": "s.XXXXXXXXXXXXXXXXXXXX"
}
```

`unseal_keys_*` viene **vacío**: no hay Shamir, el seal es KMS.

### Por qué 5 shares con umbral 3

- 5 custodios → nadie es indispensable, y se puede perder a dos personas
  (vacaciones, salida de la empresa) sin quedarse sin acceso.
- Umbral 3 → hacen falta tres personas coordinadas para regenerar un root token.
  Ninguna sola puede hacerlo.
- Con 3/5 se tolera perder 2 shares. Con 2/3 solo se tolera perder 1.

Para ajustar: `RECOVERY_SHARES=7 RECOVERY_THRESHOLD=4 ./k8s/scripts/init-openbao.sh`.

---

## Custodia

### Lo que hace el script automáticamente

Guarda el JSON completo en GCP Secret Manager, secret `openbao-prod-recovery`,
pasándolo por stdin (`--data-file=-`) para que no toque el disco.

```bash
gcloud secrets versions access latest \
  --secret=openbao-prod-recovery --project=l-net-469615 | jq
```

**Esa copia no es la custodia.** Es una red de seguridad operativa. Quien tenga
`roles/secretmanager.secretAccessor` sobre ese secret tiene los 5 shares de una
sola vez, o sea el umbral de 3 no lo protege de nada. Restringir el acceso:

```bash
gcloud secrets get-iam-policy openbao-prod-recovery --project=l-net-469615
```

Debería ser una lista muy corta de humanos, y **ninguna** service account de
aplicación.

### Lo que hay que hacer a mano

1. Repartir los 5 shares (`recovery_keys_b64[0..4]`) entre **5 personas
   distintas**, un share por persona.
2. Cada custodio lo guarda en su **gestor de contraseñas personal** (1Password,
   Bitwarden). No en un vault compartido del equipo — eso reagrupa los shares y
   anula el esquema.
3. Registrar **quién tiene qué share** (solo el índice, nunca el valor) en un
   documento accesible al equipo de infra.
4. Nunca: Slack, Mattermost, email, un archivo del repo, un ticket, una captura
   de pantalla.
5. **Nunca llamar `.env` a un archivo con este material.** Docker Compose
   autocarga `.env` y lo parsea como `KEY=VALUE`; las líneas con espacios hacen
   fallar *todos* los comandos `docker compose` con `key cannot contain a space`.
   Es el mismo gotcha que documenta el `CLAUDE.md` del POC.

### Rotación de custodios

Cuando alguien deja el equipo, **no** alcanza con quitarle el acceso: ya vio su
share. Hay que rehacer el reparto entero:

```bash
kubectl -n openbao exec -it openbao-0 -- bao operator rekey-recovery-key -init \
  -target=recovery -key-shares=5 -key-threshold=3

# Aportar 3 shares de los ACTUALES:
kubectl -n openbao exec -it openbao-0 -- bao operator rekey-recovery-key -target=recovery <share>
# (x3 → devuelve los 5 shares NUEVOS)
```

Los shares viejos dejan de servir. Actualizar también el secret de GSM.

---

## El root token

`operator init` devuelve un `root_token` sin TTL y con todos los permisos. Es la
peor deuda de seguridad posible si se deja vivo.

**Se usa para**: los pasos 7 y 9 del despliegue (registrar el plugin, bootstrap
de auth). Nada más.

**Después, se revoca:**

```bash
kubectl -n openbao exec -i openbao-0 -- \
  env BAO_TOKEN=$BAO_TOKEN bao token revoke -self
```

### Regenerarlo cuando haga falta

Requiere 3 de las 5 recovery keys y una coordinación deliberada — que es
exactamente el punto.

```bash
POD=$(kubectl -n openbao get pods -l openbao-active=true -o jsonpath='{.items[0].metadata.name}')

# 1. Iniciar. Devuelve un OTP y un nonce.
kubectl -n openbao exec -it $POD -- bao operator generate-root -init
#   Nonce: 1a2b3c...
#   OTP:   XYZ...

# 2. Cada custodio aporta su share (3 veces, con el mismo nonce)
kubectl -n openbao exec -it $POD -- bao operator generate-root -nonce=<nonce>
#   → pega el share cuando lo pida
#   Tras el tercero devuelve: Encoded Token: <blob>

# 3. Decodificar con el OTP
kubectl -n openbao exec -it $POD -- \
  bao operator generate-root -decode=<blob> -otp=<OTP>
#   → el root token nuevo
```

Volver a revocarlo al terminar.

---

## Alternativa: unseal Shamir (sin KMS)

Es lo que hace el POC. **No se eligió para producción**, pero se documenta por
si alguna vez no se puede usar KMS (auditoría que exija que ninguna llave viva
en un cloud provider, corte de KMS, etc.).

### Cómo se vería

Quitar el bloque `seal "gcpckms"` del HCL en
`k8s/argocd/openbao-application.yaml`. `operator init` pasa a devolver unseal
keys de verdad:

```bash
bao operator init -key-shares=5 -key-threshold=3
```

Y tras **cada** arranque de **cada** pod:

```bash
kubectl -n openbao exec -it openbao-0 -- bao operator unseal <share-1>
kubectl -n openbao exec -it openbao-0 -- bao operator unseal <share-2>
kubectl -n openbao exec -it openbao-0 -- bao operator unseal <share-3>
# ... y lo mismo para openbao-1 y openbao-2
```

### Por qué no

En Kubernetes los pods reinician solos: rollouts, evictions por presión de
memoria, upgrades del node pool, reschedules del autoscaler, actualizaciones de
GKE en el release channel REGULAR. Cada uno de esos eventos, con Shamir,
significa:

- juntar a 3 custodios,
- correr 9 comandos (3 shares × 3 pods),
- mientras tanto el vault está caído o en quórum degradado.

Un upgrade de GKE a las 3 de la mañana tumbaría el servicio de firma hasta que
alguien se despierte. **Ese es el argumento entero.** El auto-unseal no es una
comodidad: es lo que hace viable operar un vault en un scheduler que puede mover
pods cuando quiera.

### Migrar entre seals

Si alguna vez hay que pasar de KMS a Shamir o al revés, hay un procedimiento de
migración (`-migrate`) que requiere el umbral de recovery/unseal keys y parar el
cluster. Está fuera de alcance acá — documentarlo cuando se necesite.

---

## Escenarios de desastre

| Se pierde | ¿El vault sigue vivo? | Recuperación |
|---|---|---|
| Un pod | Sí (quórum 2/3) | Automática: el StatefulSet lo recrea, hace `retry_join` y se desella con KMS |
| Dos pods | No (sin quórum) | Vuelven solos al recrearse; si sus PVCs se perdieron, restore de snapshot |
| Los 3 PVCs | No | `raft snapshot restore` desde GCS sobre un cluster nuevo |
| La zona `us-central1-c` | No | El cluster es **zonal**: hay que levantar en otra zona y restaurar el snapshot. RPO = hasta 6h |
| 3 recovery keys | Sí, sigue operando | No se puede regenerar el root token. Rehacer el rekey **antes** de llegar a ese punto |
| **La KMS key** | Sí hasta el próximo restart, después **no abre nunca más** | **Ninguna.** Por eso la key tiene `prevent_destroy` en Terraform y rotación (no destrucción) de versiones |

La última fila es la razón por la que
[`k8s/gcp/terraform.tf.example`](../gcp/terraform.tf.example) pone
`prevent_destroy = true` en la crypto key y en el key ring, y por la que el
GSA solo tiene `cryptoKeyEncrypterDecrypter` y nunca `cloudkms.admin`.

---

## Ver también

- [`deployment.md`](deployment.md) — dónde encaja cada paso.
- [`operations.md`](operations.md) — restore desde snapshot, paso a paso.
- [`../../docs/storage.md`](../../docs/storage.md) — por qué el backend solo
  guarda blobs cifrados y qué es lo que realmente previene la pérdida de llaves.
