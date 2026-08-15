# CONFIGURE — parámetros de configuración

Referencia de todos los "knobs" configurables de la imagen y el despliegue:
build args, config del servidor (`openbao.hcl`) y opciones del `docker-compose.yml`.

---

## Build args (parámetros de compilación de la imagen)

Se pasan a `docker compose build` (o `docker build --build-arg`). En el
`docker-compose.yml` tienen la forma `${VAR:-default}`: usa la variable de entorno
`VAR` si está definida; si no, el valor por defecto.

### `ETHSIGN_REF`

- **Valor por defecto:** `236094bd56298a86364f397febd58644042256a8`
  (rama `feat/sign-digest` del fork — ver `ETHSIGN_REPO` abajo)
- **Qué es:** un **hash de commit de git** (SHA-1, 40 chars hex) del repositorio
  que indique `ETHSIGN_REPO`. Es la **versión exacta del plugin de firma
  Ethereum** que se compila y se hornea en la imagen.
- **De dónde sale este commit:** es **un solo commit** encima de
  `efdc481c29f9eb9a04c8c47e0636bdddc98b9163` (el HEAD de upstream cuando se
  forkeó), que agrega el endpoint `sign-digest`. Para volver al plugin de
  upstream tal cual, poné ese `efdc481c…` — pero perdés `sign-digest`.
- **Cómo se usa:** en la etapa 1 del `Dockerfile`, el build hace literalmente:
  ```dockerfile
  RUN git clone "${ETHSIGN_REPO}" . && git checkout "${ETHSIGN_REF}"
  RUN CGO_ENABLED=0 GOOS=linux go build ... -o /out/ethsign .
  ```
  Clona el repo, hace `git checkout` de **ese commit concreto**, y compila desde ahí
  el binario `ethsign` que luego se copia a `/openbao/plugins/`.
- **Por qué un commit fijo y no `main` o una tag:** para builds **reproducibles y
  auditables**. En un componente que **firma transacciones con llaves privadas**
  quieres saber *exactamente* qué código firma. Clavar el commit garantiza:
  - Mismo código fuente → mismo binario, hoy y en 6 meses.
  - Auditabilidad: puedes revisar ese commit en GitHub.
  - Nadie mete un cambio del upstream en tu imagen sin que tú lo decidas.

  > ⚠️ **No uses una referencia móvil** (`main`, una rama, una tag mutable) para un
  > componente de firma: reconstruir podría traerte un binario distinto sin avisar.

- **Cómo cambiarlo (sin editar archivos):**
  ```bash
  ETHSIGN_REF=<otro-commit-o-tag> docker compose build
  # o:
  docker build -t openbao-lnet:latest --build-arg ETHSIGN_REF=<ref> .
  ```
- **⚠️ Efecto secundario al cambiarlo:** un `ETHSIGN_REF` distinto produce un binario
  distinto → **su SHA256 cambia**. Ese hash es el que `scripts/register-plugin.sh`
  calcula y registra en el catálogo de OpenBao, y **OpenBao valida el hash** al
  cargar el plugin. Tras reconstruir con otro ref hay que **volver a registrar/
  actualizar** el plugin para que OpenBao acepte el nuevo binario.

### `ETHSIGN_REPO`

- **Valor por defecto:** `https://github.com/LNetNetworks/vault-plugin-secrets-ethsign.git`
- **Qué es:** el repositorio del plugin a clonar. Está expuesto como build arg en
  el `Dockerfile`, en `docker-compose.yml` y en el pipeline
  ([`k8s/ci/gitlab-ci.example.yml`](../k8s/ci/gitlab-ci.example.yml)).

