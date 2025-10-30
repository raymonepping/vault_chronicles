#!/usr/bin/env bash
set -euo pipefail

# Demo 2 — EGP (Enterprise): deny KV v2 delete operations in teamA
# - Uses a non-root token (policy: kv-ops) for tests so EGP actually applies.

need() { command -v "$1" >/dev/null 2>&1 || { echo "❌ Missing dependency: $1"; exit 1; }; }
need vault
need jq

# .env loader (safe)
load_dotenv() {
  local dotenv=".env"
  [[ -f "$dotenv" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line#"${line%%[![:space:]]*}"}"; line="${line%"${line##*[![:space:]]}"}"
    [[ -z "$line" || "${line:0:1}" == "#" ]] && continue
    if [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
      local key="${BASH_REMATCH[1]}"; local val="${BASH_REMATCH[2]}"
      if [[ "$val" =~ ^\"(.*)\"$ ]]; then val="${BASH_REMATCH[1]}"; elif [[ "$val" =~ ^\'(.*)\'$ ]]; then val="${BASH_REMATCH[1]}"; fi
      export "$key=$val"
    fi
  done < "$dotenv"
}
load_dotenv

VAULT_ADDR="${VAULT_ADDR:-http://127.0.0.1:18200}"
VAULT_TOKEN="${VAULT_TOKEN:-}"
: "${VAULT_TOKEN:?Set VAULT_TOKEN in .env or environment}"

NS="teamA"
MOUNT="secret"
POL_NAME="deny-teama-kv-deletes"
TEST_PATH="${MOUNT}/egp-test"
TEST_TOKEN_FILE=".vault-demo/${NS}.kv-ops.token"

NUKE_NAMESPACES=false
MODE="RUN"
for a in "$@"; do
  case "$a" in
    --clean) MODE="CLEAN" ;;
    --nuke-namespaces=true)  NUKE_NAMESPACES=true ;;
    --nuke-namespaces=false) NUKE_NAMESPACES=false ;;
  esac
done

v()     { VAULT_ADDR="$VAULT_ADDR" VAULT_TOKEN="$VAULT_TOKEN" vault "$@"; }
ns_v()  { local ns="$1"; shift; VAULT_NAMESPACE="$ns" v "$@"; }
has_ns(){ v namespace list 2>/dev/null | grep -qx "${1}/"; }
has_mount(){ ns_v "$1" secrets list -format=json 2>/dev/null | jq -r 'keys[]? // empty' | grep -q "^${2}/$"; }
disable_mount_if_present(){ has_mount "$1" "$2" && ns_v "$1" secrets disable "$2" >/dev/null 2>&1 || true; }

ensure_namespace() {
  local ns="$1"
  if has_ns "$ns"; then echo "  ↳ namespace '$ns' exists"
  else v namespace create "$ns" >/dev/null; echo "  ↳ created namespace '$ns'"; fi
}
enable_kv_if_missing() {
  local ns="$1" mount="$2"
  if has_mount "$ns" "$mount"; then echo "  ↳ $ns: mount '${mount}/' exists"
  else ns_v "$ns" secrets enable -path="$mount" kv-v2 >/dev/null; echo "  ↳ $ns: enabled kv-v2 at '${mount}/'"; fi
}

ensure_policy() {
  local ns="$1" name="$2" hcl="$3"
  ns_v "$ns" policy write "$name" - <<<"$hcl" >/dev/null
  echo "  ↳ $ns: policy '$name' ensured"
}

ensure_test_token() {
  local ns="$1" pol="$2" out="$3"
  mkdir -p "$(dirname "$out")"
  if [[ -f "$out" ]]; then
    echo "  ↳ $ns: test token exists ($out)"
  else
    local t; t="$(ns_v "$ns" token create -policy="$pol" -orphan -format=json | jq -r .auth.client_token)"
    printf '%s' "$t" > "$out"
    chmod 0600 "$out"
    echo "  ↳ $ns: issued non-root test token ($pol) → $out"
  fi
}

run_demo() {
  echo "🛡️  DEMO 2: EGP — deny KV v2 deletes in ${NS}"
  echo "🔎 Checking Vault Enterprise @ $VAULT_ADDR ..."
  local health ver; health="$(v status -format=json || true)"; [[ -n "$health" ]] || { echo "❌ Cannot reach Vault"; exit 1; }
  ver="$(echo "$health" | jq -r '.version')"
  [[ "$ver" == *"+ent"* ]] || { echo "❌ Enterprise-only feature (EGP) required. Detected: $ver"; exit 1; }
  echo "✅ Vault Enterprise detected ($ver)"

  ensure_namespace "$NS"
  enable_kv_if_missing "$NS" "$MOUNT"

  # EGP — explicitly evaluate KV v2 endpoints we care about
  ns_v "$NS" write "sys/policies/egp/${POL_NAME}" -<<'JSON'
{
  "enforcement_level": "hard-mandatory",
  "paths": [
    "secret/data/*",
    "secret/metadata/*",
    "secret/delete/*",
    "secret/destroy/*"
  ],
  "policy": "import \"strings\"\n\nis_meta_delete  = rule { strings.has_prefix(request.path, \"secret/metadata/\") and request.operation != \"read\" }\nis_soft_delete  = rule { strings.has_prefix(request.path, \"secret/delete/\") }\nis_hard_destroy = rule { strings.has_prefix(request.path, \"secret/destroy/\") }\n\nmain = rule { not (is_meta_delete or is_soft_delete or is_hard_destroy) }"
}
JSON
  echo "  ↳ EGP '${POL_NAME}' ensured in ${NS}"

  # ACL for non-root test token: allow normal ops incl. delete-ish paths (EGP will overrule)
  ensure_policy "$NS" "kv-ops" '
path "secret/data/*"     { capabilities = ["create","update","read","list"] }
path "secret/metadata/*" { capabilities = ["read","list","delete","update"] }
path "secret/delete/*"   { capabilities = ["update"] }
path "secret/destroy/*"  { capabilities = ["update"] }
'
  ensure_test_token "$NS" "kv-ops" "$TEST_TOKEN_FILE"
  TEST_TOKEN="$(cat "$TEST_TOKEN_FILE")"

  echo
  echo "### Tests (non-root token)"
  echo "# Put (allowed)"
  VAULT_NAMESPACE="$NS" VAULT_TOKEN="$TEST_TOKEN" vault kv put "$TEST_PATH" foo=bar >/dev/null && echo "# ✅ write ok"

  echo
  echo "# Get (allowed)"
  VAULT_NAMESPACE="$NS" VAULT_TOKEN="$TEST_TOKEN" vault kv get "$TEST_PATH"  >/dev/null && echo "# ✅ read ok"

  echo
  echo "# Metadata delete (should be denied)"
  set +e
  VAULT_NAMESPACE="$NS" VAULT_TOKEN="$TEST_TOKEN" vault kv metadata delete "$TEST_PATH" &>/dev/null
  rc_meta=$?
  set -e
  [[ $rc_meta -ne 0 ]] && echo "# ❌ blocked / denied as expected" || echo "# ⚠️ expected denial"

  echo
  echo "# Soft delete (should be denied)"
  set +e
  VAULT_NAMESPACE="$NS" VAULT_TOKEN="$TEST_TOKEN" vault kv delete "$TEST_PATH" &>/dev/null
  rc_soft=$?
  set -e
  [[ $rc_soft -ne 0 ]] && echo "# ❌ blocked / denied as expected" || echo "# ⚠️ expected denial"

  echo
  echo "# Destroy version 1 (should be denied)"
  set +e
  VAULT_NAMESPACE="$NS" VAULT_TOKEN="$TEST_TOKEN" vault kv destroy -versions=1 "$TEST_PATH" &>/dev/null
  rc_hard=$?
  set -e
  [[ $rc_hard -ne 0 ]] && echo "# ❌ blocked / denied as expected" || echo "# ⚠️ expected denial"

  echo
  echo "✅ DEMO 2 complete"
}

clean_demo() {
  echo "🧽 Cleanup: removing Demo 2 artifacts …"
  VAULT_NAMESPACE="$NS" v delete "sys/policies/egp/${POL_NAME}" >/dev/null 2>&1 || true
  VAULT_NAMESPACE="$NS" v policy delete "kv-ops" >/dev/null 2>&1 || true
  rm -f "$TEST_TOKEN_FILE" 2>/dev/null || true

  if $NUKE_NAMESPACES; then
    if has_ns "$NS"; then
      disable_mount_if_present "$NS" "$MOUNT"
      v namespace delete "$NS" >/dev/null 2>&1 || true
      echo "  ↳ deleted namespace $NS"
    fi
  else
    echo "  ↳ namespace kept (use --nuke-namespaces=true to delete)"
  fi
  echo "✅ Cleanup complete."
}

if [[ "${MODE}" == "CLEAN" ]]; then
  clean_demo
else
  run_demo
fi
