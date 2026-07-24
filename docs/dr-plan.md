# Plan de DR — snapshots a GCS + auto-unseal con Cloud KMS

> **Estado: PLAN, no implementado.** Este doc describe *qué* haríamos y *en qué
> orden* para cubrir los dos ingredientes de recuperación descritos en
> [`storage.md`](storage.md): (1) snapshots durables del estado y (2) custodia de
> la root key. Los bloques de config son **bocetos ilustrativos**, no manifiestos
> finales — faltan valores del entorno real (proyecto GCP, región, nombres).

## Objetivo

| Ingrediente de DR | Cómo lo cubre este plan |
|---|---|
| Snapshot del estado (blobs cifrados) | **CronJob** que hace `raft snapshot save` → sube a **GCS** con versionado/retención |
| Custodia de unseal / root key | **Auto-unseal con Cloud KMS** (Google gestiona la master key; se elimina el unseal manual) |

Ambos son independientes del backend, pero el plan asume **Raft** (Ruta A).

---

## Parte 1 — Auto-unseal con Cloud KMS

### Por qué antes que el CronJob
Con auto-unseal, los pods arrancan **ya desellados** tras un reinicio (no hay que
meter unseal keys a mano en 3/5 nodos). Además mueve la custodia de la root key a
KMS — el punto donde de verdad se pierden las llaves. Es el cambio de mayor impacto
en DR, por eso va primero.

### Prerrequisitos
- [ ] Proyecto GCP y **keyring + key de Cloud KMS** creados (rol
      `cloudkms.cryptoKeyEncrypterDecrypter` para la identidad de OpenBao).
- [ ] **Workload Identity** en GKE: mapear la ServiceAccount de K8s del pod de
      OpenBao a una GCP SA con ese rol (evita claves JSON montadas).
- [ ] Decidir región/keyring acorde a la región del cluster.

### Cambio de config (boceto)
```hcl
# Sustituye al sellado Shamir manual. La master key la protege KMS.
seal "gcpckms" {
  project    = "TU_PROYECTO"
  region     = "TU_REGION"
  key_ring   = "openbao-keyring"
  crypto_key = "openbao-unseal"
}
```

### Consideraciones / preguntas abiertas
- **Migración de sellado:** pasar de Shamir a auto-unseal requiere `bao operator
  unseal -migrate` (o re-`init` en la POC). En K8s hay que planificar la ventana.
- **Recovery keys:** con auto-unseal, `init` genera *recovery keys* (no unseal
  keys). Se usan para operaciones sensibles (regenerar root token, etc.) —
  custodiarlas con Shamir realista igual.
- **Dependencia de KMS:** si KMS no está disponible, OpenBao no desella. Asumir el
  SLA de Cloud KMS; considerar réplica de la key.

---

## Parte 2 — CronJob de snapshots a GCS

### Prerrequisitos
- [ ] **Bucket de GCS** con **Object Versioning** activado y **retention/lifecycle
      policy** (p. ej. retener 30 días, mover a Nearline/Coldline lo antiguo).
- [ ] SA de GCP (vía Workload Identity) con `storage.objectCreator` sobre el bucket.
- [ ] Un **token de OpenBao con política mínima**: solo permiso para
      `sys/storage/raft/snapshot` (NO el root token).

### Política mínima del token (boceto)
```hcl
path "sys/storage/raft/snapshot" {
  capabilities = ["read"]
}
```

### Flujo del CronJob (boceto conceptual, no YAML final)
```
CronJob (diario / cada N horas)
  1. bao operator raft snapshot save /tmp/openbao-<fecha>.snap
        (autenticado con el token de política mínima)
  2. gsutil cp /tmp/openbao-<fecha>.snap gs://BUCKET/snapshots/
  3. rm /tmp/*.snap
```

Notas:
- La imagen del job necesita el binario `bao` **y** `gsutil`/SDK de GCP (o dos
  contenedores: uno hace el snapshot a un volumen compartido, otro lo sube).
- **Nunca** persistir el snapshot en disco del pod más de lo necesario: es el
  estado completo cifrado.
- Nombrado con fecha para versionar; confiar en la lifecycle policy del bucket para
  la retención (no borrar a mano).

### Consideraciones / preguntas abiertas
- **Frecuencia:** ¿RPO objetivo? Diario suele bastar para llaves que cambian poco;
  si se crean cuentas a menudo, subir a cada 6–12 h.
- **Cifrado del bucket:** activar CMEK (misma KMS) para el bucket, defensa en
  profundidad.
- **Verificación de restore:** el plan **debe** incluir un *game day* periódico:
  restaurar un snapshot en un OpenBao efímero y validar que abre y firma. Un backup
  no probado no es un backup.

---

## Orden de ejecución sugerido

1. Migrar la POC a Raft (**hecho** — `config/openbao.hcl`).
2. Auto-unseal con Cloud KMS (Parte 1) — primero, porque cambia el `init`.
3. Bucket GCS + política + token de snapshot (Parte 2, prerrequisitos).
4. CronJob de snapshots (Parte 2).
5. **Game day de restore** — validar el ciclo completo antes de considerarlo DR.

## Fuera de alcance de este plan (pendiente si se avanza)
- Manifiestos finales del StatefulSet 3/5 nodos + headless Service + PVC (PD regional).
- Alertas/monitorización de: sello (`sealed`), fallo del CronJob, antigüedad del
  último snapshot en el bucket.
- Rotación de la root token y de las recovery keys.
