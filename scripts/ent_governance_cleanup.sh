#!/usr/bin/env bash
set -euo pipefail

need() { command -v "$1" >/dev/null 2>&1 || { echo "❌ Missing dependency: $1"; exit 1; }; }
need vault
need jq

VAULT_ADDR="${VAULT_ADDR:-http://127.0.0.1:18200}"
VAULT_TOKEN="${VAULT_TOKEN:-}"
: "${VAULT_TOKEN:?Set VAULT_TOKEN in env}"

NS_A="team-a"
NS_B="team-b"
MOUNT="kv"

NUKE_NAMESPACES=true
DISABLE_USERPASS=false

for a in "$@"; do
  case "$a" in
    --nuke-namespaces=true)  NUKE_NAMESPACES=true ;;
    --nuke-namespaces=false) NUKE_NAMESPACES=false ;;
    --disable-userpass=true) DISABLE_USERPASS=true ;;
    --disable-userpass=false)DISABLE_USERPASS=false ;;
    *) echo "Unknown arg: $a" ;;
  esac
done

v()           { VAULT_ADDR="$VAULT_ADDR" VAULT_TOKEN="$VAULT_TOKEN" vault "$@"; }
ns_v()        { local ns="$1"; shift; VAULT_NAMESPACE="$ns" v "$@"; }
has_ns()      { v namespace list 2>/dev/null | grep -qx "${1}/"; }
has_mount()   { ns_v "$1" secrets list -format=json 2>/dev/null | jq -r 'keys[]? // empty' | grep -q "^${2}/$"; }
del_policy()  { local ns="$1" name="$2"; ns_v "$ns" policy delete "$name" >/dev/null 2>&1 || true; }
del_sys_pol() { local ns="$1" kind="$2" name="$3"; ns_v "$ns" delete "sys/policies/${kind}/${name}" >/dev/null 2>&1 || true; }
del_secret()  { local ns="$1" path="$2"; ns_v "$ns" kv metadata delete "$MOUNT/${path}" >/dev/null 2>&1 || true; }

echo "🧽 Cleanup: removing demo artifacts …"

# 0) Local token files
rm -f .vault-demo/team-a.*.token .vault-demo/team-b.*.token 2>/dev/null || true
rmdir .vault-demo 2>/dev/null || true

# 1) Governance policies in team-a (EGP/RGP/ACL)
del_sys_pol "$NS_A" egp "deny-team-a-kv-deletes"
del_sys_pol "$NS_A" rgp "rgp-prod-writer-required"
del_sys_pol "$NS_A" acl "acl-dev-writes-team-gated"

# 2) team-a app policies
for p in prod-writer plain-reader kv-deleter ultra-reader ultra-reader-cg dev-reader dev-writer kv-reader; do
  del_policy "$NS_A" "$p"
done

# 3) team-b app policies & user
for p in kv-reader; do
  del_policy "$NS_B" "$p"
done

# 4) Secrets (metadata delete = purge)
del_secret "$NS_A" "egp-test"       # demo 2
del_secret "$NS_A" "prod/demo"      # demo 3
del_secret "$NS_A" "ultra/secret1"  # demo 4
del_secret "$NS_A" "dev/demo"       # demo 5 (ACL)

# 5) Control Group identities (root scope) + userpass users
# users
v delete auth/userpass/users/requester >/dev/null 2>&1 || true
v delete auth/userpass/users/approver  >/dev/null 2>&1 || true

# group
GRP_ID="$(v read -format=json identity/group/name/approvers 2>/dev/null | jq -r .data.id 2>/dev/null || true)"
[[ -n "${GRP_ID:-}" && "${GRP_ID:-null}" != "null" ]] && v delete identity/group/id/"$GRP_ID" >/dev/null 2>&1 || true

# entity + alias
APP_ENTITY_ID="$(v read -format=json identity/entity/name/approver 2>/dev/null | jq -r .data.id 2>/dev/null || true)"
if [[ -n "${APP_ENTITY_ID:-}" && "${APP_ENTITY_ID:-null}" != "null" ]]; then
  # delete aliases referencing the entity
  ALIASES=$(v list -format=json identity/entity-alias 2>/dev/null || echo "[]")
  if [[ "$ALIASES" != "null" ]]; then
    for aid in $(echo "$ALIASES" | jq -r '.[]? // empty'); do
      ENT_ID=$(v read -format=json identity/entity-alias/id/"$aid" 2>/dev/null | jq -r '.data.canonical_id // empty')
      [[ "$ENT_ID" == "$APP_ENTITY_ID" ]] && v delete identity/entity-alias/id/"$aid" >/dev/null 2>&1 || true
    done
  fi
  v delete identity/entity/id/"$APP_ENTITY_ID" >/dev/null 2>&1 || true
fi

# 6) Optionally disable userpass (root)
if $DISABLE_USERPASS; then
  if v auth list -format=json 2>/dev/null | jq -r 'keys[]? // empty' | grep -q '^userpass/'; then
    v auth disable userpass >/dev/null 2>&1 || true
  fi
fi

# 7) Optionally tear down mounts and namespaces
if $NUKE_NAMESPACES; then
  for NS in "$NS_A" "$NS_B"; do
    if has_ns "$NS"; then
      # Attempt to disable kv first for cleaner delete
      has_mount "$NS" "$MOUNT" && ns_v "$NS" secrets disable "$MOUNT" >/dev/null 2>&1 || true
      v namespace delete "$NS" >/dev/null 2>&1 || true
    fi
  done
else
  # Keep namespaces; just disable kv if you want a clean slate (commented by default)
  # ns_v "$NS_A" secrets disable "$MOUNT" >/dev/null 2>&1 || true
  # ns_v "$NS_B" secrets disable "$MOUNT" >/dev/null 2>&1 || true
  :
fi

echo "✅ Cleanup complete."
