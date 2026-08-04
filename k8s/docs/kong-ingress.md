# `vault.l-net.io` a través de Kong

> Respuesta corta a "¿habrá problemas con Kong?": **no para el tráfico normal**.
> La API de OpenBao es REST sobre HTTP con headers estándar, y Kong la enruta sin
> tocar nada. Hay **tres** puntos que sí requieren atención y que se detallan
> abajo: la IP real detrás de Cloudflare, el redirect a HTTPS y el failover de
> Raft.

---

## El edge tal como está hoy

Leído del cluster real (`cloud-infra` + `gitlab-pipelines/docs/kong-api-gateway.md`):

```
Internet
   │  *.l-net.io → 35.192.128.2
   ▼
Cloudflare (TLS edge)
   ▼
Service gateway-kong-proxy (LoadBalancer :80, :443)  — ns edge-system
   │
   ├── Kong Gateway (data plane)   kong/kong-gateway:3.10.0.15  × 2
   │     modo base de datos (PostgreSQL), plugins: bundled
   └── Kong Ingress Controller     kong/kubernetes-ingress-controller:3.5.4 × 2
         lee Ingress + CRDs → configura Kong por la Admin API
   ▼
IngressClass `kong` → controller konghq.com/kic-gateway-controller
```

Unas 45 Ingress y ~40 dominios pasan por acá. `vault.l-net.io` es una más.

---

## Lo que se configura

En `k8s/argocd/openbao-application.yaml`, bajo `server.ingress`:

```yaml
ingressClassName: kong
activeService: true          # ← backend = Service openbao-active
annotations:
  konghq.com/protocols: https,http
  konghq.com/https-redirect-status-code: "301"
  konghq.com/strip-path: "false"
  konghq.com/plugins: openbao-ip-restriction,openbao-rate-limiting
hosts:
  - host: vault.l-net.io
    paths: ["/"]
```

Y dos `KongPlugin` en `extraObjects`.

### Sin bloque `tls:` — a propósito

El secret `kong-cloudflare-cert` (ns `edge-system`) es un **origin cert de
Cloudflare con SAN `*.l-net.io` y `l-net.io`**, y Kong lo sirve globalmente
(`proxy.tls.existingSecret` en el values del chart de Kong). `vault.l-net.io`
ya está cubierto. Ninguna de las Ingress del cluster declara `tls:` salvo las de
agroweb3 — no hace falta.

### `strip-path: "false"` — importante

La API de OpenBao vive bajo `/v1/...`. Si Kong recortara el path, `/v1/ethereum/
accounts` llegaría como `/ethereum/accounts` y OpenBao devolvería 404.
Con `path: /` y `strip-path: false`, la URL llega íntegra.

---

## Punto de atención 1 — la IP real detrás de Cloudflare

**Este es el riesgo principal de la parte de Kong.**

El `KongPlugin/openbao-ip-restriction` filtra por IP de origen. Si el registro
DNS de `vault.l-net.io` está **proxied** en Cloudflare (nube naranja), la
conexión que llega a Kong sale de una IP de Cloudflare, no del cliente. El
allowlist entonces:

- bloquea a todo el mundo (si no incluís los rangos de Cloudflare), o
- deja pasar a todo el mundo (si los incluís) — que es peor, porque parece que
  hay control cuando no lo hay.

### Cómo verificarlo

```bash
# Desde una IP que NO esté en el allowlist:
curl -s -o /dev/null -w '%{http_code}\n' https://vault.l-net.io/v1/sys/health
# 403 → el filtro funciona
# 200 → Kong está viendo la IP de Cloudflare, el filtro es decorativo
```

El paso 4 de `k8s/scripts/smoke-test.sh` te recuerda hacer esta prueba (no se
puede automatizar desde la misma máquina que está en el allowlist).

### Las tres salidas

| Opción | Qué implica |
|---|---|
| **DNS only (nube gris)** — recomendada | Kong ve la IP real y el allowlist funciona sin nada más. Se pierden el WAF y el ocultamiento de la IP de origen de Cloudflare. Para un endpoint con allowlist e IP ya pública (35.192.128.2 lo es para las otras 40 apps) es un intercambio razonable |
| **Proxied + `real_ip` en Kong** | Configurar `trusted_ips` de Cloudflare y `real_ip_header: X-Forwarded-For` en el data plane de Kong. Es un cambio en `gitops-apps/argocd-applications/kong.yaml` que **afecta a las 45 Ingress del cluster** — coordinar con el equipo de infra, no hacerlo por esta app sola |
| **Proxied + IP rules de Cloudflare** | Mover el allowlist a Cloudflare (WAF / IP Access Rules) y dejar el `ip-restriction` solo con los CIDRs internos del cluster. Suma el WAF, pero el control queda fuera de GitOps |

---

## Punto de atención 2 — el redirect a HTTPS

`konghq.com/https-redirect-status-code: "301"` hace que Kong responda 301 a las
peticiones que llegan por HTTP.

