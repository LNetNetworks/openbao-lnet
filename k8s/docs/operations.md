# Runbook operativo — OpenBao en GKE

Namespace `openbao` · cluster `lnet-privado` · https://vault.l-net.io

---

## Comandos que se usan todos los días

```bash
# Contexto
gcloud container clusters get-credentials lnet-privado --zone us-central1-c --project l-net-469615

# Estado general
kubectl -n openbao get pods -o wide
kubectl -n openbao get pvc

# Quién es el líder
kubectl -n openbao get pods -l openbao-active=true

# Atajo: exportar el pod activo
export POD=$(kubectl -n openbao get pods -l openbao-active=true -o jsonpath='{.items[0].metadata.name}')

kubectl -n openbao exec -i $POD -- bao status
kubectl -n openbao exec -i $POD -- env BAO_TOKEN=$BAO_TOKEN bao operator raft list-peers
kubectl -n openbao exec -i $POD -- env BAO_TOKEN=$BAO_TOKEN bao operator raft autopilot state

# Logs (formato json)
kubectl -n openbao logs -f $POD | jq -r '"\(.["@timestamp"]) \(.["@level"]) \(.["@message"])"'
```

---

## Failover — qué pasa cuando cae un nodo

**No hay que hacer nada.** El flujo es:

1. El pod muere (evicción, upgrade de nodo, OOM…).
2. Raft detecta la pérdida de contacto; si era el líder, los otros dos eligen uno
   nuevo (segundos).
3. OpenBao mueve la label `openbao-active=true` al nuevo líder.
4. Los endpoints del Service `openbao-active` se actualizan → Kong reenruta.
5. El StatefulSet recrea el pod, que monta su PVC, hace `retry_join` y **se
   desella solo contra Cloud KMS**.

Las peticiones en vuelo durante el paso 3 fallan. Los clientes deben reintentar.

Prueba controlada:

```bash
SKIP_FAILOVER= BAO_TOKEN=$BAO_TOKEN ./k8s/scripts/smoke-test.sh
```

### Si un pod NO vuelve a Ready

```bash
kubectl -n openbao logs openbao-1 --previous | tail -40
```

| Síntoma en los logs | Causa | Arreglo |
|---|---|---|
| `failed to encrypt with GCP CKMS: permission denied` | El GSA perdió el rol sobre la key, o la annotation de WI no coincide | Re-correr `k8s/gcp/setup-gcp.sh` |
| `failed to retrieve credentials` | Workload Identity mal enlazado | Verificar `iam.gke.io/gcp-service-account` en la KSA `openbao` |
| `Pending` sin eventos de scheduling | `podAntiAffinity`: no hay un tercer nodo | Esperar al autoscaler (`kubectl get nodes -w`) |
| `failed to join raft cluster` | Los otros nodos no responden | Verificar el Service headless `openbao-internal` |
| `audit log: no space left on device` | El PVC de audit se llenó | **OpenBao deja de responder a propósito.** Ver "Disco de auditoría" abajo |

---

## Quórum perdido (2 de 3 nodos caídos)

Con 2 de 3 caídos no hay quórum: el vault **no procesa escrituras**. Si los pods
vuelven con sus PVCs intactos, el quórum se restablece solo.

Si los PVCs se perdieron, hay que reconstruir desde un peer sano:

```bash
# Verificar cuál sobrevivió
kubectl -n openbao exec -i openbao-0 -- bao status

# Sacar del quórum a los nodos muertos
kubectl -n openbao exec -i openbao-0 -- \
  env BAO_TOKEN=$BAO_TOKEN bao operator raft remove-peer openbao-1
```

Después, borrar el PVC del nodo muerto y su pod: se recrea vacío y hace
`retry_join` como nodo nuevo, replicando todo el estado desde el líder.

```bash
kubectl -n openbao delete pvc data-openbao-1 audit-openbao-1
kubectl -n openbao delete pod openbao-1
```

Si **ningún** nodo sobrevivió con datos → restore desde snapshot.

---

## Restore desde snapshot

> ⚠️ **Sobreescribe TODO el estado del cluster.** Tomar un snapshot del estado
> actual antes, aunque parezca inservible.

**Requisito no obvio:** el cluster destino tiene que usar **la misma KMS key**.
Un snapshot está cifrado con la root key, que a su vez está cifrada con la KMS
key. Restaurar en un cluster con otro seal no funciona sin una migración de seal.

