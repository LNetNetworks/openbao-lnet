# Storage backend — decisión de arquitectura

> Dónde y cómo OpenBao guarda las llaves de firma Ethereum. Ruta: Docker hoy →
> Kubernetes (GKE) en producción. Este doc cubre **dos ejes distintos**:
> confidencialidad (cifrado) y **durabilidad/respaldo** (que no se pierdan).
>
> **Estado: la ruta recomendada acá (Raft + snapshots a GCS) ya está
> implementada** en [`../k8s/`](../k8s/README.md) — 3 nodos Raft en GKE con
> auto-unseal por Cloud KMS. Este doc conserva el análisis que llevó a esa
> decisión. Ojo con el matiz de zona en la sección de RPO.

## TL;DR

- **Esta POC usa Integrated Storage (Raft)** — ver `config/openbao.hcl`.
- Para producción hay **dos rutas defendibles**: **Raft + snapshots a GCS**
  (recomendada) o **Cloud SQL (PostgreSQL) como backend**. La tabla de durabilidad
  más abajo explica el trade-off real.
- **Lo que de verdad protege contra pérdida de llaves no es el backend**, sino:
  (1) custodiar las *unseal keys* / root key, y (2) tener snapshots de OpenBao.
  Eso hay que resolverlo **igual con cualquiera de las dos rutas**.

---

## Dos preguntas que no hay que confundir

| | Confidencialidad | Durabilidad / respaldo |
|---|---|---|
| Pregunta | ¿Alguien puede leer las llaves? | ¿Puedo perder las llaves? |
| Respuesta | El **barrier** de OpenBao cifra todo antes de escribir. El storage **nunca** ve las llaves en claro. Esto es igual en Raft y en Postgres. | Depende de replicación + backups. Aquí sí hay trade-off entre backends. |

Conclusión del eje confidencialidad: **el backend no cambia la seguridad de
lectura**. Postgres no es "más seguro" para leer; de hecho añade superficie de
ataque (otra credencial, otra red, más hardening). El debate real es durabilidad.

---

## Mito a aclarar: un PVC en GKE no es un "volumen frágil"

Un PersistentVolumeClaim en GKE **no** es un disco local pegado a un nodo. Detrás
hay un **Persistent Disk de Google Cloud**, almacenamiento de red con durabilidad
propia:

- **PD zonal**: replicado dentro de la zona.
- **PD regional**: replicado en **dos zonas** (sobrevive la caída de una zona).

Si un pod muere o se reprograma, el PD se re-adjunta con los datos intactos (no es
un `emptyDir` efímero). Es **la misma clase de disco sobre la que Cloud SQL corre
por debajo**. Con Raft de 3/5 nodos, encima, los datos quedan replicados a nivel
de aplicación en 3/5 PDs distintos.

---

## Ruta A — Integrated Storage (Raft) + snapshots a GCS  ✅ recomendada

Backend nativo de OpenBao. HA sin base de datos externa. El respaldo se hace con
tooling nativo (no artesanal):

```bash
# Snapshot consistente de TODO el estado de OpenBao
bao operator raft snapshot save openbao-$(date +%F).snap
# Restore
bao operator raft snapshot restore openbao-2026-07-24.snap
```

Patrón de producción: un **CronJob de Kubernetes** que ejecuta `snapshot save` y
sube el archivo a un **bucket de GCS** con versionado + retención (GCS ≈ 11 nueves
de durabilidad). Son ~30 líneas de YAML, una sola vez.

**Config (ya aplicada en esta POC, un nodo):**

```hcl
storage "raft" {
  path    = "/openbao/file"
  node_id = "openbao-lnet-1"
}

api_addr     = "http://127.0.0.1:8200"
cluster_addr = "http://127.0.0.1:8201"   # requerido por Raft
```

- **`cluster_addr` es obligatorio** con Raft (no lo era con `file`).
- Exponer el **puerto 8201** en `docker-compose.yml` (puerto de cluster Raft).
- Los datos persisten en el volumen `openbao-data` montado en `/openbao/file`.
- En K8s: **StatefulSet de 3/5 nodos, un PVC por pod** (usar **PD regional** para
  tolerancia multi-zona).

