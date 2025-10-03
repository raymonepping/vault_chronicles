# Use an available enterprise tag from hashicorp/vault-enterprise
FROM hashicorp/vault-enterprise:latest

# Bake your config at the standard path
COPY vault-config.hcl /vault/config/config.hcl
# Optional: copy license file alongside (we’ll reference it in config)
COPY vault.hclic /vault/config/vault.hclic

EXPOSE 8200

# Entrypoint in base image is already set to vault
# Keep the command consistent with your OSS image
CMD ["server", "-config=/vault/config/config.hcl"]
