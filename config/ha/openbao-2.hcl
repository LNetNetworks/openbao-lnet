ui            = true
disable_mlock = true

storage "raft" {
  path    = "/openbao/file"
  node_id = "openbao-2"

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

api_addr     = "http://openbao-2:8200"
cluster_addr = "http://openbao-2:8201"
