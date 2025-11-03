#!/usr/bin/env bash
set -euo pipefail

# ent_integrations_control_groups_05.sh
# Enterprise-only demo: Control Groups approval flow in a namespace

check="✅"; info="🧭"; warn="⚠️"
VAULT_ADDR="${VAULT_ADDR:-http://127.0.0.1:18200}"
VAULT_TOKEN="${VAULT_TOKEN:-}"
NS="${NS:-teamA}"
UP="${UP:-userpass}"
WRITER="${WRITER:-alice}"
WRITER_PASS="${WRITER_PASS:-s3cretP@ss}"
APPROVER="${APPROVER:-carol}"
APPROVER_PASS="${APPROVER_PASS:-approv3Me}"
WRITER_POLICY="cg-writer"
APPROVER_POLICY="cg-approver"
GROUP_NAME="approvers"

[[ -n "$VAULT_TOKEN" ]] || { echo "$warn VAULT_TOKEN not set"; exit 1; }
command -v vault >/dev/null || { echo "$warn missing vault"; exit 1; }
command -v jq >/dev/null || { echo "$warn missing jq"; exit 1; }

echo "$info Ensuring namespace '$NS'…"
if ! vault namespace list 2>/dev/null | grep -q "^$NS/"; then
  VAULT_NAMESPACE= vault namespace create "$NS" >/dev/null
fi

echo "$info Enable userpass (if missing)…"
vault auth list -namespace="$NS" -format=json | jq -e 'has("userpass/")' >/dev/null || vault auth enable -namespace="$NS" userpass >/dev/null

echo "$info Compose control-group writer policy…"
cat > /tmp/${WRITER_POLICY}.hcl <<'HCL'
# Control Group on WRITE to secret/prod/*
path "secret/data/prod/*" {
  capabilities = ["create", "update"]
  control_group = {
    factor "approver" {
      identity {
        group_names = ["approvers"]
      }
      approvals = 1
    }
  }
}
# allow read of its own request info if needed
path "sys/control-group/*" {
  capabilities = ["read", "update", "create"]
}
HCL

echo "$info Compose approver policy…"
cat > /tmp/${APPROVER_POLICY}.hcl <<'HCL'
# Approver needs to authorize control group requests
path "sys/control-group/*" {
  capabilities = ["read", "update", "create"]
}
HCL

vault policy write -namespace="$NS" "$WRITER_POLICY" /tmp/${WRITER_POLICY}.hcl >/dev/null
vault policy write -namespace="$NS" "$APPROVER_POLICY" /tmp/${APPROVER_POLICY}.hcl >/dev/null
echo "$check Policies ready."

echo "$info Create users…"
vault write -namespace="$NS" "auth/$UP/users/$WRITER"  password="$WRITER_PASS"  policies="$WRITER_POLICY" >/dev/null || true
vault write -namespace="$NS" "auth/$UP/users/$APPROVER" password="$APPROVER_PASS" policies="$APPROVER_POLICY" >/dev/null || true
echo "$check Users ready."

echo "$info Identity entities + group…"
W_ID="$(vault write -format=json -namespace="$NS" identity/entity name="$WRITER" policies="$WRITER_POLICY" | jq -r '.data.id')"
A_ID="$(vault write -format=json -namespace="$NS" identity/entity name="$APPROVER" policies="$APPROVER_POLICY" | jq -r '.data.id')"

UP_ACC="$(vault auth list -namespace="$NS" -format=json | jq -r '."userpass/".accessor')"
vault write -namespace="$NS" identity/entity-alias name="$WRITER"   canonical_id="$W_ID" mount_accessor="$UP_ACC" >/dev/null || true
vault write -namespace="$NS" identity/entity-alias name="$APPROVER" canonical_id="$A_ID" mount_accessor="$UP_ACC" >/dev/null || true

G_ID="$(vault write -format=json -namespace="$NS" identity/group name="$GROUP_NAME" policies="$APPROVER_POLICY" member_entity_ids="$A_ID" | jq -r '.data.id')"
echo "$check Group '$GROUP_NAME' id: $G_ID"

cat <<EOF

$check Setup complete.

# 1) Writer attempts a protected write (requires approval):
  VAULT_NAMESPACE=$NS vault login -method=userpass username="$WRITER" password="$WRITER_PASS"
  VAULT_NAMESPACE=$NS vault kv put secret/prod/payroll token="super-secret"

=> EXPECT: Response does not immediately succeed. It includes a Control Group request,
           typically with a token or request id indicating pending approval.

# 2) Approver authorizes the request:
  VAULT_NAMESPACE=$NS vault login -method=userpass username="$APPROVER" password="$APPROVER_PASS"

Now authorize the control-group request. Depending on your Vault version,
use one of these (the CLI will guide you if the request token is wrapped):

  VAULT_NAMESPACE=$NS vault write sys/control-group/authorize \
    accessor="\$(vault auth list -namespace=$NS -format=json | jq -r 'last | .accessor')" \
    request_id="<REQUEST_ID_FROM_ALICE_OUTPUT>"

Or unwrap the wrapped token given to Alice and re-run the operation as instructed.

# 3) Writer completes:
Re-run the original write OR follow the unwrap flow printed in step 1.

EOF