### ¿Cuántos nodos? Raft ≠ obligatoriamente 3

Confusión habitual: "Raft necesita 3 instancias". **No.** Hay que separar dos cosas:

- **Raft como backend de storage** → funciona con **1 nodo**. Es un backend válido
  en solitario; simplemente no hay a quién replicar. **Es lo que usa esta POC en
  Docker** (`node_id = "openbao-lnet-1"`, un solo servicio) — no hay que cambiar
  nada.
- **Raft como mecanismo de HA/quórum** → ahí es donde entran los 3/5 nodos.

El número de nodos es una decisión de **disponibilidad**, no un requisito del
backend.

#### Por qué números impares (3, 5) para HA

Raft necesita **mayoría (quórum)** para confirmar escrituras y elegir líder.
Tolerancia = `(N-1)/2`:

| Nodos | Quórum | Tolera caídas | Comentario |
|-------|--------|---------------|------------|
| 1 | 1 | 0 | POC / dev. Sin HA. Solo sobrevive a reinicio del proceso, no a pérdida de volumen. |
| 2 | 2 | 0 | ❌ **Peor que 1**: si cae uno, se pierde quórum. No se usa. |
| **3** | 2 | **1** | Mínimo real para HA. |
| 5 | 3 | 2 | Mayor tolerancia (multi-zona). |

Por eso siempre son impares: 2 no aporta tolerancia y 4 no aporta más que 3.

> **Multi-nodo en un solo host Docker no da HA real:** aunque se puede levantar un
> cluster de 3 con `retry_join` en Compose, si el host muere caen los 3. La HA de
> verdad exige nodos en máquinas/zonas distintas → eso lo da Kubernetes
> (StatefulSet + PD regional). En Docker local, **quédate con 1 nodo**.
>
> Para *probar/ver* el quórum y el failover en local hay un cluster de 3 nodos en
> `docker-compose.ha.yml` — procedimiento en [`ha-cluster.md`](ha-cluster.md).

---

## Ruta B — Cloud SQL (PostgreSQL) como backend

Se apunta OpenBao a una instancia de Cloud SQL. Ventaja principal: **Google
gestiona los backups** (automáticos diarios + *point-in-time recovery* + retención)
sin que construyas nada.

```hcl
storage "postgresql" {
  connection_url = "postgres://USER:PASS@HOST:5432/openbao?sslmode=require"
  table          = "openbao_kv_store"
  ha_enabled     = "true"          # requiere tabla de locks (ha_table)
  ha_table       = "openbao_ha_locks"
}
```

Notas de despliegue:

- Conectar preferentemente vía **Cloud SQL Auth Proxy** / conector con **IAM**, no
  con contraseña plana en el `connection_url`. Esa credencial es otra pieza a
  proteger y rotar.
- HA de OpenBao con Postgres depende de que **Cloud SQL** tenga HA activado
  (instancia regional). Es HA de la base, no de OpenBao en sí.
- Más saltos de red y gestión de conexiones que Raft (local al proceso).

---

## Comparación honesta — enfocada en durabilidad/respaldo

| | Raft + snapshots a GCS | Cloud SQL como backend |
|---|---|---|
| Durabilidad datos vivos | 3/5 PDs replicados (regional = multi-zona) | PD de Cloud SQL (+ réplica si HA activado) |
| Backups | CronJob → GCS (lo montas 1 vez) | Automáticos + PITR, **gestionados por Google** ✅ |
| Esfuerzo de backup | Bajo, pero tuyo | Cero, de Google |
| Piezas a operar/asegurar | Solo OpenBao | OpenBao **+** Cloud SQL (red, credencial, IAM) |
| Recomendado oficialmente | ✅ Sí, default | Viable, no el default |
| ¿Evita custodiar unseal keys? | **No** | **No** |
| ¿Restore fiable de OpenBao? | Sí (mecanismo nativo) | Requiere snapshot lógico igual |

