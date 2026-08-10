# Alto volumen de firma — throughput y escalado

> Cómo se comporta OpenBao + el plugin `ethsign` cuando hay que firmar **muchas
> transacciones**, y dónde está de verdad el cuello de botella. Complementa la
> decisión de storage ([`storage.md`](storage.md)) y la durabilidad
> ([`dr-plan.md`](dr-plan.md)).

## Idea central (leer esto primero)

Dos verdades no obvias que gobiernan todo lo demás:

1. **En OpenBao, HA ≠ throughput.** La doc oficial es explícita: *"HA does not
   enable increased scalability"* y *"the bottleneck of OpenBao is the data store
   itself, not OpenBao core."* En un cluster Raft, **solo el nodo activo procesa
   peticiones**; los standby reenvían al líder (o redirigen con 307). Añadir nodos
   da **failover**, no más firmas/segundo.
2. **El cuello de botella real de "muchas tx" no es OpenBao, es el `nonce`.** El
   plugin `ethsign` **no gestiona nonces** — tú se lo pasas en cada firma y él
   firma ciegamente lo que le des. La coordinación de nonces es responsabilidad de
   **tu servicio**, no del vault.

---

## Qué es "firmar" internamente

Firmar es una operación de **lectura**: OpenBao lee la entrada cifrada de la cuenta
desde el storage, la descifra en el barrier, hace la firma secp256k1 (CPU,
sub-milisegundo) y devuelve. El coste dominante **no** es la criptografía, sino:
acceso al storage + barrier + el RPC al proceso del plugin.

Implicación directa: como toda firma lee el storage, y el storage es el cuello de
botella, quieres el storage **local y rápido**. **Raft** (BoltDB local con caché)
gana claramente a **PostgreSQL**, donde cada firma sería un round-trip de red a la
base. → Para alto volumen, esto refuerza Raft también por rendimiento, no solo por
durabilidad.

---

## El problema del nonce (el fallo #1 en producción)

### El plugin NO habla con la cadena (por diseño)

`ethsign` **no se conecta a ningún nodo blockchain**. El README del plugin lo dice
literal: *"The plugin does not interact with the target blockchain. It has very
simple responsibilities: sign transactions."* No es que gestione mal los nonces —
es que **no los gestiona en absoluto** y **no puede** (no tiene conexión JSON-RPC,
así que no puede consultar `eth_getTransactionCount`). Firma el `nonce` que le des,
tal cual.

Ese aislamiento es **deseable**: es lo que lo hace comportarse como un HSM. La
llave vive en un componente sin salida de red hacia la cadena → menor superficie de
ataque. Separa responsabilidades: **firmar** (OpenBao) vs **conocer el estado de la
cadena** (tu servicio).

### De dónde sale el nonce entonces

De **tu servicio**, que es quien sí habla con el nodo:

```
tu servicio
  ├─ (1) consulta el nodo:   eth_getTransactionCount(cuenta, "pending")
  ├─ (2) serializa/asigna el nonce por cuenta   ← tu lógica, con lock/secuencia
  ├─ (3) pide a OpenBao:     POST /ethereum/accounts/<addr>/sign  { nonce, to, ... }
  └─ (4) difunde:            eth_sendRawTransaction(signed_transaction)
```

**Ojo:** el paso (1) NO basta por sí solo. `eth_getTransactionCount(..., "pending")`
puede quedarse corto si hay varias tx en vuelo aún no minadas, o devolver el mismo
valor a dos peticiones concurrentes. El nodo te da un punto de partida; la
unicidad/orden bajo concurrencia la garantiza el asignador serializado del paso (2),
que es tuyo e imprescindible.

### Consecuencias si no lo coordinas

`ethsign` firma el `nonce` que le pases en el payload. Si no lo coordinas:

- **Nonce duplicado** (dos tx concurrentes con el mismo nonce) → una se cae en la
  red.
- **Hueco de nonce** (te saltas uno) → las tx siguientes quedan atascadas en el
  mempool hasta que se rellene.

### Reglas de diseño

1. **Serializa el nonce por cuenta.** Pon delante de OpenBao un asignador de nonce
   (contador/secuencia con lock por dirección) que garantice orden y unicidad. Esto
   vive en **tu servicio**, no en OpenBao.
2. **Paraleliza por cuentas, no por tx de una cuenta.**
   - Muchas cuentas firmando a la vez = llaves independientes = escala bien.
   - Muchas tx de **una** cuenta = obligatoriamente serializadas por el nonce.
3. **Shardea emisores si necesitas volumen desde "un" origen.** Reparte la carga en
   varias cuentas ("nonce lanes") en vez de exprimir una sola dirección.

---

## Escalado de throughput

Como el throughput no escala añadiendo nodos al cluster:

- **Escala vertical:** nodo activo más potente (CPU + disco rápido para el storage).
- **Storage rápido:** Raft local; en K8s, PD SSD.
- **Higiene de cliente:**
  - Reutiliza la conexión HTTP (keep-alive).
  - **Reutiliza el token** — no re-autenticar en cada request.
  - Revisa el **audit logging**: cada request se escribe y hashea; a alto volumen
    añade latencia + I/O. Ajusta o desactiva según tu necesidad de auditoría.
- **Protege el nodo activo** con *rate-limit quotas* de OpenBao para que un pico no
  lo tumbe.
- **Mide con tu hardware.** Techo aproximado: cientos a pocos miles de firmas/seg
  según máquina y storage. El diseño del nonce suele importar más que el TPS bruto.

### Si un solo cluster no da abasto

**No** añadas más nodos al mismo cluster (no escala lecturas). **Shardea en varios
clusters**, cada uno dueño de un subconjunto de cuentas. Es la vía correcta —
probablemente innecesaria, pero disponible si llega.

---

## Interacción con la durabilidad (HA)

La replicación de Raft añade una pequeña latencia **solo en escrituras** (crear /
importar cuenta), porque confirma en quórum antes de responder. Pero **firmar es
lectura** → no se ve afectado. Es decir: **el HA que da la durabilidad no penaliza
el throughput de firma.** Los dos objetivos son compatibles con Raft.

Ver [`storage.md`](storage.md) (elección de backend) y [`dr-plan.md`](dr-plan.md)
(snapshots + auto-unseal) para el eje de "que no se pierdan las llaves".

---

## Checklist para el caso "muchas tx + no perder llaves"

- [ ] Backend **Raft** (no Postgres) — storage local rápido + HA nativo.
- [ ] Asignador de **nonce serializado por cuenta** en el servicio cliente.
- [ ] **Sharding de cuentas emisoras** si el volumen viene de pocos orígenes.
- [ ] Token reutilizado + keep-alive + audit logging ajustado.
- [ ] Rate-limit quotas en el nodo activo.
- [ ] Durabilidad: Raft 3/5 con **PD regional** + **snapshots a GCS** + **auto-unseal KMS**.
- [ ] **Benchmark** con hardware real antes de comprometer un SLA de TPS.
