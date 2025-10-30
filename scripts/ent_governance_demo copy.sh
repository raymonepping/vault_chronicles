#!/usr/bin/env bash
set -euo pipefail

# ╭──────────────────────────────────────────────────────────────────────────────╮
# │ Vault Enterprise Governance Demo (idempotent)                                │
# │                                                                              │
# │ Demos:                                                                       │
# │  1) Namespaces & per-namespace isolation (KV + ACLs + tokens)                |
# │  2) Endpoint Governance Policy (EGP): deny deletes on team-a KV              │
# │  3) Request Governance Policy (RGP): require policy `prod-writer`            │
# │  4) Control Groups: approval required for ultra-sensitive path               │
# │  5) Per-namespace auth: userpass in team-b, isolated access                  │
# │                                                                              │
# │ Usage:                                                                       │
# │   ./ent_governance_demo.sh all       # run everything                        │
# │   ./ent_governance_demo.sh 1 3 5     # run selected demos                    │
# │   (or set RUN_DEMO_x=true in .env)                                           │
# │   ./ent_governance_demo.sh --help     # show help                             │
# │                                                                              │
# │ Notes: Governance policies here use SENTINEL with the `strings` import.      │
# │        Paths are limited to ["kv/*"] to avoid catching sys/* lookups.        │
# ╰──────────────────────────────────────────────────────────────────────────────╯

# --- prerequisites -------------------------------------------------------------
need() { command -v "$1" >/dev/null 2>&1 || { echo "❌ Missing dependency: $1"; exit 1; }; }
need vault
need jq