### El punto que iguala la balanza

**Elijas el backend que elijas, necesitas snapshots de OpenBao para DR**, porque:

- Un backup de Cloud SQL contiene **blobs cifrados**. Para restaurarlos necesitas
  **también las unseal keys / root key**. Sin ellas, el dump de Postgres es
  ilegible.
- Un PITR de Postgres puede dejar a OpenBao en estado inconsistente; el mecanismo
  pensado para recuperar OpenBao es su **propio snapshot**, no un dump de la base.

O sea: Postgres **no te ahorra** custodiar las unseal keys ni tener un plan de
restore de OpenBao. Solo mueve *dónde* viven los bytes cifrados.

---

## Por qué el backend no cubre el DR real (en detalle)

El backend (Raft o Postgres) solo guarda **bytes cifrados**. El trabajo que de
verdad decide si recuperas tus llaves o las pierdes para siempre vive **fuera** del
backend, y es el mismo elijas el que elijas.

### Qué hay realmente guardado en el storage

Cuando OpenBao escribe, escribe blobs cifrados. La cadena de cifrado es:

```
tus llaves Ethereum
   └─ cifradas por la  Encryption Key  (uso diario del barrier)
        └─ cifrada por la  Root Key (master key)
             └─ cifrada/partida por las  Unseal Keys (Shamir)
```

El backend **nunca** ve nada de esto en claro. Consecuencia clave: **un backup del
storage (dump de Postgres o `raft snapshot`) es inútil por sí solo** — es un bloque
cifrado. Para volverlo llaves usables necesitas lo que **no vive en el storage**:
las unseal keys.

### Ingrediente 1 — Custodia de las unseal keys / root key

Decide si un backup se puede **descifrar**.

- Se generan **una sola vez** en `bao operator init` y **no se guardan en el
  storage**: se muestran por pantalla y desaparecen.
- Sin ellas OpenBao arranca **sellado** y no descifra nada. Un servidor sellado con
  todos los datos intactos es un ladrillo.

**Escenario de pérdida real:** Cloud SQL con backups perfectos de Google, PITR,
todo. Pierdes las unseal keys (se fueron con quien hizo el `init`, o estaban en un
`.txt` borrado). Resultado: backup impecable lleno de blobs que **nadie puede
descifrar jamás**. Las llaves se pierden — no por fallo de disco, sino por perder
la clave de descifrado.

Postgres **no** ayuda aquí: no guarda esas llaves, no puede. Lo que sí resuelve el
problema (trabajo tuyo, independiente del backend):

- Shamir realista (**5/3**, no 1/1 como en la POC).
- Guardar los shares en gestor de secretos externo / hardware / sobres físicos.
- En producción: **auto-unseal con Cloud KMS**, para que la root key la custodie el
  KMS de Google y no dependas de humanos con `.txt`.

### Ingrediente 2 — Restore de OpenBao (consistencia lógica)

Decide si un backup se puede **restaurar coherentemente**.

- **`raft snapshot save`** captura un punto **lógicamente consistente** de todo el
  estado (Raft garantiza atomicidad vía su log de consenso). Restore = un comando →
  estado coherente conocido.
- Un **backup / PITR de Postgres** captura la base a nivel de filas/páginas. Puede
  caer en mitad de una operación multi-clave de OpenBao y dejar un estado
  **parcialmente escrito** que OpenBao no espera. Postgres sabe restaurar
  *Postgres*, no sabe qué es "un estado válido de OpenBao".

Por eso, **incluso con Postgres como backend, la guía sigue siendo tomar snapshots
de OpenBao** para DR. Y si los vas a tomar igual... ya estás haciendo el trabajo que
"te ahorraba" Postgres.

### Los dos ingredientes juntos

Un DR de verdad necesita **ambos**, y el backend no aporta ninguno:

| Ingrediente | ¿Dónde vive? | ¿Lo da el backend? | Si falta |
|---|---|---|---|
| Snapshot del estado (blobs cifrados) | Raft snapshot o dump de Postgres | Parcial (Postgres, con riesgo de inconsistencia) | Pierdes los datos |
| Unseal keys / root key | **Fuera del storage** (tu custodia / KMS) | **No, ninguno** | Tienes los datos pero **no puedes descifrarlos** |

Para restaurar necesitas **los dos a la vez**. Postgres, en el mejor caso, mejora
un poco el primero (backups gestionados) pero **no toca el segundo** —el punto donde
de verdad se pierden las llaves— y ni siquiera cubre bien el primero para DR.

**El trabajo que salva tus llaves:** auto-unseal / custodia robusta de unseal keys
**+** snapshots regulares de OpenBao a un sitio durable (GCS). Ese trabajo es igual
con Raft o Postgres; una vez hecho, la ventaja de backups gestionados de Cloud SQL
se vuelve marginal.

> Cómo montar exactamente estos dos ingredientes (CronJob de snapshots a GCS +
> auto-unseal con Cloud KMS) está esbozado, como plan, en
> [`dr-plan.md`](dr-plan.md). Para el eje de **alto volumen de firma** (throughput,
> nonce, sharding) ver [`throughput.md`](throughput.md).

---

## RPO: recuperar la última llave generada

Escenario concreto: **genero una llave Ethereum y 5 segundos después falla la
infra. ¿La recupero?** La respuesta corta es incómoda pero clave:

> **Ni el backup de Postgres ni el snapshot de Raft contemplan esa llave de hace
> 5 s.** Pero no la pierdes — porque lo que la salva **no es el backup**, es la
> **replicación en vivo**. Estás mezclando dos mecanismos distintos.

### Backup ≠ replicación (RPO distinto)

| Mecanismo | RPO (cuánto puedes perder) | Contra qué protege |
|---|---|---|
| **Backup / snapshot** (periódico) | = intervalo del backup (min/horas) | Catástrofe total, corrupción, borrado |
| **Replicación en vivo** (quórum) | **≈ 0** para el dato ya confirmado | Caída de un nodo / disco / zona |

La pregunta correcta no es *"¿mi backup la tiene?"* (no la tiene), sino *"¿mi
storage en vivo la replicó antes de que yo supiera que existía?"*.

### Por qué "tengo la address" ⇒ ya está confirmada

OpenBao es **fuertemente consistente**: responde **después** de confirmar la
escritura en el storage.

```
POST /accounts → ethsign genera → escribe en storage → [CONFIRMA] → devuelve la address
```

- Falla **antes** de devolver la address → nunca tuviste la llave (reintentas, nada perdido).
- Falla **después** (los 5 s) → la escritura ya está confirmada; que sobreviva
  depende de la **garantía de confirmación** del backend.

### Evaluación por tipo de fallo y topología

| Fallo a los 5 s | POC single-node | **Raft 3/5 nodos (PD regional)** | Cloud SQL con HA |
|---|---|---|---|
| Crash del proceso / reinicio, disco intacto | ✅ (confirmada a disco) | ✅ | ✅ |
| Se destruye nodo / disco / **una zona** | ❌ solo último backup | ✅ **replicada al quórum → RPO≈0** | ✅ replicada al standby síncrono |
| Pérdida **total** del cluster / corrupción / borrado | ❌ | ❌ solo último snapshot | ⚠️ PITR (ver abajo) |

- **Single-node (la POC) NO protege de perder el volumen** — solo de un reinicio. Insuficiente para esta necesidad.
- **Raft 3+ nodos resuelve el escenario directo:** una escritura se confirma solo
  tras replicarse al **quórum** + fsync. Al recibir la address ya está en ≥2
  discos; si muere un nodo/zona 5 s después → **RPO cero**.

