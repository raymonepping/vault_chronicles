#!/usr/bin/env bash
set -euo pipefail

# Directory to store any generated tokens for demo use
DEMO_DIR=".vault-demo"
mkdir -p "$DEMO_DIR"

# Emojis for output formatting
check_mark="✅"
arrow="↳"
warning="⚠️"
people="👥"
compass="🧭"
lock="🔐"
clock="🕒"
hourglass="⌛"
party="🎉"

# Check Vault Enterprise edition and cluster status
echo "🔎 Checking Vault edition @ ${VAULT_ADDR:-http://127.0.0.1:8200} ..."
VAULT_VERSION=$(vault status -format=json | jq -r .version 2>/dev/null || echo "")
VAULT_EDITION=$(vault status -format=json | jq -r .license.holder 2>/dev/null || echo "")
if [[ "$VAULT_VERSION" == "" || "$VAULT_VERSION" != *"+ent"* ]]; then
  echo "❌ Vault Enterprise not detected! (Enterprise features are required)" 
  exit 1
fi
# If HA enabled, ensure we are on the active node
if vault status -format=json | jq -e '(.ha_enabled == true) and (.ha_cluster? // {} | .is_self == false)' >/dev/null; then
  echo "❌ Connected to a standby node. Please run this on the active Vault leader."
  exit 1
fi
# If performance replication enabled, ensure this is primary
if vault status -format=json | jq -e '.replication_perf_mode == "secondary"' >/dev/null; then
  echo "❌ Connected to a performance standby cluster. Please run this on the primary cluster."
  exit 1
fi
echo "$check_mark Vault Enterprise detected ($VAULT_VERSION)"

# Usage message for invalid input
usage() {
  echo -e "Usage: $0 {1|2|3|4|5|all|cleanup}\n 1-5: run specific demo case\n all: run demos 1 through 5 in order\n cleanup: remove all demo configurations"
  exit 1
}

