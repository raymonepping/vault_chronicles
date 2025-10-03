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

# ADVERTISE CONTAINER-NETWORK ADDRESSES
api_addr     = "http://vault-1:8200"
cluster_addr = "http://vault-1:8201"

license_path = "/vault/config/vault.hclic"
