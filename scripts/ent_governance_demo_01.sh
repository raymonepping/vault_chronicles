#!/usr/bin/env bash
set -euo pipefail

# ──────────────────────────────────────────────────────────────────────────────
# Demo 1 — Vault Enterprise Namespaces & Isolation (teamA, teamB)
# ──────────────────────────────────────────────────────────────────────────────

need() { command -v "$1" >/dev/null 2>&1 || { echo "❌ Missing dependency: $1"; exit 1; }; }
need vault
need jq

# --- safe .env loader ----------------------------------------------------------
load_dotenv() {
  local dotenv=".env"
  [[ -f "$dotenv" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -z "$line" || "${line:0:1}" == "#" ]] && continue
    if [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
      key="${BASH_REMATCH[1]}"
      val="${BASH_REMATCH[2]}"
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

# --- config --------------------------------------------------------------------
NS_A="teamA"
NS_B="teamB"
MOUNT="secret"
USER_A="alice"; PASS_A="pass"
USER_B="bob";   PASS_B="pass"

NUKE_NAMESPACES=false
for a in "$@"; do
  case "$a" in
    --clean) MODE="CLEAN" ;;
    --nuke-namespaces=true)  NUKE_NAMESPACES=true ;;
    --nuke-namespaces=false) NUKE_NAMESPACES=false ;;
    *) : ;;
  esac
done
MODE="${MODE:-RUN}"

v()    { VAULT_ADDR="$VAULT_ADDR" VAULT_TOKEN="$VAULT_TOKEN" vault "$@"; }
ns_v() { local ns="$1"; shift; VAULT_NAMESPACE="$ns" v "$@"; }

# --- helpers -------------------------------------------------------------------
has_namespace() { v namespace list 2>/dev/null | grep -qx "${1}/"; }

ensure_namespace() {
  local ns="$1"
  if has_namespace "$ns"; then
    echo "  ↳ namespace '$ns' exists"
  else
    v namespace create "$ns" >/dev/null
    echo "  ↳ created namespace '$ns'"
  fi
}

has_mount() { ns_v "$1" secrets list -format=json 2>/dev/null | jq -r 'keys[]? // empty' | grep -q "^${2}/$"; }

enable_kv_if_missing() {
  local ns="$1" mount="$2"
  if has_mount "$ns" "$mount"; then
    echo "  ↳ $ns: mount '${mount}/' exists"
  else
    ns_v "$ns" secrets enable -path="$mount" kv-v2 >/dev/null
    echo "  ↳ $ns: enabled kv-v2 at '${mount}/'"
  fi
}

ensure_userpass_enabled() {
  local ns="$1"
  if ns_v "$ns" auth list -format=json | jq -r 'keys[]? // empty' | grep -q '^userpass/'; then
    echo "  ↳ $ns: userpass enabled"
  else
    ns_v "$ns" auth enable userpass >/dev/null
    echo "  ↳ $ns: enabled userpass"
  fi
}

create_user() {
  local ns="$1" user="$2" pass="$3" pols="$4"
  ns_v "$ns" write "auth/userpass/users/${user}" password="$pass" policies="$pols" >/dev/null
  echo "  ↳ $ns: ensured user ${user} (policies: $pols)"
}

delete_user() { ns_v "$1" delete "auth/userpass/users/${2}" >/dev/null 2>&1 || true; }
del_policy()  { ns_v "$1" policy delete "$2" >/dev/null 2>&1 || true; }
del_secret()  { ns_v "$1" kv metadata delete "${MOUNT}/${2}" >/dev/null 2>&1 || true; }
disable_mount_if_present() { has_mount "$1" "$2" && ns_v "$1" secrets disable "$2" >/dev/null 2>&1 || true; }

