# Políticas de ejemplo para separar la firma de digests crudos de la firma de
# transacciones. La razón está en plan-digest/README.md (sección Seguridad):
# quien puede firmar digests arbitrarios puede firmar CUALQUIER transacción,
# porque el hash de una tx es solo keccak256(RLP(tx)) calculado off-chain.
#
# Regla: la cuenta que firma credentialHash NO debe tener saldo ni ser la misma
# que firma transacciones on-chain.
#
# Reemplazar las direcciones por las reales. Aplicar con:
#   bao policy write ethsign-credentials  plan-digest/policies/ethsign-digest.hcl
# (partir el archivo en dos, o usar -  y pegar solo el bloque que corresponda)

# ---------------------------------------------------------------------------
# Policy `ethsign-credentials` — solo firma digests, y solo con la cuenta
# dedicada a credenciales. No puede firmar transacciones ni exportar claves.
# ---------------------------------------------------------------------------
path "ethereum/accounts/0xCUENTA_CREDENCIALES/sign-digest" {
  capabilities = ["create", "update"]
}

path "ethereum/accounts/0xCUENTA_CREDENCIALES" {
  capabilities = ["read"]
}

# Denegación explícita: aunque otra policy del token lo permita, este path
# queda cerrado (deny gana siempre en OpenBao/Vault).
path "ethereum/export/accounts/*" {
  capabilities = ["deny"]
}

path "ethereum/accounts/+/sign" {
  capabilities = ["deny"]
}

# ---------------------------------------------------------------------------
# Policy `ethsign-transactions` — el rol que ya existe hoy: firma transacciones
# con las cuentas con saldo, y NO puede pedir firmas de digests crudos.
# ---------------------------------------------------------------------------
# path "ethereum/accounts/0xCUENTA_CON_SALDO/sign" {
#   capabilities = ["create", "update"]
# }
#
# path "ethereum/accounts/+/sign-digest" {
#   capabilities = ["deny"]
# }
#
# path "ethereum/export/accounts/*" {
#   capabilities = ["deny"]
# }