```bash
# 1. Elegir el snapshot
gcloud storage ls -r gs://lnet-openbao-snapshots/auto/

# 2. Bajarlo y meterlo en el pod activo
gcloud storage cp gs://lnet-openbao-snapshots/auto/2026/08/04/openbao-20260804T060000Z.snap /tmp/restore.snap
export POD=$(kubectl -n openbao get pods -l openbao-active=true -o jsonpath='{.items[0].metadata.name}')
kubectl -n openbao cp /tmp/restore.snap $POD:/tmp/restore.snap

# 3. Restaurar
kubectl -n openbao exec -it $POD -- \
  env BAO_TOKEN=$BAO_TOKEN bao operator raft snapshot restore -force /tmp/restore.snap

# 4. Los tres nodos se re-sincronizan solos. Verificar:
kubectl -n openbao exec -i $POD -- env BAO_TOKEN=$BAO_TOKEN bao operator raft list-peers
BAO_TOKEN=$BAO_TOKEN ./k8s/scripts/smoke-test.sh
```

**Después de un restore hay que re-verificar el plugin**: el registro del
catálogo viaja dentro del snapshot, pero si el binario de la imagen actual tiene
otro sha256, hay que re-registrarlo:

```bash
BAO_TOKEN=$BAO_TOKEN ./k8s/scripts/register-plugin.sh
```

### Ensayo de restore

Un backup no probado no es un backup. Recomendación: **cada trimestre**,
restaurar el último snapshot en un cluster/namespace desechable (con la misma
KMS key) y correr el smoke test. Anotar la fecha del último ensayo.

---

## Upgrades

### Subir la imagen (bump de OpenBao o del plugin ethsign)

```bash
# 1. Snapshot ANTES
BAO_TOKEN=$BAO_TOKEN LABEL=pre-upgrade ./k8s/scripts/snapshot.sh

# 2. Build + push (pipeline o a mano) → nuevo $TAG

# 3. Bump del tag en cloud-infra
#    Job manual `bump-image-tag` del pipeline, o a mano:
#    .spec.source.helm.valuesObject.server.image.tag en
#    gitops-apps/argocd-applications/openbao.yaml

# 4. Vigilar el rollout (updateStrategy: RollingUpdate, OrderedReady)
kubectl -n openbao rollout status statefulset/openbao --timeout=10m
kubectl -n openbao get pods -w
```

El rollout va de a un pod, empezando por `openbao-2`. Cada uno vuelve desellado
solo. Habrá **uno o dos failovers** durante el proceso (cuando le toque al
líder).

**Si cambió el binario del plugin**, re-registrarlo después:

```bash
BAO_TOKEN=$BAO_TOKEN ./k8s/scripts/register-plugin.sh
```

### Subir el chart de Helm

Editar `targetRevision` en la Application. **Leer antes el changelog del chart**:
un cambio en los `volumeClaimTemplates` obliga a recrear el StatefulSet, y los
StatefulSet no admiten modificar los claim templates in-place.

```bash
# Verificar el diff ANTES de commitear:
helm template openbao openbao/openbao --version <NUEVA> -n openbao -f /tmp/values.yaml \
  --kube-version 1.31.0 > /tmp/nuevo.yaml
diff /tmp/actual.yaml /tmp/nuevo.yaml
```

### Upgrades de GKE (node pool)

El release channel es REGULAR: Google reinicia nodos por su cuenta. Con el PDB
(`maxUnavailable=1`) y auto-unseal, esto es transparente. Es exactamente el
escenario que hacía inviable el unseal manual.

---

## Escalado — leer esto antes de agregar nodos

> **HA ≠ throughput.** Es la conclusión de
> [`../../docs/throughput.md`](../../docs/throughput.md) y sigue valiendo igual
> en Kubernetes.

Solo el nodo **activo** atiende peticiones. Los standby no reparten carga: están
para el failover. Agregar un cuarto y quinto nodo **no sube las firmas por
segundo**, solo la tolerancia a fallos (de 1 nodo a 2).

Para más throughput:

1. **Vertical**: subir `server.resources` (CPU sobre todo — la firma secp256k1
   es CPU-bound).
2. **Shardear cuentas** entre varios clusters de OpenBao si algún día hiciera
   falta.
3. **Nunca**: agregar réplicas esperando más TPS.

Y el cuello de botella real no es OpenBao: **`ethsign` no gestiona nonces**. El
cliente tiene que serializar las transacciones por cuenta. Tres réplicas hacen
más tentador paralelizar — y es justo lo que provoca nonces duplicados.

### Pasar a 5 nodos (tolerancia, no velocidad)

```yaml
server:
  ha:
    replicas: 5
```

Y actualizar el autopilot: `-min-quorum=5`. Con 5 nodos se toleran 2 caídas.
El node pool tiene que poder llegar a 5 nodos (hoy `max_node_count = 5`, así que
todo el pool quedaría ocupado por OpenBao — revisar antes).

---

## Disco de auditoría

