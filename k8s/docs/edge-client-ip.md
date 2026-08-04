# La IP del cliente se pierde en el edge — análisis y opciones

> **Documento de decisión.** Reúne la evidencia medida en el cluster
> `lnet-privado` sobre por qué Kong no puede ver la IP real de quien hace una
> petición, qué implica eso para el allowlist de `vault.l-net.io`, y qué
> opciones hay — con su coste y su alcance. No implementa ninguna: la que toca
> el data plane de Kong afecta a las 50 Ingress del cluster y es una decisión
> de infra, no de esta app.
>
> Medido el **2026-08-04** contra `lnet-privado` (GKE v1.35.6-gke,
> Kong Gateway 3.10, KIC 3.5.4).

---

## TL;DR

1. **Kong nunca ve la IP del cliente.** Ni con Cloudflare delante ni sin él.
   Medido, no inferido.
2. La causa principal **no es Cloudflare**: es `externalTrafficPolicy: Cluster`
   en el Service `gateway-kong-proxy`, que hace **SNAT en L4** antes de que el
   paquete llegue a Kong. Cloudflare añade una segunda capa de ofuscación, pero
   quitarlo no resuelve nada.
3. Por lo tanto **un `KongPlugin/ip-restriction` con CIDRs de oficina bloquearía
   a todo el mundo**, y el `rate-limiting` con `limit_by: ip` es hoy un límite
   **global compartido**, no por cliente.
4. Lo que **sí funciona hoy sin tocar nada compartido**: filtrar por IP en
   **Cloudflare** (IP Access Rules / WAF), porque ahí la IP del cliente es
   visible por definición.
5. La solución correcta a medio plazo es **`externalTrafficPolicy: Local` +
   `trusted_ips`/`real_ip_header` en Kong**, juntas. Por separado, cada una deja
   un agujero (§5).

---

## 1. Por qué este despliegue necesita un allowlist por IP

Es la pregunta de fondo: las otras ~40 apps del edge no lo tienen, ¿por qué
ésta sí?

### No es una API más, es custodia de llaves

`POST /v1/ethereum/accounts/<address>/sign` **firma transacciones** con llaves
secp256k1 que controlan fondos y permisos on-chain. El resto del edge expone
datos: si se filtran, el daño es grave pero acotado y a menudo reversible. Acá
lo que se expone es **capacidad de firma**, y una transacción firmada y
difundida **no se revierte**. No hay un "deshacer" equivalente al de restaurar
un backup.

### La autenticación es un único bearer token

Todo el control de acceso de OpenBao vive en un header:

```
X-Vault-Token: s.XXXXXXXXXXXXXXXXXXXX
```

Sin mTLS, sin binding a IP, sin segundo factor. Quien tenga ese string tiene
exactamente el poder que le dé su política. Y los tokens se filtran de maneras
mundanas, no exóticas:

- un `curl -v` pegado en un ticket o en un chat,
- una variable de entorno impresa en el log de un job de CI,
- un `.env` commiteado por error,
- el historial de shell de una laptop robada,
- un dump de memoria o un core file de la app cliente.

El allowlist convierte "tengo el token" en "tengo el token **y** estoy en una
red concreta". Son dos condiciones independientes; la probabilidad conjunta de
que se cumplan las dos es mucho menor que la de cada una.

### Reduce la superficie pre-autenticación

Esto pesa más de lo que parece. El allowlist no solo protege del token filtrado:
**impide que internet alcance siquiera el listener de OpenBao**. Es decir,
protege también de:

- un 0-day pre-auth en OpenBao (que es software joven: fork de Vault de 2023),
- y sobre todo de un fallo en **`ethsign`**, que es un plugin de terceros
  (`kaleido-io/vault-plugin-secrets-ethsign`) pinneado a un commit suelto
  (`efdc481c`), sin releases ni ciclo de parches de seguridad, ejecutándose
  **dentro** del proceso que custodia las llaves.

Si mañana aparece un bug explotable sin token en cualquiera de los dos, un
allowlist es la diferencia entre "hay que parchear" y "hay que parchear ya
mismo porque está expuesto a internet".

### El conjunto de clientes legítimos es pequeño y enumerable

Esto es lo que hace que el coste operativo sea casi nulo:

