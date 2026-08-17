# Acceso administrativo: cómo NO quedarse afuera del vault

> **Lo que hay que saber antes de revocar cualquier cosa:** desde **OpenBao
> 2.6.0**, `bao operator generate-root` usa un endpoint **autenticado**
> (`sys/generate-root-token`). Las recovery keys **no acuñan un root token por sí
> solas**: hace falta un token válido *además* de los shares. Si revocás el
> último token administrativo sin dejar otra vía, el vault queda **sin
> administración posible** aunque tengas las 5 recovery keys en la mano.
>
> Pasó en producción el **2026-08-17**. Este documento existe para que no vuelva
> a pasar.

---

## 1. Qué cambió, con evidencia

Medido contra el cluster de GKE con **OpenBao 2.6.1**, sin token:

| Endpoint | Código | Qué significa |
|---|---|---|
| `PUT sys/generate-root/attempt` | **405** | el endpoint no autenticado de ≤2.5.x ya no existe |
| `PUT sys/generate-root-token/attempt` | **403** | el reemplazo exige token |
| `PUT sys/generate-recovery-token/attempt` | **403** | ídem |
| `PUT sys/rekey-recovery-key/init` | **404** | desapareció |
| `PUT sys/rotate/recovery/init` | **403** | su reemplazo, autenticado |
| `PUT sys/rotate/root/init` | **403** | autenticado |
| `GET sys/seal-status`, `GET sys/leader` | 200 | lo único que sigue abierto: lectura de estado |