OpenBao **deja de responder** si el audit device no puede escribir. Es
intencional: prefiere caerse antes que operar sin dejar rastro.

```bash
kubectl -n openbao exec -i $POD -- df -h /openbao/audit
```

Alerta sugerida para Prometheus (el ServiceMonitor ya está activo):

```yaml
- alert: OpenBaoAuditDiskFilling
  expr: kubelet_volume_stats_available_bytes{persistentvolumeclaim=~"audit-openbao-.*"} 
        / kubelet_volume_stats_capacity_bytes{persistentvolumeclaim=~"audit-openbao-.*"} < 0.20
  for: 15m
  annotations:
    summary: "PVC de auditoría de OpenBao al 80% — si se llena, el vault deja de firmar"
```

Rotar el log cuando haga falta (OpenBao reabre el archivo con `SIGHUP`):

```bash
kubectl -n openbao exec -i $POD -- sh -c \
  'mv /openbao/audit/audit.log /openbao/audit/audit-$(date +%F).log'
kubectl -n openbao exec -i $POD -- pkill -HUP bao
```

---

## Monitoreo

`serverTelemetry.serviceMonitor` está activo y el namespace lleva la label
`monitoring: enabled` (vía `managedNamespaceMetadata` de la Application), que es
lo que exige el `serviceMonitorNamespaceSelector` de kube-prometheus-stack.

> **Solo se scrapea el nodo activo.** El ServiceMonitor que genera el chart
> selecciona por la label `openbao-active: "true"`, o sea el Service
> `openbao-active` → un único endpoint, el líder. Es deliberado (evita métricas
> de cluster duplicadas × 3), pero implica que **no hay métricas de los
> standby**: un standby que se quedara sellado no se vería en Prometheus.
> Para eso está el readiness probe — vigilar en su lugar
> `kube_statefulset_status_replicas_ready{statefulset="openbao"} < 3`.

> El prefijo de las métricas es `vault_` (OpenBao mantuvo el de Vault; se puede
> cambiar con `metrics_prefix` en el bloque `telemetry` del HCL).

Métricas que vale la pena mirar en Grafana (https://ops-monitor.l-net.io):

| Métrica | Qué indica |
|---|---|
| `vault_core_unsealed` | 1 = el líder está desellado |
| `kube_statefulset_status_replicas_ready{statefulset="openbao"}` | **< 3 = algún nodo no volvió** (la señal real de un auto-unseal fallido) |
| `vault_raft_leader_lastcontact` | Latencia líder↔followers. Si sube, el quórum está en riesgo |
| `vault_core_handle_request` | Latencia y volumen de peticiones |
| `vault_audit_log_request_failure` | **> 0 es una emergencia**: el audit device no escribe |
| `vault_runtime_alloc_bytes` | Memoria; vigilar contra el límite de 2Gi |

---

## Cosas que este despliegue NO cubre

Honestidad sobre los límites, para que nadie asuma de más:

- **Caída de zona.** El cluster es **zonal** (`us-central1-c`). Las 3 réplicas
  viven en la misma zona. Si la zona cae, cae el vault entero y la recuperación
  es levantar en otra zona y restaurar el último snapshot → **RPO de hasta 6h**.
  `docs/storage.md` habla de RPO≈0 para fallo de zona; eso requeriría un cluster
  **regional**, que hoy no existe. Anotado también allá.
- **Broadcast.** Este sistema firma, no envía. Publicar la
  `signed_transaction` necesita un RPC (`eth_sendRawTransaction`).
- **Gestión de nonces.** Es del cliente. Ver arriba.
- **Rotación de las llaves de Ethereum.** `ethsign` no la implementa; rotar
  significa crear una cuenta nueva y migrar los fondos/permisos a nivel de
  aplicación.
- **Replicación entre regiones.** Es una feature Enterprise de Vault que OpenBao
  no tiene. La alternativa es snapshots + restore.
- **WAF.** `vault.l-net.io` va DNS only para que el `ip-restriction` vea la IP
  real, así que **no pasa por el WAF de Cloudflare** ni por su mitigación de
  DDoS. La defensa de borde es el allowlist + rate limiting de Kong. Si algún
  día se configura `real_ip` en el data plane de Kong (afecta a todo el
  cluster), `vault` puede volver a proxied y recuperar el WAF.

---

## Ver también

- [`deployment.md`](deployment.md) — el despliegue desde cero.
- [`unseal-keys.md`](unseal-keys.md) — recovery keys y escenarios de desastre.
- [`kong-ingress.md`](kong-ingress.md) — el edge y sus trampas.
- [`../../docs/throughput.md`](../../docs/throughput.md) — HA ≠ throughput, nonces.
- [`../../docs/storage.md`](../../docs/storage.md) — por qué Raft.