- Los consumidores **dentro del cluster** usan
  `openbao-active.openbao.svc.cluster.local:8200` y **ni siquiera pasan por el
  Ingress**.
- El Ingress existe para (a) operadores humanos con la CLI o la UI, y (b)
  consumidores externos concretos, que son un puñado y conocidos.

No es una API pública para terceros arbitrarios. Restringir por IP no le cierra
la puerta a nadie que debiera entrar.

### Postura de auditoría

Un sistema equivalente a un HSM, alcanzable desde cualquier IP de internet con
solo un bearer token, es difícil de defender en una revisión de seguridad
—independientemente de si alguna vez se explotó.

### El contra-argumento honesto

Un allowlist por IP tiene coste: hay que mantener la lista, las IPs de casa son
dinámicas, y una VPN mal configurada bloquea a gente legítima. Y —esto es
exactamente lo que documenta el resto de este archivo— **un allowlist que no
filtra de verdad es peor que no tener ninguno**, porque aparenta un control que
no existe y desincentiva poner otros.

Por eso el allowlist **no sustituye** a las otras capas, las complementa: el
audit device, la política que deniega `ethereum/export/*`, la revocación del
root token, el rate limiting y la autenticación por ServiceAccount siguen
siendo necesarios exactamente igual.

---

## 2. La evidencia: qué IP ve Kong

### El experimento

Desde una máquina con IP pública `179.6.6.187`, dos peticiones al mismo backend
(`stats.l-net.io`), diferenciadas por el `User-Agent`:

```bash
# A) Directo al LoadBalancer, saltándose Cloudflare
#    (= exactamente el escenario "DNS only / nube gris")
curl -sk4 -H "Host: stats.l-net.io" -A "probe-direct" https://35.192.128.2/

# B) Por el camino normal, a través de Cloudflare
curl -s4 -A "probe-cf" https://stats.l-net.io/
```

Lo que registró Kong en su access log (`$remote_addr` es el primer campo):

```
10.3.207.227 - - [...] "GET / HTTP/1.1" 307 8245 "-" "probe-direct"
10.88.1.1    - - [...] "GET / HTTP/1.1" 307 2180 "-" "probe-cf"
```

| Camino | Kong registró | Qué es esa IP |
|---|---|---|
| Directo al LB (DNS only) | `10.3.207.227` | un **nodo** de GKE |
| Vía Cloudflare (proxied) | `10.88.1.1` | un **pod / gateway interno** |
| Real | `179.6.6.187` | **no aparece en ningún caso** |

### Por qué: dos capas que borran la IP

```
cliente 179.6.6.187
   │
   ├─[si proxied]─► Cloudflare edge ──► añade CF-Connecting-IP y X-Forwarded-For
   │                                    (la IP real viaja en un HEADER, no en el paquete)
   ▼
GCP external passthrough LB (35.192.128.2, target-pool)
   │   preserva la IP de origen del paquete hasta acá
   ▼
nodo de GKE
   │   ◄── ✂ AQUÍ SE PIERDE: kube-proxy hace SNAT porque el Service
   │        gateway-kong-proxy tiene externalTrafficPolicy: Cluster
   ▼
pod de Kong  ──►  $remote_addr = IP del nodo (o del pod)
```

**`externalTrafficPolicy: Cluster`** es el default de Kubernetes. Permite que
cualquier nodo reciba tráfico del LB y lo reenvíe a un pod de Kong en otro
nodo; para que el paquete de vuelta encuentre el camino, kube-proxy reescribe
la IP de origen (SNAT). El precio de ese balanceo es la IP del cliente.

Confirmación en la configuración:

```bash
$ kubectl -n edge-system get svc gateway-kong-proxy \
    -o jsonpath='{.spec.type} {.spec.externalTrafficPolicy}'
LoadBalancer Cluster

$ kubectl -n edge-system get deploy gateway-kong \
    -o jsonpath='{range .spec.template.spec.containers[0].env[*]}{.name}{"\n"}{end}' \
    | grep -iE 'trusted|real_ip'
                    # vacío: sin KONG_TRUSTED_IPS, KONG_REAL_IP_HEADER
                    #        ni KONG_REAL_IP_RECURSIVE
```

Y la zona entera está proxied, lo que añade la segunda capa:

```bash
$ dig +short stats.l-net.io api-ppr.l-net.io naas.l-net.io auth.l-net.io ops-console.l-net.io
104.21.35.194
172.67.178.218      # IPs del edge de Cloudflare, no 35.192.128.2
```

---

## 3. Qué rompe esto, hoy

### El `ip-restriction` no filtra: bloquea a todos

Un allowlist con CIDRs de oficina compararía contra `10.3.207.x`. Ningún
cliente legítimo entra. Y si se "arreglara" añadiendo `10.3.204.0/22` y
`10.88.0.0/14` al allowlist, entonces **pasaría absolutamente todo el tráfico
de internet**, porque todo llega con esas IPs. Sería un control decorativo — el
peor de los dos mundos.

**Por eso el `KongPlugin/openbao-ip-restriction` se retiró** del
`k8s/argocd/openbao-application.yaml`. Ver §6.

### El `rate-limiting` con `limit_by: ip` es un límite global

Mismo problema, consecuencia distinta: como todos los clientes aparecen con la
IP del nodo, comparten el mismo contador. Un `minute: 600` no es "600 por
cliente", es **600 en total repartidos entre todo el mundo** — y un solo cliente
ruidoso deja fuera a los demás (una especie de DoS accidental).

Corregido a `limit_by: service`, que expresa lo que realmente hace: un techo
global para el servicio.

### Los access logs del edge no sirven para forense

Ninguna de las 50 Ingress del cluster puede saber de dónde vino una petición.
Para cualquier investigación de un incidente (en cualquier app, no solo ésta),
los logs de Kong dicen "vino de un nodo". Es una carencia que ya existe y que
este análisis simplemente documenta.

---

## 4. Lo que sí funciona hoy, sin tocar nada compartido

**Filtrar por IP en Cloudflare**, no en Kong.

El filtro se aplica en el edge de Cloudflare, donde la IP del cliente es
visible por definición: es el peer TCP. Es inmune al SNAT porque ocurre antes.

- **IP Access Rules** (zona `l-net.io`, scope por hostname), o
- una **WAF Custom Rule**:
  `(http.host eq "vault.l-net.io" and not ip.src in {1.2.3.4 5.6.7.0/24})` → Block

Requiere que `vault.l-net.io` esté **proxied** (nube naranja), como el resto de
la zona.

**A favor:** funciona ya, no toca el data plane de Kong, y de paso suma el WAF
y la mitigación de DDoS de Cloudflare.

**En contra:** el control de acceso sale de GitOps — se gestiona en el panel de
Cloudflare y no en un MR revisable. Mitigable llevándolo a Terraform con el
provider `cloudflare` en `cloud-infra/infrastructure/`, que sería lo coherente
con el resto del repo.

**El agujero que deja:** alguien que conozca `35.192.128.2` puede saltarse
Cloudflare pegándole directo al LB con `Host: vault.l-net.io`. No es una
hipótesis remota: la IP es pública y aparece en el DNS histórico de cualquiera
de los 40 dominios. Formas de cerrarlo:

| Cómo | Viabilidad |
|---|---|
| **Authenticated Origin Pulls** de Cloudflare (mTLS al origen) + validación del cert cliente en Kong | Correcta, pero exige configurar TLS de cliente en el data plane → toca el edge |
| `ip-restriction` en Kong con los rangos de Cloudflare | **No sirve**: por el SNAT, Kong no distingue el tráfico de Cloudflare del directo |
| Un header secreto compartido que Cloudflare inyecte y Kong exija | Funciona, pero es un secreto más que custodiar y rotar |
| Aceptarlo | El atacante necesita conocer la IP del LB y el Host. Eleva el listón, no es defensa. Sigue quedando el bearer token como control real |

---

## 5. Las opciones que tocan Kong (decisión de infra)

Alcance: el Service y el data plane son **compartidos por las 50 Ingress** de
19 namespaces. Nada de esto debería colarse en el despliegue de una app.

### Opción A — `externalTrafficPolicy: Local`

```yaml
# En cloud-infra/gitops-apps/argocd-applications/kong.yaml → proxy.service
externalTrafficPolicy: Local
```

Kube-proxy deja de hacer SNAT: Kong ve la IP real del peer (el cliente si es
directo, Cloudflare si va proxied).

