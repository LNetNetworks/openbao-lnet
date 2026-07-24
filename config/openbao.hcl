ui            = true
disable_mlock = true

# Integrated Storage (Raft) — OpenBao's recommended production backend.
# Provides native HA and requires no external database. Single-node here for the
# POC; in production run a 3/5-node StatefulSet in Kubernetes (one PVC per pod).
storage "raft" {
  path    = "/openbao/file"
  node_id = "openbao-lnet-1"
}

listener "tcp" {
  address     = "0.0.0.0:8200"
  tls_disable = "true"
}

# Directory containing external plugin binaries (the ethsign binary lives here).
plugin_directory = "/openbao/plugins"

# Required so the plugin process can talk back to the OpenBao server at mount time.
api_addr = "http://127.0.0.1:8200"

# Required by Raft: address other cluster nodes use to reach this node.
# Even single-node Raft needs it (uses the cluster port, 8201 by default).
cluster_addr = "http://127.0.0.1:8201"