> **Esto es un FORK, y hay que tratarlo como tal.** El repositorio de upstream es
> [`kaleido-io/vault-plugin-secrets-ethsign`](https://github.com/kaleido-io/vault-plugin-secrets-ethsign);
> el fork de LNetNetworks existe por una sola razón: el endpoint **`sign-digest`**
> (firma de digests crudos de 32 bytes), que upstream no tiene y que no se puede
> resolver con el motor Transit de OpenBao porque no soporta secp256k1. El delta
> es **un archivo nuevo + una línea** en `backend/accounts.go`.
>
> Consecuencias prácticas:
>
> - **El repo debe ser público.** La etapa 1 del `Dockerfile` hace `git clone`
>   sin credenciales; con un repo privado, el build y el CI fallarían.
> - **Los bumps de upstream se rebasan.** Cuando salga una versión nueva del
>   plugin: `git fetch upstream && git rebase upstream/master` sobre la rama del
>   fork, `go test ./...`, y recién ahí mover `ETHSIGN_REF`.
> - **El commit pineado tiene que seguir siendo alcanzable** o el build deja de
>   encontrarlo. Hoy lo es por tres caminos —`master`, la rama
>   `feat/sign-digest` y el tag anotado `v0.1.0-sign-digest`—, así que borrar
>   una rama no rompe el build. **El tag no se toca ni se mueve.**
>
> Todo el procedimiento de despliegue del binario nuevo (incluida la ventana del
> `sha256` en producción) está en
> [`k8s/docs/plugin-update.md`](../k8s/docs/plugin-update.md).

### `OPENBAO_VERSION`

- **Valor por defecto:** `latest`
- **Qué es:** la tag de la imagen base oficial `openbao/openbao` sobre la que se
  construye (etapa 2 del `Dockerfile`, `FROM openbao/openbao:${OPENBAO_VERSION}`).
- **Cómo cambiarlo:**
  ```bash
  OPENBAO_VERSION=<tag> docker compose build
  ```
  > Para producción conviene **fijar una versión concreta** en vez de `latest`, por
  > la misma razón de reproducibilidad que `ETHSIGN_REF`.

---

## Config del servidor — `config/openbao.hcl`

Montado en el contenedor como `/openbao/config/openbao.hcl` (read-only). Ver
[`storage.md`](storage.md) para el detalle de la decisión de storage.

| Clave | Valor en la POC | Notas |
|-------|-----------------|-------|
| `storage "raft"` | `path=/openbao/file`, `node_id=openbao-lnet-1` | Integrated Storage (Raft). HA nativo. |
| `cluster_addr` | `http://127.0.0.1:8201` | **Obligatorio con Raft** (puerto de cluster). |
| `api_addr` | `http://127.0.0.1:8200` | Necesario para que el plugin hable con el server al montar. |
| `listener "tcp"` | `0.0.0.0:8200`, `tls_disable=true` | **TLS deshabilitado = solo local.** Habilitar TLS en prod. |
| `plugin_directory` | `/openbao/plugins` | Dónde vive el binario `ethsign`. No debe ser world-writable. |
| `disable_mlock` | `true` | Habitual en contenedores (el compose añade cap `IPC_LOCK`). |
| `ui` | `true` | UI web en `http://127.0.0.1:8200/ui`. |

---

## Opciones del `docker-compose.yml`

| Opción | Valor | Notas |
|--------|-------|-------|
| `ports` | `8200:8200`, `8201:8201` | API + puerto de cluster Raft (este último requerido por integrated storage). |
| `cap_add: IPC_LOCK` | — | Permite `mlock` (memoria bloqueada); complementa `disable_mlock`. |
| `environment: BAO_ADDR` | `http://127.0.0.1:8200` | Dirección que usa el CLI `bao` dentro del contenedor. |
| `volumes` (config) | `./config/openbao.hcl:/openbao/config/openbao.hcl:ro` | Config montada read-only. |
| `volumes` (datos) | `openbao-data:/openbao/file` | Volumen persistente con los datos de Raft (¡las llaves!). |
| `command` | `server -config=/openbao/config/openbao.hcl` | Arranca el server con esa config. |

### Variables de entorno del host (fuera del contenedor)

| Variable | Para qué |
|----------|----------|
| `BAO_TOKEN` | Token usado por `scripts/register-plugin.sh` y `scripts/demo-sign.sh`. |
| `OPENBAO_VERSION`, `ETHSIGN_REF` | Overrides de build (ver arriba). |

> ⚠️ **Nunca** guardes secretos (unseal keys / root token) en un archivo `.env`:
> Docker Compose lo autocarga y la línea `Unseal Key 1: ...` (con espacios) rompe
> todos los comandos `docker compose`. Usa otro nombre (p. ej. `vault-init.txt`,
> ya git-ignored). Ver README / `quickstart.md`.
