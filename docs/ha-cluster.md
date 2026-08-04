# Cluster Raft HA de 3 nodos en Docker (aprendizaje)

> **Esto NO es HA real.** 3 nodos en un solo host Docker caen todos si el host
> muere. Sirve para *ver* el comportamiento de Raft: join automático, quórum,
> `list-peers` y failover al matar un nodo. La HA de verdad exige nodos en
> máquinas/zonas distintas → Kubernetes. Ver [`storage.md`](storage.md) para el
> porqué del quórum impar.

Archivos: `docker-compose.ha.yml` + `config/ha/openbao-{1,2,3}.hcl`. No toca la POC
de un nodo (`docker-compose.yml`).

## Cómo funciona el auto-join

- Cada nodo tiene su `node_id`, su `api_addr`/`cluster_addr` **anunciados con el
  nombre de servicio** (`openbao-1`, no `127.0.0.1`), y su propio volumen.
- Los tres bloques `retry_join` hacen que cada nodo busque al líder por la red de
  Compose (se ignora a sí mismo).
- Con sello Shamir, un nodo que se une **igual arranca sellado**: hay que
  desellarlo con **la misma unseal key** del líder para que sincronice y participe.

## Arranque (el orden importa)

```bash
# 1. Construir la imagen (compartida por los 3 nodos)
docker compose build            # o: docker build -t openbao-lnet:latest .

# 2. Levantar el cluster
docker compose -f docker-compose.ha.yml up -d
docker compose -f docker-compose.ha.yml ps        # 3 servicios "running" (sellados)

# 3. Inicializar SOLO el nodo 1 (crea el cluster, nodo 1 = líder)
docker compose -f docker-compose.ha.yml exec openbao-1 \
  bao operator init -key-shares=1 -key-threshold=1
#   -> copia "Unseal Key 1" e "Initial Root Token" (se muestran una sola vez)

# 4. Desellar el nodo 1 con esa unseal key
docker compose -f docker-compose.ha.yml exec openbao-1 \
  bao operator unseal <UNSEAL_KEY>

# 5. Desellar nodos 2 y 3 con la MISMA unseal key.
#    Vía retry_join descubren al líder y se unen como followers.
docker compose -f docker-compose.ha.yml exec openbao-2 bao operator unseal <UNSEAL_KEY>
docker compose -f docker-compose.ha.yml exec openbao-3 bao operator unseal <UNSEAL_KEY>

# 6. Verificar el cluster (3 peers: 1 leader + 2 followers)
export BAO_TOKEN=<INITIAL_ROOT_TOKEN>
docker compose -f docker-compose.ha.yml exec -e BAO_TOKEN="$BAO_TOKEN" openbao-1 \
  bao operator raft list-peers
```

> ⚠️ **No inicialices los nodos 2 y 3** (`operator init`) — eso crearía clusters
> separados. Solo se inicializa **uno**; los demás **solo se desellan**.

## Registrar el plugin (una sola vez, se replica)

El binario `ethsign` está en los 3 (misma imagen). El registro se guarda en Raft y
se replica, así que se hace **una vez contra el líder**:

```bash
SHA=$(docker compose -f docker-compose.ha.yml exec -T openbao-1 sha256sum /openbao/plugins/ethsign | awk '{print $1}')
docker compose -f docker-compose.ha.yml exec -e BAO_TOKEN="$BAO_TOKEN" openbao-1 \
  bao plugin register -sha256="$SHA" -command=ethsign secret ethsign
docker compose -f docker-compose.ha.yml exec -e BAO_TOKEN="$BAO_TOKEN" openbao-1 \
  bao secrets enable -path=ethereum ethsign
```

## Probar el failover

```bash
# ¿Quién es el líder ahora?
docker compose -f docker-compose.ha.yml exec -e BAO_TOKEN="$BAO_TOKEN" openbao-1 bao status

# Matar el líder (p. ej. openbao-1) y ver cómo otro nodo toma el relevo
docker compose -f docker-compose.ha.yml stop openbao-1
docker compose -f docker-compose.ha.yml exec -e BAO_TOKEN="$BAO_TOKEN" openbao-2 bao operator raft list-peers
```

Con 3 nodos y quórum 2, el cluster **sigue operativo** tras perder 1 (elige nuevo
líder). Si paras un segundo nodo, pierdes quórum y el cluster deja de aceptar
escrituras — exactamente lo que ilustra la tabla de quórum en `storage.md`.

## Acceso a las APIs desde el host

| Nodo | Puerto host | URL |
|------|-------------|-----|
| openbao-1 | 8200 | http://127.0.0.1:8200 |
| openbao-2 | 8210 | http://127.0.0.1:8210 |
| openbao-3 | 8220 | http://127.0.0.1:8220 |

## Teardown

```bash
docker compose -f docker-compose.ha.yml down        # parar, conservar volúmenes
docker compose -f docker-compose.ha.yml down -v     # + BORRAR los 3 volúmenes
```
