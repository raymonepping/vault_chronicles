ui            = true
disable_mlock = true

listener "tcp" {
  address         = "0.0.0.0:8200"
  cluster_address = "0.0.0.0:8201"
  tls_disable     = 1
}

storage "raft" {
  path    = "/vault/data"
  node_id = "node-1"
}

audit "file" {
  file_path = "/vault/logs/vault_audit.log"
}

# Explicit external addresses to match host port mapping
api_addr     = "http://127.0.0.1:18200"
cluster_addr = "http://127.0.0.1:18201"

license_path = "/vault/config/vault.hclic"