**Coste operativo real:** el LB solo manda tráfico a los nodos que tengan un pod
de Kong (health check por nodo). Hoy hay **2 réplicas de Kong sobre 3 nodos** →
un nodo deja de recibir tráfico, y si ambas réplicas caen en el mismo nodo, todo
el edge pasa por un único nodo. Antes de cambiar esto hay que:

- subir Kong a 3 réplicas, **o**
- añadir un `topologySpreadConstraint` que garantice reparto,
- y verificar que el `podAntiAffinity` actual (`preferred`, no `required`) no
  las junte.

**Riesgo:** cambiar `externalTrafficPolicy` reprograma el LoadBalancer de GCP.
Hay una ventana de segundos a minutos que afecta a **todo el tráfico entrante
del cluster**. Ventana de mantenimiento obligatoria.

### Opción B — `trusted_ips` + `real_ip_header` en Kong

```yaml
env:
  trusted_ips: "<rangos de Cloudflare>"   # https://www.cloudflare.com/ips/
  real_ip_header: X-Forwarded-For
  real_ip_recursive: "on"
```

Kong recupera la IP real **del header** que inyecta Cloudflare, en vez del
paquete.

**⚠️ Por sí sola es insegura, y es importante entender por qué.** Con el SNAT
activo, todo el tráfico llega a Kong desde las CIDRs internas
(`10.3.204.0/22`, `10.88.0.0/14`). Kong **no puede distinguir** una petición que
vino de Cloudflare de una que alguien mandó directa al LB. Si se ponen esas
CIDRs internas en `trusted_ips`, cualquiera puede pegarle al LB con un
`X-Forwarded-For: <ip-permitida>` falsificado y **Kong se lo va a creer**. El
allowlist se salta con un header.

Y con `vault` en DNS only no hay ningún XFF que recuperar: nadie lo inyecta.

### Opción A + B juntas — la configuración correcta

Es la única combinación que aguanta:

1. `externalTrafficPolicy: Local` → Kong ve la IP real del **peer**, que será la
   de Cloudflare cuando el host esté proxied.
2. `trusted_ips` = **los rangos publicados de Cloudflare** (no las CIDRs
   internas) + `real_ip_header: X-Forwarded-For` + `real_ip_recursive: on`.

Con eso:

- Tráfico legítimo por Cloudflare → el peer está en `trusted_ips` → Kong lee el
  XFF → obtiene la IP real del cliente. ✅
- Tráfico directo al LB con XFF falsificado → el peer **no** está en
  `trusted_ips` → Kong ignora el header y usa la IP real del atacante → el
  allowlist lo bloquea. ✅

**Beneficio colateral, y no menor:** arregla los access logs de **las 50
Ingress** del cluster. Hoy ninguna app puede saber de dónde le llegan las
peticiones.

**Coste:** los dos riesgos de la Opción A, más mantener sincronizada la lista de
rangos de Cloudflare (cambia de vez en cuando; hay endpoint público
`https://api.cloudflare.com/client/v4/ips`).

### Opción C — no depender de la IP

- **mTLS de cliente** en Kong: el plugin `mtls-auth` es de Kong **Enterprise**.
  La imagen es `kong/kong-gateway` (Enterprise) con `KONG_PLUGINS=bundled`, así
  que habría que verificar si hay licencia activa. Sustituye el control de red
  por uno criptográfico, que es estrictamente mejor.
- **No exponer `vault` públicamente**: dejar el Service en ClusterIP y quitar el
  Ingress. Los consumidores in-cluster ya usan
  `openbao-active.openbao.svc:8200`; los operadores usan `kubectl port-forward`.
  **Es la opción más segura y la más barata**, y solo se descarta si hay
  consumidores fuera del cluster que no puedan entrar por VPN. Merece estar en
  la mesa antes que cualquiera de las otras.

---

## 6. Qué se aplicó en este repo mientras tanto

En `k8s/argocd/openbao-application.yaml`:

- **Se retiró el `KongPlugin/openbao-ip-restriction`.** Dejarlo habría
  bloqueado a todos los clientes; "arreglarlo" con las CIDRs internas habría
  dejado pasar a todo internet aparentando control. Queda comentado en el
  manifiesto con el porqué y con el enlace a este documento.
