ui            = true
disable_mlock = true

listener "tcp" {
  address         = "0.0.0.0:8200"
  cluster_address = "0.0.0.0:8201"
  tls_disable     = 1
}

storage "raft" {
  path    = "/vault/data"
  node_id = "node-3"

  retry_join {
    leader_api_addr = "http://vault-1:8200"
  }
}

audit "file" {
  file_path = "/vault/logs/vault_audit.log"
}

api_addr     = "http://vault-3:8200"
cluster_addr = "http://vault-3:8201"

license_path = "/vault/config/vault.hclic"