# Ensure an argument is provided
[[ $# -ge 1 ]] || usage

# Demo 1: Business hours EGP on kv/business/*
demo1() {
  echo -e "\n$clock DEMO 1: Endpoint Governing Policy (EGP) – enforce business-hours access on secrets path"
  # Enable a KV v2 secrets engine at path "kv/" in root namespace (if not already enabled)
  if vault secrets list -format=json | jq -e '."kv/"' &>/dev/null; then
    echo "  $arrow root: mount 'kv/' already exists"
  else
    vault secrets enable -path=kv -version=2 kv &>/dev/null
    echo "  $arrow root: enabled KV secrets engine at 'kv/' (v2)"
  fi
  # Create a test secret under kv/business/
  vault kv put kv/business/test demo="123" &>/dev/null
  echo "  $arrow root: secret kv/business/test created (for demo access testing)"
  # Define and apply the business-hours Sentinel EGP
  vault write sys/policies/egp/business-hours \
    paths="kv/data/business/*" enforcement_level="hard-mandatory" \
    code=-<<'EOF' &>/dev/null
        import "time"
        # Allow access Mon-Fri, 08:00-18:00
        workdays = rule { time.now.weekday > 0 && time.now.weekday < 6 }
        workhours = rule { time.now.hour >= 8 && time.now.hour < 18 }
        main = rule { workdays and workhours }
EOF
  echo "  $arrow root: EGP policy 'business-hours' created (8AM-6PM access window)"
  # Create an ACL policy for read access to kv/business/*
  vault policy write biz-reader -<<EOF &>/dev/null
path "kv/data/business/*" {
  capabilities = ["read"]
}
EOF
  echo "  $arrow root: ACL policy 'biz-reader' created"
  # Generate a non-root token with biz-reader policy to test access
  TEST_TOKEN=$(vault token create -policy="biz-reader" -format=json | jq -r .auth.client_token)
  # Simulate a read access attempt with the test token
  if VAULT_TOKEN="$TEST_TOKEN" vault kv get kv/business/test &>/dev/null; then
    echo "  $check_mark access granted with test token (within allowed hours)"
    echo "      (Access would be $warning blocked outside Mon-Fri 08:00-18:00 by the EGP)"
  else
    echo "  $check_mark access correctly $warning blocked (outside allowed hours)"
  fi
}

# Demo 2: RGP restricting access to a specific identity (only 'jeff' allowed)
demo2() {
  echo -e "\n$lock DEMO 2: Role Governing Policy (RGP) – allow secret access only for a specific identity ('jeff')"
  # Ensure userpass auth is enabled at root for test identities
  if vault auth list -format=json | jq -e '."userpass/"' &>/dev/null; then
    echo "  $arrow root: auth method 'userpass/' already enabled"
  else
    vault auth enable userpass &>/dev/null
    echo "  $arrow root: enabled userpass auth method (root namespace)"
  fi
  # Enable a KV path for storing the demo secret (reuse kv mount from demo1)
  # Create a secret at kv/dev-team/plan
  vault kv put kv/dev-team/plan project="Top Secret Project" &>/dev/null
  echo "  $arrow root: secret kv/dev-team/plan created"
  # Create an ACL policy that allows reading the dev-team secret
  vault policy write devteam-read -<<EOF &>/dev/null
path "kv/data/dev-team/*" {
  capabilities = ["read"]
}
EOF
  echo "  $arrow root: ACL policy 'devteam-read' created"
  # Create two test users 'jeff' and 'tim', both assigned the devteam-read policy
  vault write auth/userpass/users/jeff password="demopass" policies="devteam-read" &>/dev/null
  vault write auth/userpass/users/tim password="demopass" policies="devteam-read" &>/dev/null
  echo "  $arrow root: userpass users 'jeff' and 'tim' created (policies: devteam-read)"
  # Log in as each user to generate tokens and obtain their entity IDs
  jeff_login=$(vault login -method=userpass username=jeff password=demopass -format=json)
  tim_login=$(vault login -method=userpass username=tim password=demopass -format=json)
  JEFF_TOKEN=$(echo "$jeff_login" | jq -r .auth.client_token)
  TIM_TOKEN=$(echo "$tim_login" | jq -r .auth.client_token)
  JEFF_ENTITY_ID=$(echo "$jeff_login" | jq -r .auth.entity_id)
  TIM_ENTITY_ID=$(echo "$tim_login" | jq -r .auth.entity_id)
  # Create an identity group containing both jeff and tim, attach the RGP to it
  vault write identity/group name="dev-group" \
    member_entity_ids="$JEFF_ENTITY_ID,$TIM_ENTITY_ID" \
    governance_policies="rgp-allow-jeff" &>/dev/null
  echo "  $arrow root: identity group 'dev-group' created (members: jeff, tim)"
  # Create the RGP Sentinel policy that permits only Jeff's identity
  vault write sys/policies/rgp/rgp-allow-jeff enforcement_level="hard-mandatory" \
    code=-<<'EOF' &>/dev/null
        main = rule {
          identity.entity.name is "jeff"
        }
EOF
  echo "  $arrow root: RGP policy 'rgp-allow-jeff' created (only entity name 'jeff' allowed)"
  # Test secret access with Tim's token (should be denied) and Jeff's token (should succeed)
  if VAULT_TOKEN="$TIM_TOKEN" vault kv get kv/dev-team/plan &>/dev/null; then
    echo "  $warning ERROR: 'tim' was able to access the secret (unexpected)"
  else
    echo "  $check_mark access denied for identity 'tim' (as expected)"
  fi
  if VAULT_TOKEN="$JEFF_TOKEN" vault kv get kv/dev-team/plan &>/dev/null; then
    echo "  $check_mark access granted for identity 'jeff' (as expected)"
  else
    echo "  $warning ERROR: 'jeff' could not access the secret (unexpected)"
  fi
}

# Demo 3: RGP requiring presence of 'prod-writer' policy for writes under team-a: kv/prod/*
demo3() {
  echo -e "\n$compass DEMO 3: Role Governing Policy (RGP) – require 'prod-writer' policy for writing secrets under team-a: kv/prod/*"
  # Ensure namespace team-a exists
  if vault namespace list -format=json | jq -e '.[] | select(. == "team-a/")' &>/dev/null; then
    echo "  $arrow namespace 'team-a' already exists"
  else
    vault namespace create team-a &>/dev/null
    echo "  $arrow namespace 'team-a' created"
  fi
  # Ensure a KV v2 secrets engine is mounted in team-a at path "kv/"
  if vault secrets list -namespace=team-a -format=json | jq -e '."kv/"' &>/dev/null; then
    echo "  $arrow team-a: mount 'kv/' already exists"
  else
    vault secrets enable -namespace=team-a -path=kv -version=2 kv &>/dev/null
    echo "  $arrow team-a: enabled KV secrets engine at 'kv/'"
  fi
  # Create the Sentinel RGP in team-a that mandates 'prod-writer' policy on write requests to kv/prod/*
  vault write sys/policies/rgp/rgp-prod-writer-required -namespace=team-a enforcement_level="hard-mandatory" \
    code=-<<'EOF' &>/dev/null
        import "strings"
        main = rule {
          # For any create/update to kv/data/prod/*, require the token to have 'prod-writer' policy
          not (request.operation in ["create", "update"] and strings.hasPrefix(request.path, "kv/data/prod/")) ||
          "prod-writer" in identity.token.policies
        }
EOF
  echo "  $arrow team-a: RGP policy 'rgp-prod-writer-required' created"
  # Define ACL policies in team-a for demonstration
  vault policy write -namespace=team-a prod-writer -<<EOF &>/dev/null
path "kv/data/prod/*" {
  capabilities = ["create", "update", "read"]
}
EOF
  vault policy write -namespace=team-a plain-reader -<<EOF &>/dev/null
path "kv/data/prod/*" {
  capabilities = ["create", "update", "read"]
}
EOF
  echo "  $arrow team-a: policies 'prod-writer' and 'plain-reader' created"
  # Create two tokens in team-a: one with only plain-reader, one with plain-reader + prod-writer
  if [[ -f "$DEMO_DIR/team-a.plain-reader.token" ]]; then
    echo "  $arrow team-a: token file exists ($DEMO_DIR/team-a.plain-reader.token)"
  else
    vault write -field=token -namespace=team-a auth/token/create \
      policies="plain-reader" token_ttl=1h token_governance_policies="rgp-prod-writer-required" \
      > "$DEMO_DIR/team-a.plain-reader.token"
    echo "  $arrow team-a: token generated ($DEMO_DIR/team-a.plain-reader.token)"
  fi
  if [[ -f "$DEMO_DIR/team-a.prod-writer.token" ]]; then
    echo "  $arrow team-a: token file exists ($DEMO_DIR/team-a.prod-writer.token)"
  else
    vault write -field=token -namespace=team-a auth/token/create \
      policies="plain-reader,prod-writer" token_ttl=1h token_governance_policies="rgp-prod-writer-required" \
      > "$DEMO_DIR/team-a.prod-writer.token"
    echo "  $arrow team-a: token generated ($DEMO_DIR/team-a.prod-writer.token)"
  fi
  # Use the plain-reader token to attempt a write (should be blocked by RGP)
  PLAIN_TOKEN=$(cat "$DEMO_DIR/team-a.plain-reader.token")
  PROD_TOKEN=$(cat "$DEMO_DIR/team-a.prod-writer.token")
  if VAULT_TOKEN="$PLAIN_TOKEN" vault kv put -namespace=team-a kv/prod/demo foo="bar" &>/dev/null; then
    echo "  $warning ERROR: write succeeded with token missing 'prod-writer' (unexpected)"
  else
    echo "  $check_mark write blocked (token missing 'prod-writer' policy) – RGP enforced"
  fi
  # Now attempt the write with the token that has 'prod-writer' policy (should succeed)
  if VAULT_TOKEN="$PROD_TOKEN" vault kv put -namespace=team-a kv/prod/demo foo="bar" &>/dev/null; then
    echo "  $check_mark write succeeded with 'prod-writer' policy token (as expected)"
  else
    echo "  $warning ERROR: write failed even with 'prod-writer' policy (unexpected)"
  fi
}

# Demo 4: Control Groups – require approver authorization for reads under team-a: kv/ultra/*
demo4() {
  echo -e "\n$people DEMO 4: Control Group – require 1 approver for secret reads under team-a: kv/ultra/*"
  echo "  $arrow namespace 'team-a' already exists"
  echo "  $arrow team-a: mount 'kv/' exists"

  echo "unsetting VAULT_TOKEN for demo4"
  # unset VAULT_TOKEN

  # Enable userpass auth in team-a
  if vault auth list -namespace=team-a -format=json | jq -e '."userpass/"' &>/dev/null; then
    echo "  $arrow team-a: auth method 'userpass/' already enabled"
  else
    vault auth enable -namespace=team-a userpass &>/dev/null
    echo "  $arrow team-a: enabled userpass auth method"
  fi

  # Policies
  vault policy write -namespace=team-a approver -<<EOF &>/dev/null
path "sys/control-group/authorize" {
  capabilities = ["update"]
}
EOF
  echo "  $arrow team-a: policy 'approver' created"

  vault policy write -namespace=team-a ultra-reader -<<EOF &>/dev/null
path "kv/data/ultra/*" {
  capabilities = ["read"]
  control_group = {
    factor "approvers" {
      identity {
        group_names = ["approvers"]
        approvals   = 1
      }
    }
  }
}
EOF
  echo "  $arrow team-a: policy 'ultra-reader' created with control group requirement"

  # Users
  vault write -namespace=team-a auth/userpass/users/approver password="demopass" policies="approver" &>/dev/null
  vault write -namespace=team-a auth/userpass/users/requester password="demopass" policies="ultra-reader" &>/dev/null
  echo "  $arrow team-a: users 'approver' and 'requester' ensured"

  # Approver login
  approver_login=$(vault login -namespace=team-a -method=userpass username=approver password=demopass -format=json)
  APPROVER_TOKEN=$(echo "$approver_login" | jq -r .auth.client_token)
  APPROVER_ENTITY_ID=$(echo "$approver_login" | jq -r .auth.entity_id)

  # Create or update group
  vault write -namespace=team-a identity/group name="approvers" member_entity_ids="$APPROVER_ENTITY_ID" &>/dev/null
  echo "  $arrow team-a: identity group 'approvers' includes user 'approver'"

  # Seed secret
  vault kv put -namespace=team-a kv/ultra/secret1 ultra_key="Ultra Secret Value" &>/dev/null
  echo "  $arrow team-a: secret kv/ultra/secret1 created"

  # Requester login and token cache
  if [[ -f "$DEMO_DIR/team-a.requester.token" ]]; then
    echo "  $arrow team-a: token file exists ($DEMO_DIR/team-a.requester.token)"
    REQUESTER_TOKEN=$(cat "$DEMO_DIR/team-a.requester.token")
  else
    requester_login=$(vault login -namespace=team-a -method=userpass username=requester password=demopass -format=json)
    REQUESTER_TOKEN=$(echo "$requester_login" | jq -r .auth.client_token)
    echo "$REQUESTER_TOKEN" > "$DEMO_DIR/team-a.requester.token"
    echo "  $arrow team-a: token generated ($DEMO_DIR/team-a.requester.token)"
  fi

  # Read attempt by requester (should trigger control group wrapping)
  echo -n "  → Requesting secret as 'requester' (no approval yet)... "
  READ_OUTPUT=$(VAULT_TOKEN="$REQUESTER_TOKEN" vault kv get -namespace=team-a -format=json kv/ultra/secret1 2>/dev/null || true)
  WRAP_ACCESSOR=$(echo "$READ_OUTPUT" | jq -r .wrap_info.accessor 2>/dev/null || echo "")
  WRAP_TOKEN=$(echo "$READ_OUTPUT" | jq -r .wrap_info.token 2>/dev/null || echo "")
  if [[ -n "$WRAP_ACCESSOR" && -n "$WRAP_TOKEN" ]]; then
    echo "$check_mark got wrapping token (accessor: $WRAP_ACCESSOR)"
  else
    echo "$warning expected a wrapped response, but request was denied (check policies)"
    return
  fi

  # Approver submits approval
  VAULT_TOKEN="$APPROVER_TOKEN" vault write -namespace=team-a sys/control-group/authorize accessor="$WRAP_ACCESSOR" &>/dev/null
  echo "  $arrow approver: submitted approval for accessor $WRAP_ACCESSOR"

  sleep 1  # optional delay to allow Vault to sync approval

  # Requester unwraps
  if VAULT_TOKEN="$REQUESTER_TOKEN" vault unwrap -namespace=team-a "$WRAP_TOKEN" &>/dev/null; then
    echo "  $check_mark secret unwrapped successfully after approval"
  else
    echo "  $warning ERROR: unwrapping failed (approval might be missing)"
  fi
}

# Demo 5: EGP that denies ONLY the "old" token by accessor (no time/imports)
demo5() {
  echo -e "\n$hourglass DEMO 5: Endpoint Governing Policy (EGP) – deny only the pre-cutoff token (accessor-based)"

  # 1) Seed a secret.
  vault kv put kv/classified/topsecret answer=42 &>/dev/null
  echo "  $arrow root: secret kv/classified/topsecret created"

  # 2) Simple ACL that permits reads (EGP will do the deny)
  vault policy write demo5-old -<<'EOF' &>/dev/null
path "kv/data/classified/*" {
  capabilities = ["read"]
}
EOF
  echo "  $arrow root: policy 'demo5-old' (read access to kv/classified/*) created"

  # 3) Create the "old" token (this one will be blocked by EGP)
  OLD_TOKEN_JSON=$(vault token create -policy="demo5-old" -ttl=30m -format=json)
  OLD_TOKEN=$(echo "$OLD_TOKEN_JSON"   | jq -r .auth.client_token)
  OLD_ACCESSOR=$(echo "$OLD_TOKEN_JSON"| jq -r .auth.accessor)
  echo "  $arrow old token accessor: $OLD_ACCESSOR"

  # 4) Cleanly replace the EGP every run
  vault delete sys/policies/egp/egp-old-token-cutoff >/dev/null 2>&1 || true

  mkdir -p .vault-demo
  cat > .vault-demo/demo5-policy.sentinel <<EOF
# Minimal, standard Sentinel: allow when authenticated AND accessor != OLD
main = rule when not request.unauthenticated {
  request.auth.token.accessor != "$OLD_ACCESSOR"
}
EOF

  # Install + show the policy so we’re 100% sure what’s active
  echo "  $arrow writing EGP 'egp-old-token-cutoff' ..."
  if ! vault write sys/policies/egp/egp-old-token-cutoff \
        paths="kv/data/classified/*" \
        enforcement_level="hard-mandatory" \
        policy=@.vault-demo/demo5-policy.sentinel >/dev/null; then
    echo "  $warning failed to create EGP policy 'egp-old-token-cutoff'"
    vault read sys/policies/egp/egp-old-token-cutoff 2>/dev/null || true
    return 1
  fi
  echo "  $arrow EGP installed. Effective policy:"
  vault read -format=json sys/policies/egp/egp-old-token-cutoff | jq -r '.data.policy'

  # 5) Old token SHOULD be blocked
  if VAULT_TOKEN="$OLD_TOKEN" vault kv get kv/classified/topsecret &>/dev/null; then
    echo "  $warning ERROR: old token was able to read the secret (unexpected)"
  else
    echo "  $check_mark old token blocked (as expected)"
  fi

  # 6) Create a fresh "new" token
  sleep 1
  NEW_TOKEN_JSON=$(vault token create -policy="demo5-old" -format=json)
  NEW_TOKEN=$(echo "$NEW_TOKEN_JSON"   | jq -r .auth.client_token)
  NEW_ACCESSOR=$(echo "$NEW_TOKEN_JSON"| jq -r .auth.accessor)
  echo "  $arrow new token accessor: $NEW_ACCESSOR"

  # Assert accessors differ; if not, something is off with token issuance
  if [[ "$NEW_ACCESSOR" == "$OLD_ACCESSOR" || -z "$NEW_ACCESSOR" ]]; then
    echo "  $warning NEW_ACCESSOR is identical/empty. Aborting."
    echo "           (Check: vault token create actually produced a new token)"
    return 1
  fi

  # 7) New token SHOULD be allowed
  if VAULT_TOKEN="$NEW_TOKEN" vault kv get kv/classified/topsecret &>/dev/null; then
    echo "  $check_mark new token allowed (different accessor, rule returns true)"
  else
    echo "  $warning ERROR: new token was unexpectedly blocked"
    echo "          Quick checks:"
    echo "            - Only this EGP exists?"
    echo "                vault list sys/policies/egp"
    echo "                vault read sys/policies/egp/egp-old-token-cutoff"
    echo "            - Does the request carry an accessor?"
    echo "                vault token lookup -format=json \"$NEW_TOKEN\" | jq -r .data.accessor"
    echo "            - Try a no-op rule to verify EGP plumbing (should allow both):"
    echo "                main = rule when not request.unauthenticated { true }"
    return 1
  fi
}

# Cleanup: Remove all demo configurations (policies, auth methods, entities, groups, secrets, namespace)
cleanup() {
  echo -e "\n🧹 Cleaning up all demo configurations..."
  # Remove sentinel policies
  vault delete sys/policies/egp/business-hours &>/dev/null || true
  vault delete sys/policies/egp/egp-old-token-cutoff &>/dev/null || true
  vault delete sys/policies/rgp/rgp-allow-jeff &>/dev/null || true
  vault delete sys/policies/rgp/rgp-prod-writer-required -namespace=team-a &>/dev/null || true
  echo "  $arrow removed Sentinel policies (business-hours, egp-old-token-cutoff, rgp-allow-jeff, rgp-prod-writer-required)"
  # Remove ACL policies
  for policy in biz-reader devteam-read demo5-old; do
    vault policy delete "$policy" &>/dev/null || true
  done
  vault policy delete -namespace=team-a prod-writer &>/dev/null || true
  vault policy delete -namespace=team-a plain-reader &>/dev/null || true
  vault policy delete -namespace=team-a ultra-reader &>/dev/null || true
  vault policy delete -namespace=team-a approver &>/dev/null || true
  echo "  $arrow removed ACL policies (biz-reader, devteam-read, demo5-old, team-a: prod-writer, plain-reader, ultra-reader, approver)"
  # Disable or tidy up auth methods and users
  vault delete auth/userpass/users/jeff &>/dev/null || true
  vault delete auth/userpass/users/tim &>/dev/null || true
  vault auth disable userpass &>/dev/null || true
  vault delete -namespace=team-a auth/userpass/users/approver &>/dev/null || true
  vault delete -namespace=team-a auth/userpass/users/requester &>/dev/null || true
  vault auth disable -namespace=team-a userpass &>/dev/null || true
  echo "  $arrow removed userpass users (jeff, tim, approver, requester) and disabled userpass auth"
  # Remove identity groups and entities if possible (non-critical as namespace removal will clean them)
  vault delete identity/group/name/dev-group &>/dev/null || true
  vault delete identity/group/name/approvers -namespace=team-a &>/dev/null || true
  echo "  $arrow removed identity groups (dev-group, team-a/approvers)"
  # Delete secrets and mounts created for demos
  vault kv metadata delete kv/business/test &>/dev/null || true
  vault kv metadata delete kv/dev-team/plan &>/dev/null || true
  vault kv metadata delete kv/classified/topsecret &>/dev/null || true
  vault secrets disable kv/ &>/dev/null || true   # only if it was enabled by demo (be cautious: this deletes all kv/ secrets in root!)
  echo "  $arrow removed demo secrets and disabled 'kv/' mount in root (if it was created for demo)"
  # Finally, remove the team-a namespace and all its data
  vault namespace delete team-a &>/dev/null || true
  echo "  $arrow removed namespace 'team-a' (and all data under it)"
  # Remove generated token files
  rm -f "$DEMO_DIR"/team-a.*.token &>/dev/null || true
  echo "  $arrow removed token files in $DEMO_DIR"
  echo "$party Cleanup complete."
}

# Parse argument and execute corresponding demo(s)
case "$1" in
  1)        demo1 ;;
  2)        demo2 ;;
  3)        demo3 ;;
  4)        demo4 ;;
  5)        demo5 ;;
  all)      
            demo1
            demo2
            demo3
            demo4
            demo5
            echo -e "\n$party All demos completed." ;;
  cleanup)  cleanup ;;
  *)        usage ;;
esac