- **`rate-limiting` pasa de `limit_by: ip` a `limit_by: service`**, que es lo
  que realmente hace hoy.
- **`vault.l-net.io` vuelve a ir proxied** (nube naranja), como el resto de la
  zona: es el prerrequisito para que el allowlist de Cloudflare funcione y suma
  WAF y DDoS.

Las capas de seguridad que **no** dependen de la IP y siguen en pie:

| Control | Dónde |
|---|---|
| Auth por ServiceAccount de K8s (tokens de 1h, sin secretos estáticos) | `k8s/scripts/bootstrap-auth.sh` |
| Política `ethsign-signer` con `deny` explícito sobre `ethereum/export/*` | idem |
| Audit device en disco dedicado (OpenBao deja de servir si no puede escribir) | idem |
| Revocación del root token tras el bootstrap | `k8s/docs/unseal-keys.md` |
| Rate limiting global | el Application |
| Auto-unseal por KMS: sin acceso a la key, los datos no se descifran | el Application |

---

## 7. Aviso para quien vaya a tocar `kong.yaml`

Antes de sincronizar cualquier cambio en el data plane de Kong, mirar esto:

```bash
$ git show origin/main:gitops-apps/argocd-applications/kong.yaml | grep 'tag:'
tag: "3.10.0.15"

$ kubectl -n edge-system get deploy gateway-kong \
    -o jsonpath='{.spec.template.spec.containers[0].image}'
kong/kong-gateway:3.10        # ← tag FLOTANTE, no el pinneado
```

**El cluster no corre lo que dice git**, pese a que la Application `kong`
reporta `Synced`. Un sync que reconcilie de verdad cambiaría la imagen a
`3.10.0.15` y dispararía los hooks `preUpgrade`/`postUpgrade` de Helm, que
ejecutan `kong migrations up`.

El comentario del propio `kong.yaml` documenta que **un tag flotante causó un
outage total del ingress el 2026-07-02** por exactamente ese mecanismo. Sea cual
sea la opción que se elija de §5, hay que resolver este drift **primero** y por
separado, no como efecto colateral.

---

## 8. Cómo re-verificar todo esto

```bash
# 1. ¿Qué IP ve Kong? (el experimento de §2)
MY4=$(curl -s -4 https://ifconfig.me); echo "mi IP: $MY4"
MARK="probe-$(date +%s)"
curl -sk4 -H "Host: stats.l-net.io" -A "$MARK-direct" https://35.192.128.2/ -o /dev/null
curl -s4  -A "$MARK-cf" https://stats.l-net.io/ -o /dev/null
sleep 5
for p in $(kubectl -n edge-system get pods -l app.kubernetes.io/name=kong -o name); do
  kubectl -n edge-system logs "$p" -c proxy --tail=4000 --since=3m | grep "$MARK"
done

# 2. Config del Service y del data plane
kubectl -n edge-system get svc gateway-kong-proxy \
  -o jsonpath='{.spec.type} {.spec.externalTrafficPolicy}{"\n"}'
kubectl -n edge-system get deploy gateway-kong \
  -o jsonpath='{range .spec.template.spec.containers[0].env[*]}{.name}={.value}{"\n"}{end}' \
  | grep -iE 'trusted|real_ip' || echo "sin config de real_ip"

# 3. Alcance de un cambio en Kong
kubectl get ingress -A --no-headers | wc -l          # 50 Ingress
kubectl get ingress -A --no-headers | awk '{print $1}' | sort -u | wc -l   # 19 namespaces

# 4. Reparto de las réplicas de Kong (relevante para externalTrafficPolicy: Local)
kubectl -n edge-system get pods -l app.kubernetes.io/name=kong -o wide

# 5. Drift de la imagen
kubectl -n edge-system get deploy gateway-kong -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
```

---

## Ver también

- [`kong-ingress.md`](kong-ingress.md) — el Ingress de OpenBao en detalle.
- [`deployment.md`](deployment.md) — paso 8 (DNS) y paso 11 (smoke test).
- [`operations.md`](operations.md) — qué NO cubre este despliegue.
- `cloud-infra/gitops-apps/argocd-applications/kong.yaml` — values del data plane.
- `gitlab-pipelines/docs/kong-api-gateway.md` — inventario completo del edge.