Si Cloudflare está en modo SSL **Flexible** (habla HTTP con el origen), Kong
recibe HTTP → responde 301 a `https://vault.l-net.io` → Cloudflare vuelve a
pedir por HTTP → **bucle de redirección**.

Este par de anotaciones es exactamente el que ya usa `stats.l-net.io`
(`gitops-apps/lnet-stats-dashboard/ingress.yaml`) y funciona, lo que indica que
la zona está en **Full**. Igual, verificar:

```bash
curl -sI http://vault.l-net.io/v1/sys/health | head -3
# HTTP/1.1 301 Moved Permanently   → bien
# ERR_TOO_MANY_REDIRECTS           → Cloudflare está en Flexible, pasarlo a Full
```

Si hubiera bucle y no se puede tocar el modo SSL de la zona: quitar la anotación
`https-redirect-status-code` y dejar solo `konghq.com/protocols: https,http`.

---

## Punto de atención 3 — el failover de Raft

El Ingress apunta al Service **`openbao-active`**, no a `openbao`.

`openbao-active` tiene el selector `openbao-active=true`, una label que OpenBao
mantiene en el pod líder gracias a `service_registration "kubernetes" {}` en el
HCL. Sus endpoints son **un solo pod**: el líder.

**Por qué así y no al Service que balancea a los tres:**

- Las escrituras (crear cuenta, firmar) solo las procesa el líder. Un standby las
  reenvía, sí, pero eso añade un salto y un modo de fallo más.
- Sin `activeService`, un standby puede responder `307 Temporary Redirect` a la
  dirección del líder — y muchos clientes HTTP no siguen 307 en POST.

**Qué pasa durante un failover:** OpenBao mueve la label al nuevo líder, el
endpoint del Service se actualiza y Kong reenruta. La ventana es de segundos.
Las peticiones en vuelo durante ese lapso fallan; el cliente debe reintentar.
Es el comportamiento normal de un cluster Raft, no un problema de Kong.

Verificación:

```bash
kubectl -n openbao get endpoints openbao-active
# debe listar exactamente UNA dirección
```

---

## Lo que NO es problema

Cosas que uno se pregunta y que están bien:

- **`X-Vault-Token`**: Kong reenvía todos los headers que no gestiona
  explícitamente. No hace falta configurar nada.
- **Timeouts**: los defaults de Kong (60s connect/read/write) son holgados —
  firmar una transacción son milisegundos. Si algún día hiciera falta:
  `konghq.com/read-timeout: "30000"` en el Ingress.
- **Tamaño del body**: las peticiones de firma son de unos pocos KB. Muy por
  debajo de cualquier límite.
- **Los CRDs `KongPlugin`**: el KIC corre con
  `CONTROLLER_ENABLE_LEGACY_KONG_CRDS=false`, lo que a primera vista parece que
  los deshabilita. Pero NaaS usa `KongPlugin/jwt-keycloak` en producción
  (`gitops-apps/naas/base/ingress/`) y funciona, así que la anotación
  `konghq.com/plugins` sigue siendo el mecanismo válido. Si aun así el plugin no
  se aplicara, se ve en los logs del KIC (ver abajo).
- **WebSockets / streaming**: OpenBao no los usa para esta API.
- **UI de OpenBao**: se sirve en `/ui/` por el mismo listener y pasa por el mismo
  Ingress sin configuración extra.

---

## Depurar

```bash
# ¿Kong recogió la Ingress?
kubectl -n edge-system logs -l app.kubernetes.io/name=kong-ingress-controller \
  --tail=100 | grep -i openbao

# ¿La ruta existe en Kong?
kubectl -n edge-system port-forward svc/gateway-kong-admin 8001:8001 &
curl -s localhost:8001/routes | jq '.data[] | select(.hosts[]? | contains("vault"))'
curl -s localhost:8001/plugins | jq '.data[] | select(.name=="ip-restriction")'

# ¿Los plugins se aplicaron a la ruta?
kubectl -n openbao get kongplugin
kubectl -n openbao describe ingress openbao

# ¿El backend responde por dentro?
kubectl -n openbao run tmp --rm -it --image=curlimages/curl --restart=Never -- \
  curl -s http://openbao-active.openbao.svc:8200/v1/sys/health
```

Tabla de códigos de `/v1/sys/health` (útil para no confundir un problema de Kong
con uno de OpenBao):

| Código | Significado |
|--------|-------------|
| 200 | Inicializado, desellado, **activo** |
| 429 | Desellado pero **standby** (no debería verse: el Ingress apunta al activo) |
| 472 | Recuperación de DR |
| 501 | **No inicializado** — falta el paso 5 del despliegue |
| 503 | **Sellado** |
| 502 desde Kong | Kong no llega al backend: el Service `openbao-active` no tiene endpoints |

---

## Ver también

- [`deployment.md`](deployment.md) — paso 8 (DNS) y paso 11 (smoke test).
- `cloud-infra/gitops-apps/argocd-applications/kong.yaml` — values del data plane.
- `cloud-infra/gitops-apps/platform/gateway/kong/` — KIC e IngressClass.
- `gitlab-pipelines/docs/kong-api-gateway.md` — inventario completo del edge.