> ⚠️ **Lo que se desplegó realmente (2026-08) no cumple la columna "zona".**
> El cluster `lnet-privado` es **zonal** (`us-central1-c`), no regional: las 3
> réplicas de OpenBao viven en la misma zona, cada una con un PD zonal. Eso da
> **RPO≈0 para caída de un nodo o de un disco**, que es el fallo frecuente —
> pero **no** para la caída de la zona entera, donde la recuperación es restore
> del último snapshot (**RPO de hasta 6 h**, el intervalo del CronJob).
> Para conseguir el RPO≈0 multi-zona que describe la tabla haría falta un
> cluster GKE **regional**. Ver
> [`../k8s/docs/operations.md`](../k8s/docs/operations.md) → "Cosas que este
> despliegue NO cubre".

### El único punto donde Cloud SQL tiene ventaja (honesto)

Cloud SQL hace **PITR con archivado continuo de WAL** a almacenamiento separado de
la instancia → puede restaurar a hace segundos incluso tras perder la instancia
(RPO más fino que un snapshot **periódico** de Raft). **Pero** solo aplica a la
**pérdida total del cluster en vivo**, y ahí:

- Raft **regional (multi-zona)** ya hace ese caso muy improbable (cubierto por la
  replicación en vivo, sin depender de backups).
- Para la catástrofe real (perder toda la región) necesitas **replicar snapshots
  cross-region** — trabajo que haces **igual** con Postgres. No es gratis en ninguno.

La ventaja de PITR es real pero **estrecha**, y pesa solo en un escenario que el
Raft regional ya vuelve improbable. (Y recuerda: recuperes por réplica o por PITR,
el blob sigue cifrado — sin unseal/recovery keys no lo lees.)

### Mitigación a nivel de aplicación (la más efectiva)

Si "no perder **nunca** la última address" es requisito duro (p. ej. es una
dirección de depósito que das a un usuario), la solución más robusta es de diseño,
no de infra:

- **Pre-genera un pool de direcciones** en baja carga, deja que se confirmen/
  repliquen (y entren en un snapshot), y **entrégalas después** desde el pool.
- Así "dar una address" deja de ser una escritura *just-in-time* compitiendo contra
  un crash — la llave existía y estaba replicada mucho antes. Neutraliza la ventana
  **independientemente del backend**.

### Conclusión

Los backups no cubren la última llave en **ningún** backend; lo que la cubre es la
**replicación síncrona en vivo**. **Raft multi-nodo con PD regional te da RPO≈0**
para fallos de nodo/disco/zona sin la pieza extra de Postgres. Snapshots = para
catástrofe/corrupción, no para el último write. Y el **pool de direcciones** cierra
la ventana a nivel de app.

---

## Recomendación

**Raft + snapshots automáticos a GCS**, porque:

1. La durabilidad de datos vivos ya es equivalente (ambos sobre PD; regional =
   multi-zona).
2. El backup gestionado que da Cloud SQL se replica con un CronJob → GCS de forma
   trivial, y GCS es igual de durable.
3. Postgres **no elimina** el trabajo real de DR (custodia de unseal keys +
   restore de OpenBao).
4. Añadir Cloud SQL es una pieza más con estado que asegurar y facturar, para un
   beneficio de durabilidad ya cubierto.

**Cloud SQL es una elección defendible** si el criterio dominante es "que Google
gestione los backups y no construir nada". Es un motivo legítimo — no un error.

> El riesgo real de "perder las llaves" casi nunca es corrupción de disco: es
> **perder las unseal keys** o no tener snapshots. Eso se resuelve igual con
> cualquiera de las dos rutas.

---

## Migración desde el backend `file` (POC)

Migrar de `file` a `raft` (o a `postgresql`) **no es transparente**: son formatos
de datos distintos. En la POC, lo más limpio es empezar con volumen nuevo:

```bash
docker compose down -v      # borra el volumen viejo (formato file)
docker compose up -d        # arranca con Raft, sellado
# init + unseal + register-plugin.sh (ver README / quickstart)
```

Si tuvieras llaves que salvar, expórtalas antes con
`GET /v1/ethereum/export/accounts/<address>`.