La dirección del proyecto es explícita: el RFC
[*Delay recovery key generation for auto-unseal mechanisms and make rotation
authenticated*](https://openbao.org/community/rfcs/authenticated-rekey/) mueve
estas operaciones a `sys/rotate/*` **autenticados**. La documentación del comando
lo confirma: [`generate-root`](https://openbao.org/docs/commands/operator/generate-root/).

### Qué siguen sirviendo las recovery keys

Siguen siendo **necesarias** —son el quórum de entrada de `sys/rotate/root/*` y
`sys/rotate/recovery/*`— pero dejaron de ser **suficientes**. La custodia
repartida entre 5 personas sigue teniendo sentido; lo que ya no es cierto es que
alcance para recuperar el vault.

> **Corolario para la custodia:** el material que hay que cuidar dejó de ser solo
> las recovery keys. El acceso al `kubectl` del cluster —que es lo que emite un
> token de operador (§3)— pasó a ser igual de crítico.

---

## 2. La regla

> **Nunca revoques la última credencial administrativa sin haber probado el
> camino de vuelta primero, en ese build.**

Verificar que la revocación funcionó no dice nada sobre si podés volver a
entrar. Son dos comprobaciones distintas y la segunda va **antes**.

`bootstrap-auth.sh` la hace por vos: emite un token por el rol de operador,
comprueba que puede leer `sys/mounts`, y **aborta** si algo de eso falla. Solo
entonces sugiere revocar el root token.

---

## 3. El camino de vuelta: el rol `openbao-operator`

`bootstrap-auth.sh` crea:

- la ServiceAccount **`openbao/openbao-operator`**;
- el rol de auth de Kubernetes **`openbao-operator`**, atado a esa SA en ese
  namespace, con la política `openbao-operator`, `ttl=30m`, `max_ttl=2h`.

El control de acceso queda delegado en el **RBAC de Kubernetes**: quien pueda
hacer `kubectl create token openbao-operator -n openbao` es operador del vault.
Eso es auditable, revocable y ya existe — a diferencia de un token estático en un
`.env`.

```bash
JWT=$(kubectl -n openbao create token openbao-operator --duration=1800s)

export BAO_TOKEN=$(curl -s -d "{\"role\":\"openbao-operator\",\"jwt\":\"$JWT\"}" \
  https://vault.l-net.io/v1/auth/kubernetes/login | jq -r .auth.client_token)

# Comprobación rápida de que sirve
curl -s -H "X-Vault-Token: $BAO_TOKEN" https://vault.l-net.io/v1/sys/mounts | jq -r '.data | keys[]'
```

Con ese token podés crear políticas, roles de auth, montar engines y registrar
plugins — todo lo que `openbao-operator` habilita (ver el heredoc en
`bootstrap-auth.sh`). Lo que **no** podés es firmar: la política administrativa no
toca `ethereum/*`, a propós.

Revocalo al terminar: `bao token revoke -self`.

### Tokens de consumidor (no confundir)

Para **firmar** no hace falta nada administrativo. Cualquier SA de los namespaces
del rol `ethsign-signer` sirve:

```bash
JWT=$(kubectl create token default -n lnet-tools --duration=3600s)
curl -s -d "{\"role\":\"ethsign-signer\",\"jwt\":\"$JWT\"}" \
  https://vault.l-net.io/v1/auth/kubernetes/login | jq -r .auth.client_token
```

TTL 1h, renovable hasta 4h. Esa política **deniega** `sign-digest` y `export`
a propósito.

---

## 4. Si ya te quedaste afuera

Síntoma: `403 permission denied` en `sys/generate-root-token/attempt` sin token, y
ningún rol de auth que entregue `openbao-operator`.

Verificá primero **qué acceso te queda**, porque casi siempre los consumidores
siguen funcionando y eso cambia la urgencia:

```bash
JWT=$(kubectl create token default -n lnet-tools --duration=600s)
BT=$(curl -s -d "{\"role\":\"ethsign-signer\",\"jwt\":\"$JWT\"}" \
  https://vault.l-net.io/v1/auth/kubernetes/login | jq -r .auth.client_token)
curl -s -X LIST -H "X-Vault-Token: $BT" https://vault.l-net.io/v1/ethereum/accounts | jq
```

Si eso responde, **el servicio está intacto**: se puede firmar, pero no se puede
cambiar ninguna configuración (crear una política, conectar un consumidor nuevo,
montar un engine). No es una emergencia; es una deuda que hay que pagar antes de
que alguna address valga algo.

Y hay dos salidas.

### Opción A — re-inicializar (recomendada mientras no haya nada valioso)

Borrar los PVCs y volver a correr `init-openbao.sh` + `register-plugin.sh` +
`bootstrap-auth.sh`. **No hace falta una KMS key nueva**: la key no está
comprometida, solo hay que reconstruir el barrier.

**El costo, que hay que medir antes:** se pierden todas las llaves privadas.
Concretamente:

- toda address con fondos, o registrada como issuer / en un DID / en una
  allowlist / hardcodeada en un cliente;
- **toda address que sea `owner` de un contrato desplegado.** Ojo con el patrón
  `BaseRelayRecipient`: si el contrato hace `owner = _msgSender()`, el owner es la
  **EOA del deployer**, no el forwarder — aunque las direcciones CREATE de esa EOA
  estén vacías porque el deploy pasó por el relay. Un `eth_getCode` sobre las
  direcciones CREATE **no alcanza** para descartarlo.

`ethereum/export/accounts/*` está denegado en todas las políticas, así que **no
se puede exportar una llave para reimportarla después**. Si necesitás que una
address sobreviva a los re-inits, la llave tiene que nacer **fuera** del vault e
importarse (`POST /accounts {"privateKey":"0x…"}`) — lo que renuncia a la
propiedad de que la llave nunca sale del vault. Aceptable para un deployer de
testnet; **inaceptable** para la cuenta de `credentialHash`.

### Opción B — modo recovery (último recurso)

`bao server -recovery` arranca un nodo en modo recuperación y permite emitir un
*recovery operational token* con las recovery keys, pero ese token solo habilita
**`sys/raw`**: manipulación directa del storage. Reconstruir a mano una política o
un rol de auth ahí es trabajo de experto sobre formatos internos no
documentados, y el token no se persiste (se reemite en cada arranque).
Ver [Recovery mode](https://openbao.org/docs/concepts/recovery-mode/).

Solo tiene sentido si la Opción A está descartada porque hay llaves que **no** se
pueden perder.

---

## 5. Orden correcto de un bootstrap

El orden importa: cada paso deja habilitado el siguiente, y la revocación va
**última**.

1. `init-openbao.sh` → recovery keys + root token (a Secret Manager)
2. `register-plugin.sh` → catálogo + engine en `ethereum/`
3. `bootstrap-auth.sh` → audit, autopilot, políticas, roles, **y el auto-test del
   rol de operador**
4. Cuenta dedicada + política `ethsign-credentials` **+ su rol de auth de K8s**
   (ver [`plugin-update.md` §6](plugin-update.md#6-políticas-sin-esto-el-endpoint-queda-403))
5. `smoke-test.sh` con el token administrativo → 0 fallos, 0 saltados
6. Repartir las recovery keys entre los 5 custodios
7. **Recién ahora**: revocar el root token

Saltarse el 4 fue lo que dejó `sign-digest` inutilizable el 2026-08-17: la
política existía, el rol no, y cuando se quiso crear ya no había con qué.

---

## Ver también

- [`unseal-keys.md`](unseal-keys.md) — custodia de recovery keys y escenarios de desastre
- [`operations.md`](operations.md) — runbook del día a día
- [`redeploy-clean.md`](redeploy-clean.md) — tirar el cluster y levantarlo de cero
- [`deployment.md`](deployment.md) — el despliegue paso a paso
