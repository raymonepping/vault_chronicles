# Read the KV v2 data path
path "secret/data/app/backend" {
  capabilities = ["read"]
}

# Quiet the UI preflight checks
path "sys/internal/ui/mounts/secret/*" {
  capabilities = ["read"]
}
