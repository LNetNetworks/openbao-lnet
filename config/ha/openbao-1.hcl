ui            = true
disable_mlock = true

storage "raft" {
  path    = "/openbao/file"
  node_id = "openbao-1"

  # Auto-join: cada nodo intenta contactar a los tres (se ignora a sí mismo).
  # Resuelven por nombre de servicio dentro de la red de Docker Compose.
  retry_join { leader_api_addr = "http://openbao-1:8200" }
  retry_join { leader_api_addr = "http://openbao-2:8200" }
  retry_join { leader_api_addr = "http://openbao-3:8200" }
}

listener "tcp" {
  address         = "0.0.0.0:8200"
  cluster_address = "0.0.0.0:8201"
  tls_disable     = "true"
}

plugin_directory = "/openbao/plugins"

# Direcciones ANUNCIADAS a los demás nodos (nombre del servicio, no 127.0.0.1).
api_addr     = "http://openbao-1:8200"
cluster_addr = "http://openbao-1:8201"