usage() {
  cat <<'EOF'
Vault Enterprise Governance Demo

Demos:
  1  Namespaces & isolation (KV + ACLs + tokens)
  2  EGP: Deny deletes on team-a KV
  3  RGP: Require 'prod-writer' for kv/data/prod/*
  4  Control Groups: 1 approver for kv/data/ultra/*
  5  Per-namespace auth: userpass in team-b

Run:
  ./ent_governance_demo.sh all
  ./ent_governance_demo.sh 1 3 5

.env (optional):
  VAULT_ADDR=http://127.0.0.1:18200
  VAULT_TOKEN=hvs.xxxxx
  RUN_DEMO_1=true
  RUN_DEMO_2=true
  RUN_DEMO_3=true
  RUN_DEMO_4=true
  RUN_DEMO_5=true
EOF
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  usage
  exit 0
fi

# --- safe .env loader ----------------------------------------------------------
# Loads only lines shaped like KEY=VALUE (ignores comments/blank/invalid keys).
load_dotenv() {
  local dotenv=".env"
  [[ -f "$dotenv" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    # trim leading/trailing spaces
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    # skip comments/blank
    [[ -z "$line" || "${line:0:1}" == "#" ]] && continue
    # require KEY=VALUE (KEY must be valid shell identifier)
    if [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
      key="${BASH_REMATCH[1]}"
      val="${BASH_REMATCH[2]}"
      # Strip surrounding single/double quotes if present (preserve inner '=')
      if [[ "$val" =~ ^\"(.*)\"$ ]]; then
        val="${BASH_REMATCH[1]}"
      elif [[ "$val" =~ ^\'(.*)\'$ ]]; then
        val="${BASH_REMATCH[1]}"
      fi
      export "$key=$val"
    fi
  done < "$dotenv"
}
load_dotenv

VAULT_ADDR="${VAULT_ADDR:-http://127.0.0.1:18200}"
VAULT_TOKEN="${VAULT_TOKEN:-}"
: "${VAULT_TOKEN:?Set VAULT_TOKEN in .env or environment}"

# namespace & names we’ll use
NS_A="team-a"
NS_B="team-b"
MOUNT_A="kv"
MOUNT_B="kv"

# Utility: talk to Vault with global addr/token
v() { VAULT_ADDR="$VAULT_ADDR" VAULT_TOKEN="$VAULT_TOKEN" vault "$@"; }

# --- sanity: enterprise? -------------------------------------------------------
echo "🔎 Checking Vault edition @ $VAULT_ADDR ..."
HEALTH="$(v status -format=json || true)"
if [[ -z "$HEALTH" ]]; then
  echo "❌ Cannot reach Vault at $VAULT_ADDR"
  exit 1
fi
VER="$(echo "$HEALTH" | jq -r '.version')"
if [[ "$VER" != *"+ent"* ]]; then
  echo "❌ Enterprise-only features required. Detected version: $VER"
  exit 1
fi
echo "✅ Vault Enterprise detected ($VER)"

# --- runner selection ----------------------------------------------------------
REQUESTED=("$@")
if [[ ${#REQUESTED[@]} -eq 0 ]]; then
  [[ "${RUN_DEMO_1:-false}" == "true" ]] && REQUESTED+=("1")
  [[ "${RUN_DEMO_2:-false}" == "true" ]] && REQUESTED+=("2")
  [[ "${RUN_DEMO_3:-false}" == "true" ]] && REQUESTED+=("3")
  [[ "${RUN_DEMO_4:-false}" == "true" ]] && REQUESTED+=("4")
  [[ "${RUN_DEMO_5:-false}" == "true" ]] && REQUESTED+=("5")
fi
if [[ ${#REQUESTED[@]} -eq 0 ]]; then
  echo "ℹ️  No demos selected via args or .env. Defaulting to: all"
  REQUESTED=("all")
fi
run_demo() {
  local n="$1"
  if [[ " ${REQUESTED[*]} " == *" all "* || " ${REQUESTED[*]} " == *" ${n} "* ]]; then
    return 0
  fi
  return 1
}

# --- helpers -------------------------------------------------------------------
has_namespace() {
  # Keep this lightweight: plain-text list is reliable to parse
  # Shows names like "team-a/" one per line.
  v namespace list 2>/dev/null | grep -qx "${1}/"
}

ensure_namespace() {
  local ns="$1"
  # Try to create; if it already exists, treat as success.
  if out="$(v namespace create "$ns" 2>&1)"; then
    echo "  ↳ created namespace '$ns'"
    return 0
  fi

  if echo "$out" | grep -qi "already exists"; then
    echo "  ↳ namespace '$ns' already exists"
    return 0
  fi

  # Fallback: double-check via list (covers perms/race conditions)
  if has_namespace "$ns"; then
    echo "  ↳ namespace '$ns' already exists"
    return 0
  fi

  echo "❌ failed to ensure namespace '$ns':"
  echo "$out"
  return 1
}

ns_v() {
  local ns="$1"; shift
  VAULT_NAMESPACE="$ns" v "$@"
}

enable_kv_if_missing() {
  local ns="$1" mount="$2"
  local mounts
  mounts="$(ns_v "$ns" secrets list -format=json 2>/dev/null || echo '{}')"
  if echo "$mounts" | jq -r 'keys[]? // empty' | grep -q "^${mount}/$"; then
    echo "  ↳ $ns: mount '${mount}/' exists"
  else
    ns_v "$ns" secrets enable -path="$mount" kv-v2 >/dev/null
    echo "  ↳ $ns: enabled kv-v2 at '${mount}/'"
  fi
}

ensure_policy() {
  local ns="$1" name="$2" hcl="$3"
  # always (re)write to ensure contents are up to date
  ns_v "$ns" policy write "$name" - <<<"$hcl" >/dev/null
  echo "  ↳ $ns: policy '$name' ensured"
}

ensure_token_with_policies() {
  local ns="$1" pols_csv="$2" token_file="$3"
  mkdir -p "$(dirname "$token_file")"
  if [[ -f "$token_file" ]]; then
    echo "  ↳ $ns: token file exists ($token_file)"
    return 0
  fi
  local token
  token="$(ns_v "$ns" token create -policy="$pols_csv" -orphan -format=json | jq -r .auth.client_token)"
  printf '%s' "$token" > "$token_file"
  chmod 0600 "$token_file"
  echo "  ↳ $ns: issued token with policies [$pols_csv] → $token_file"
}

# --- DEMO 1: Namespaces & isolation -------------------------------------------
demo_1() {
  echo "🧱 DEMO 1: Namespaces & per-namespace isolation"
  ensure_namespace "$NS_A"
  ensure_namespace "$NS_B"

  enable_kv_if_missing "$NS_A" "$MOUNT_A"
  enable_kv_if_missing "$NS_B" "$MOUNT_B"

  POLICY_KV_READER='path "kv/data/*" { capabilities = ["read","list"] }'
  ensure_policy "$NS_A" "kv-reader" "$POLICY_KV_READER"
  ensure_policy "$NS_B" "kv-reader" "$POLICY_KV_READER"

  ns_v "$NS_A" kv put "$MOUNT_A/app" user=alice pw=teamA >/dev/null || true
  ns_v "$NS_B" kv put "$MOUNT_B/app" user=bob   pw=teamB >/dev/null || true
  echo "  ↳ wrote sample secrets team-a/app & team-b/app"

  ensure_token_with_policies "$NS_A" "kv-reader" ".vault-demo/team-a.reader.token"
  ensure_token_with_policies "$NS_B" "kv-reader" ".vault-demo/team-b.reader.token"

  local TA_TOKEN TB_TOKEN ok_a fail_a
  TA_TOKEN="$(cat .vault-demo/team-a.reader.token)"
  TB_TOKEN="$(cat .vault-demo/team-b.reader.token)"

  set +e
  ok_a=$(VAULT_NAMESPACE="$NS_A" VAULT_ADDR="$VAULT_ADDR" VAULT_TOKEN="$TA_TOKEN" vault kv get -field=user "$MOUNT_A/app" 2>/dev/null)
  fail_a=$(VAULT_NAMESPACE="$NS_B" VAULT_ADDR="$VAULT_ADDR" VAULT_TOKEN="$TA_TOKEN" vault kv get -field=user "$MOUNT_B/app" 2>&1 | grep -c 'permission denied' || true)
  set -e
  echo "  ✓ team-a token reads team-a/app → user=${ok_a}"
  [[ "$fail_a" -gt 0 ]] && echo "  ✓ team-a token blocked from team-b/app (403)"
  echo "✅ DEMO 1 complete"
}

# --- DEMO 2: EGP (Sentinel allow-list; deny KV v2 delete endpoints) ------------
demo_2() {
  echo "🛡️  DEMO 2: Endpoint Governance Policy (EGP) to deny deletes on team-a KV"

  ensure_namespace "$NS_A"
  enable_kv_if_missing "$NS_A" "$MOUNT_A"

  # Sentinel: allow everything EXCEPT any delete-ish endpoint on KV v2
  SENTINEL="$(cat <<'POL'
import "strings"
# Block any operation to KV v2 delete-ish endpoints
is_meta_delete   = rule { strings.has_prefix(request.path, "kv/metadata/") and request.operation != "read" }
is_soft_delete   = rule { strings.has_prefix(request.path, "kv/delete/") }
is_hard_destroy  = rule { strings.has_prefix(request.path, "kv/destroy/") }
main = rule { not ( is_meta_delete or is_soft_delete or is_hard_destroy ) }
POL
)"

  tmp="$(mktemp)"
  jq -n \
    --arg policy "$SENTINEL" \
    --arg level  "hard-mandatory" \
    --argjson paths '["kv/*"]' \
    '{enforcement_level:$level, paths:$paths, policy:$policy}' > "$tmp"

  set +e
  out=$(VAULT_NAMESPACE="$NS_A" v write sys/policies/egp/deny-team-a-kv-deletes @"$tmp" 2>&1)
  rc=$?
  set -e
  rm -f "$tmp"
  if (( rc != 0 )); then
    echo "❌ EGP write failed in ${NS_A}:"
    echo "$out"
    return 1
  fi
  echo "  ↳ EGP ensured in ${NS_A}: deny-team-a-kv-deletes"

  # Test: PUT allowed, KV delete endpoints denied
  ns_v "$NS_A" kv put "$MOUNT_A/egp-test" foo=bar >/dev/null || true

  set +e
  out_meta=$(VAULT_NAMESPACE="$NS_A" v kv metadata delete "$MOUNT_A/egp-test" 2>&1)
  out_soft=$(VAULT_NAMESPACE="$NS_A" v kv delete "$MOUNT_A/egp-test" 2>&1)
  out_hard=$(VAULT_NAMESPACE="$NS_A" v kv destroy -versions=1 "$MOUNT_A/egp-test" 2>&1)
  set -e

  if echo "$out_meta$out_soft$out_hard" | grep -qi "permission denied\|denied"; then
    echo "  ✓ KV delete operations blocked by EGP in ${NS_A}"
  else
    echo "  ⚠️ expected KV deletes to be blocked, got:"
    echo "$out_meta"
    echo "$out_soft"
    echo "$out_hard"
  fi
  echo "✅ DEMO 2 complete"
}

# --- DEMO 3: RGP (Sentinel allow-list; require 'prod-writer' for prod writes) --
demo_3() {
  echo "🧭 DEMO 3: Request Governance Policy (RGP) requiring policy 'prod-writer' for writes under team-a: kv/data/prod/*"

  ensure_namespace "$NS_A"
  enable_kv_if_missing "$NS_A" "$MOUNT_A"

  # Sentinel: allow unless it's a prod write AND caller lacks 'prod-writer'
  SENTINEL="$(cat <<'POL'
import "strings"
is_prod_write = rule { strings.has_prefix(request.path, "kv/data/prod/") and request.operation in ["create","update","patch"] }
has_required  = rule { "prod-writer" in request.token.policies }
main = rule { not ( is_prod_write and not has_required ) }
POL
)"

  tmp="$(mktemp)"
  jq -n \
    --arg policy "$SENTINEL" \
    --arg level  "hard-mandatory" \
    --argjson paths '["kv/*"]' \
    '{enforcement_level:$level, paths:$paths, policy:$policy}' > "$tmp"

  set +e
  out=$(VAULT_NAMESPACE="$NS_A" v write sys/policies/rgp/rgp-prod-writer-required @"$tmp" 2>&1)
  rc=$?
  set -e
  rm -f "$tmp"
  if (( rc != 0 )); then
    echo "❌ RGP write failed in ${NS_A}:"
    echo "$out"
    return 1
  fi
  echo "  ↳ RGP ensured in ${NS_A}: rgp-prod-writer-required"

  # Policies & tokens for the test (idempotent)
  ensure_policy "$NS_A" "prod-writer" '
path "kv/data/prod/*"     { capabilities = ["create","update","read"] }
path "kv/metadata/prod/*" { capabilities = ["read"] }
'
  ensure_policy "$NS_A" "plain-reader" 'path "kv/data/*" { capabilities = ["read","list"] }'

  ensure_token_with_policies "$NS_A" "plain-reader" ".vault-demo/team-a.plain-reader.token"
  ensure_token_with_policies "$NS_A" "plain-reader,prod-writer" ".vault-demo/team-a.prod-writer.token"

  PLAIN="$(cat .vault-demo/team-a.plain-reader.token)"
  WRITR="$(cat .vault-demo/team-a.prod-writer.token)"

  # Negative (should be denied)
  set +e
  neg_out=$(VAULT_NAMESPACE="$NS_A" VAULT_ADDR="$VAULT_ADDR" VAULT_TOKEN="$PLAIN" vault kv put "$MOUNT_A/prod/demo" a=b 2>&1)
  set -e
  if echo "$neg_out" | grep -qi "permission denied"; then
    echo "  ✓ write blocked (token missing 'prod-writer')"
  else
    echo "  ⚠️ expected block for plain-reader, got:"
    echo "$neg_out"
  fi

  # Positive (should succeed)
  VAULT_NAMESPACE="$NS_A" VAULT_ADDR="$VAULT_ADDR" VAULT_TOKEN="$WRITR" vault kv put "$MOUNT_A/prod/demo" a=b >/dev/null
  echo "  ✓ write allowed with 'prod-writer' token"
  echo "✅ DEMO 3 complete"
}

# --- DEMO 4: Control Groups (M-of-N) ------------------------------------------
demo_4() {
  echo "👥 DEMO 4: Control Groups — require 1 approver for reads under team-a: kv/data/ultra/*"

  ensure_namespace "$NS_A"
  enable_kv_if_missing "$NS_A" "$MOUNT_A"

  if v auth list -format=json | jq -r 'keys[]? // empty' | grep -q '^userpass/'; then
    echo "  ↳ userpass already enabled (root)"
  else
    v auth enable userpass >/dev/null
    echo "  ↳ enabled userpass (root)"
  fi

  v write auth/userpass/users/requester password="reqpass" >/dev/null || true
  v write auth/userpass/users/approver  password="apppass" >/dev/null || true
  echo "  ↳ ensured users: requester, approver"

  UP_ACCESSOR="$(v auth list -format=json | jq -r '."userpass/".accessor')"

  APP_ENTITY_ID="$(v read -format=json identity/entity/name/approver 2>/dev/null | jq -r .data.id 2>/dev/null || true)"
  if [[ -z "${APP_ENTITY_ID}" || "${APP_ENTITY_ID}" == "null" ]]; then
    APP_ENTITY_ID="$(v write -format=json identity/entity name="approver" | jq -r .data.id)"
    echo "  ↳ created entity for approver: $APP_ENTITY_ID"
  else
    echo "  ↳ entity exists for approver: $APP_ENTITY_ID"
  fi

  # Ensure alias (no fragile loops)
  if ! v list -format=json identity/entity-alias 2>/dev/null | jq -r '.[]? // empty' \
       | xargs -I{} v read -format=json identity/entity-alias/id/{} 2>/dev/null \
       | jq -r '.data.name' | grep -qx 'approver'; then
    v write identity/entity-alias name="approver" canonical_id="$APP_ENTITY_ID" mount_accessor="$UP_ACCESSOR" >/dev/null
    echo "  ↳ created entity alias for userpass/approver"
  else
    echo "  ↳ entity alias for approver already present"
  fi

  GRP_ID="$(v read -format=json identity/group/name/approvers 2>/dev/null | jq -r .data.id 2>/dev/null || true)"
  if [[ -z "${GRP_ID}" || "${GRP_ID}" == "null" ]]; then
    GRP_ID="$(v write -format=json identity/group name="approvers" member_entity_ids="$APP_ENTITY_ID" | jq -r .data.id)"
    echo "  ↳ created group 'approvers' with member approver"
  else
    v write identity/group/id/"$GRP_ID" member_entity_ids="$APP_ENTITY_ID" >/dev/null
    echo "  ↳ ensured group 'approvers' includes approver"
  fi

  read -r -d '' CG_POLICY <<'HCL'
path "kv/data/ultra/*" {
  capabilities = ["read"]
  control_group = {
    factor "approver_required" {
      identity {
        group_names = ["approvers"]
        approvals = 1
      }
    }
  }
}
HCL
  ensure_policy "$NS_A" "ultra-reader-cg" "$CG_POLICY"

  ns_v "$NS_A" kv put "$MOUNT_A/ultra/secret1" wow=controlgroups >/dev/null || true
  echo "  ↳ seeded $NS_A:$MOUNT_A/ultra/secret1"

  ensure_policy "$NS_A" "ultra-reader" 'path "kv/data/ultra/*" { capabilities=["read","list"] }'
  ensure_token_with_policies "$NS_A" "ultra-reader,ultra-reader-cg" ".vault-demo/team-a.requester.token"

  REQ_TOKEN="$(cat .vault-demo/team-a.requester.token)"
  echo "  → Simulate request (no approval yet): should yield a pending wrap"
  set +e
  resp=$(VAULT_NAMESPACE="$NS_A" VAULT_ADDR="$VAULT_ADDR" VAULT_TOKEN="$REQ_TOKEN" vault kv get -format=json "$MOUNT_A/ultra/secret1" 2>&1 || true)
  set -e

  if echo "$resp" | grep -q '"wrap_info"'; then
    WRAP_TOKEN=$(echo "$resp" | jq -r '.wrap_info.token' 2>/dev/null || true)
    if [[ -n "${WRAP_TOKEN}" && "${WRAP_TOKEN}" != "null" ]]; then
      echo "  ✓ request is pending approval (wrap token issued)"
      APP_TOKEN=$(VAULT_ADDR="$VAULT_ADDR" vault login -method=userpass username=approver password=apppass -format=json | jq -r .auth.client_token)
      VAULT_TOKEN="$APP_TOKEN" VAULT_ADDR="$VAULT_ADDR" vault write sys/control-group/authorize token="$WRAP_TOKEN" >/dev/null
      echo "  ✓ approver authorized"
      final=$(VAULT_NAMESPACE="$NS_A" VAULT_ADDR="$VAULT_ADDR" VAULT_TOKEN="$REQ_TOKEN" vault unwrap -format=json "$WRAP_TOKEN")
      val=$(echo "$final" | jq -r '.data.data.wow')
      echo "  ✓ requester unwraps: wow=${val}"
    else
      echo "  ⚠️ expected a wrap token, got:"
      echo "$resp"
    fi
  else
    echo "  ⚠️ expected control-group wrapping flow; got:"
    echo "$resp"
  fi

  echo "✅ DEMO 4 complete"
}

# --- DEMO 5: Per-namespace auth (userpass in team-b) ---------------------------
demo_5() {
  echo "🔐 DEMO 5: Per-namespace auth (userpass) & isolated access in team-b"

  ensure_namespace "$NS_B"
  enable_kv_if_missing "$NS_B" "$MOUNT_B"

  if ns_v "$NS_B" auth list -format=json | jq -r 'keys[]? // empty' | grep -q '^userpass/'; then
    echo "  ↳ userpass already enabled in ${NS_B}"
  else
    ns_v "$NS_B" auth enable userpass >/dev/null
    echo "  ↳ enabled userpass in ${NS_B}"
  fi

  ns_v "$NS_B" kv put "$MOUNT_B/app2" user=bob pw=teamB2 >/dev/null || true
  ensure_policy "$NS_B" "kv-reader" 'path "kv/data/*" { capabilities=["read","list"] }'
  ns_v "$NS_B" write auth/userpass/users/bob password="b0bpass" policies="kv-reader" >/dev/null || true
  echo "  ↳ created/ensured user bob in ${NS_B} with kv-reader"

  BOB_TOKEN=$(VAULT_NAMESPACE="$NS_B" VAULT_ADDR="$VAULT_ADDR" vault login -method=userpass username=bob password=b0bpass -format=json | jq -r .auth.client_token)
  read_ok=$(VAULT_NAMESPACE="$NS_B" VAULT_ADDR="$VAULT_ADDR" VAULT_TOKEN="$BOB_TOKEN" vault kv get -field=user "$MOUNT_B/app2")
  echo "  ✓ bob@${NS_B} reads ${MOUNT_B}/app2 user=${read_ok}"

  set +e
  cross_err=$(VAULT_NAMESPACE="$NS_A" VAULT_ADDR="$VAULT_ADDR" VAULT_TOKEN="$BOB_TOKEN" vault kv get "$MOUNT_A/app" 2>&1 || true)
  set -e
  if echo "$cross_err" | grep -qi "permission denied\|403"; then
    echo "  ✓ bob@${NS_B} is isolated from ${NS_A}"
  else
    echo "  ⚠️ expected bob to be blocked from ${NS_A}, got:"
    echo "$cross_err"
  fi


  echo "✅ DEMO 5 complete"
}

# --- execute -------------------------------------------------------------------
run_demo 1 && demo_1
run_demo 2 && demo_2
run_demo 3 && demo_3
run_demo 4 && demo_4
run_demo 5 && demo_5

echo "🎉 Done."
