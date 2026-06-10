ui            = true
disable_mlock = true

storage "file" {
  path = "/openbao/file"
}

listener "tcp" {
  address     = "0.0.0.0:8200"
  tls_disable = "true"
}

# Directory containing external plugin binaries (the ethsign binary lives here).
plugin_directory = "/openbao/plugins"

# Required so the plugin process can talk back to the OpenBao server at mount time.
api_addr = "http://127.0.0.1:8200"