# --- run demo ------------------------------------------------------------------
run_demo() {
  echo "🧱 DEMO 1: Namespaces & per-namespace isolation"
  echo "🔎 Checking Vault Enterprise @ $VAULT_ADDR ..."
  local health ver
  health="$(v status -format=json || true)"
  [[ -n "$health" ]] || { echo "❌ Cannot reach Vault"; exit 1; }
  ver="$(echo "$health" | jq -r '.version')"
  [[ "$ver" == *"+ent"* ]] || { echo "❌ Enterprise-only feature (namespaces) required. Detected: $ver"; exit 1; }
  echo "✅ Vault Enterprise detected ($ver)"

  ensure_namespace "$NS_A"
  ensure_namespace "$NS_B"
  enable_kv_if_missing "$NS_A" "$MOUNT"
  enable_kv_if_missing "$NS_B" "$MOUNT"
  ensure_userpass_enabled "$NS_A"
  ensure_userpass_enabled "$NS_B"

  ns_v "$NS_A" policy write admin -<<'HCL'
path "*" { capabilities = ["create","read","update","delete","list","sudo"] }
HCL
  echo "  ↳ $NS_A: policy 'admin' ensured"

  ns_v "$NS_B" policy write admin -<<'HCL'
path "*" { capabilities = ["create","read","update","delete","list","sudo"] }
HCL
  echo "  ↳ $NS_B: policy 'admin' ensured"

  create_user "$NS_A" "$USER_A" "$PASS_A" "admin"
  create_user "$NS_B" "$USER_B" "$PASS_B" "admin"

  echo "  ↳ logging in as $USER_A@$NS_A and $USER_B@$NS_B"
  ALICE_TOKEN=$(env -u VAULT_TOKEN VAULT_NAMESPACE="$NS_A" VAULT_ADDR="$VAULT_ADDR" \
    vault login -method=userpass username="$USER_A" password="$PASS_A" -format=json | jq -r .auth.client_token)
  BOB_TOKEN=$(env -u VAULT_TOKEN VAULT_NAMESPACE="$NS_B" VAULT_ADDR="$VAULT_ADDR" \
    vault login -method=userpass username="$USER_B" password="$PASS_B" -format=json | jq -r .auth.client_token)

  echo
  echo "### Tests"
  echo "# Alice in teamA"
  VAULT_NAMESPACE="$NS_A" VAULT_TOKEN="$ALICE_TOKEN" vault kv put "${MOUNT}/demoA" value=1 >/dev/null
  VAULT_NAMESPACE="$NS_A" VAULT_TOKEN="$ALICE_TOKEN" vault kv get "${MOUNT}/demoA" >/dev/null && echo "# ✅ read ok"

  echo
  echo "# Cross-namespace isolation (should fail)"
  echo "# alice → teamB: ${MOUNT}/demoA"
  set +e
  VAULT_NAMESPACE="$NS_B" VAULT_TOKEN="$ALICE_TOKEN" vault kv get "${MOUNT}/demoA" &>/dev/null
  rc_alice_cross=$?
  set -e
  if [[ $rc_alice_cross -ne 0 ]]; then
    echo "# ❌ blocked / denied as expected"
  else
    echo "# ⚠️ expected denial but succeeded"
  fi

  echo
  echo "# Bob in teamB"
  VAULT_NAMESPACE="$NS_B" VAULT_TOKEN="$BOB_TOKEN" vault kv put "${MOUNT}/demoB" value=2 >/dev/null
  VAULT_NAMESPACE="$NS_B" VAULT_TOKEN="$BOB_TOKEN" vault kv get "${MOUNT}/demoB" >/dev/null && echo "# ✅ read ok"

  echo
  echo "# Cross-namespace isolation (should fail)"
  echo "# bob → teamA: ${MOUNT}/demoB"
  set +e
  VAULT_NAMESPACE="$NS_A" VAULT_TOKEN="$BOB_TOKEN" vault kv get "${MOUNT}/demoB" &>/dev/null
  rc_bob_cross=$?
  set -e
  if [[ $rc_bob_cross -ne 0 ]]; then
    echo "# ❌ blocked / denied as expected"
  else
    echo "# ⚠️ expected denial but succeeded"
  fi

  echo
  echo "✅ DEMO 1 complete"
}

# --- cleanup -------------------------------------------------------------------
clean_demo() {
  echo "🧽 Cleanup: removing Demo 1 artifacts …"
  delete_user "$NS_A" "$USER_A"
  delete_user "$NS_B" "$USER_B"
  del_secret "$NS_A" "demoA"
  del_secret "$NS_B" "demoB"
  del_policy "$NS_A" "admin"
  del_policy "$NS_B" "admin"

  if $NUKE_NAMESPACES; then
    if has_namespace "$NS_A"; then
      disable_mount_if_present "$NS_A" "$MOUNT"
      v namespace delete "$NS_A" >/dev/null 2>&1 || true
      echo "  ↳ deleted namespace $NS_A"
    fi
    if has_namespace "$NS_B"; then
      disable_mount_if_present "$NS_B" "$MOUNT"
      v namespace delete "$NS_B" >/dev/null 2>&1 || true
      echo "  ↳ deleted namespace $NS_B"
    fi
  else
    echo "  ↳ namespaces kept (use --nuke-namespaces=true to delete)"
  fi
  echo "✅ Cleanup complete."
}

# --- dispatch ------------------------------------------------------------------
if [[ "${MODE}" == "CLEAN" ]]; then
  clean_demo
else
  run_demo
fi
