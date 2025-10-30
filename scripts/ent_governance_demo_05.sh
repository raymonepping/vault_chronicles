#!/usr/bin/env bash
set -euo pipefail

# ================================
# DEMO 5: EGP — Business Hours Gate (doc-proven)
# - Enforces business hours on kv-v2 path under teamA
# - Soft-mandatory by default (shows policy override)
# - Scope: secret/* (kv-v2)
# ================================

need() { command -v "$1" >/dev/null 2>&1 || { echo "❌ Missing dependency: $1"; exit 1; }; }
need vault; need jq

load_dotenv() {
  local f=.env; [[ -f $f ]] || return 0
  while IFS= read -r l || [[ -n $l ]]; do
    l="${l#"${l%%[![:space:]]*}"}"; l="${l%"${l##*[![:space:]]}"}"
    [[ -z "$l" || "${l:0:1}" == "#" ]] && continue
    if [[ "$l" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
      k="${BASH_REMATCH[1]}"; v="${BASH_REMATCH[2]}"
      [[ "$v" =~ ^\"(.*)\"$ ]] && v="${BASH_REMATCH[1]}"
      [[ "$v" =~ ^\'(.*)\'$ ]] && v="${BASH_REMATCH[1]}"
      export "$k=$v"
    fi
  done <"$f"
}
load_dotenv

VAULT_ADDR="${VAULT_ADDR:-http://127.0.0.1:18200}"
VAULT_TOKEN="${VAULT_TOKEN:-}"; : "${VAULT_TOKEN:?Set VAULT_TOKEN in .env or env}"

# ----- Demo params -----
NS="teamA"
MOUNT="secret"                       # kv-v2 mount path
EGP_NAME="egp-business-hours"        # EGP policy name
CLASS_KEY="classified/topsecret"     # Key to test
TEST_VALUE="${TEST_VALUE:-t65}"      # value written in test
ENFORCEMENT="soft-mandatory"         # default (overrideable via flags)
SIMULATE_AFTER_HOURS=false
TRACE=false
TEST_TOKEN_FILE=".vault-demo/${NS}.egp-bh.token"

# Flags:
# --clean                  -> remove artifacts
# --hard                   -> hard-mandatory
# --soft                   -> soft-mandatory (default)
# --advisory               -> advisory
# --simulate-after-hours   -> force denial to demo override (soft mode)
# --trace                  -> show example commands at the end
# --nuke-namespaces=true   -> (kept for parity; not used to delete NS)
NUKE_NAMESPACES=false
MODE="RUN"

for a in "$@"; do
  case "$a" in
    --clean) MODE="CLEAN" ;;
    --nuke-namespaces=true)  NUKE_NAMESPACES=true ;;
    --nuke-namespaces=false) NUKE_NAMESPACES=false ;;
    --hard) ENFORCEMENT="hard-mandatory" ;;
    --soft) ENFORCEMENT="soft-mandatory" ;;
    --advisory) ENFORCEMENT="advisory" ;;
    --simulate-after-hours) SIMULATE_AFTER_HOURS=true ;;
    --trace) TRACE=true ;;
  esac
done

v(){ VAULT_ADDR="$VAULT_ADDR" VAULT_TOKEN="$VAULT_TOKEN" vault "$@"; }
ns_v(){ local ns="$1"; shift; VAULT_NAMESPACE="$ns" v "$@"; }
has_ns(){ v namespace list 2>/dev/null | grep -qx "${1}/"; }
has_mount(){ ns_v "$1" secrets list -format=json 2>/dev/null | jq -r 'keys[]? // empty' | grep -q "^${2}/$"; }

ensure_namespace(){
  local ns="$1"
  if ! has_ns "$ns"; then
    v namespace create "$ns" >/dev/null
    echo "  ↳ created namespace '$ns'"
  fi
}

enable_kv_if_missing(){
  local ns="$1" m="$2"
  if ! has_mount "$ns" "$m"; then
    ns_v "$ns" secrets enable -path="$m" kv-v2 >/dev/null
    echo "  ↳ $ns: enabled kv-v2 at '${m}/'"
  fi
}

ensure_policy(){
  local ns="$1" name="$2" hcl="$3"
  ns_v "$ns" policy write "$name" - <<<"$hcl" >/dev/null
  echo "  ↳ $ns: policy '$name' ensured"
}

seed_secret(){
  ns_v "$NS" kv put -mount="$MOUNT" "$CLASS_KEY" s="$TEST_VALUE" >/dev/null
  echo "  ↳ seeded ${MOUNT}/${CLASS_KEY}"
}

# Issue a plain token with read/write on secret/*
issue_reader_token(){
  local out="$1"
  mkdir -p "$(dirname "$out")"; rm -f "$out"
  local token_json
  token_json="$(
    VAULT_NAMESPACE="$NS" VAULT_ADDR="$VAULT_ADDR" VAULT_TOKEN="$VAULT_TOKEN" \
      vault write -format=json auth/token/create \
        token_ttl="1h" \
        token_type="service" \
        policies="plain-rw"
  )"
  printf '%s' "$(echo "$token_json" | jq -r .auth.client_token)" > "$out"
  chmod 0600 "$out"
  echo "  ↳ $NS: issued fresh token [plain-rw] → $out"
}

write_egp_policy(){
  local pol tmp_json out rc
  pol="$(mktemp -t egp.XXXXXX.sentinel)"
  tmp_json="$(mktemp -t egp.XXXXXX.json)"

  # Build the policy body with optional simulation
  {
    cat <<'BASE'
import "time"
import "strings"

# Precondition: only apply to secret/* paths (all ops)
precond = rule {
  strings.has_prefix(request.path, "secret/")
}

# Work days: Monday(1) .. Friday(5)
workdays = rule {
  time.now.weekday > 0 and time.now.weekday < 6
}
BASE

    if $SIMULATE_AFTER_HOURS; then
      # Force "after-hours" (always false) to demo denial/override at any time
      cat <<'SIM'
workhours = rule { false }
SIM
    else
      cat <<'NORM'
# Work hours: 07:00 .. 18:00 (exclusive upper bound)
workhours = rule {
  time.now.hour > 7 and time.now.hour < 18
}
NORM
    fi

    cat <<'TAIL'
# Only enforce when precond matches
main = rule when precond {
  workdays and workhours
}
TAIL
  } >"$pol"

  echo "---- EGP policy being written ----"
  sed -n '1,200p' "$pol"
  echo "----------------------------------"

  # Clean install
  VAULT_NAMESPACE="$NS" VAULT_ADDR="$VAULT_ADDR" VAULT_TOKEN="$VAULT_TOKEN" \
    vault delete "sys/policies/egp/$EGP_NAME" >/dev/null 2>&1 || true

  # Include required paths + enforcement
  jq -n \
    --rawfile policy "$pol" \
    --arg level "$ENFORCEMENT" \
    --arg path "$MOUNT/*" \
    '{enforcement_level:$level, policy:$policy, paths: [$path]}' >"$tmp_json"

  set +e
  out=$(VAULT_NAMESPACE="$NS" VAULT_ADDR="$VAULT_ADDR" VAULT_TOKEN="$VAULT_TOKEN" \
    vault write "sys/policies/egp/$EGP_NAME" @"$tmp_json" 2>&1)
  rc=$?
  set -e

  if (( rc != 0 )); then
    echo "❌ EGP write failed. Vault said:"
    echo "$out"
    rm -f "$pol" "$tmp_json"
    exit 1
  fi

  echo "✔ Stored EGP policy body:"
  VAULT_NAMESPACE="$NS" VAULT_ADDR="$VAULT_ADDR" VAULT_TOKEN="$VAULT_TOKEN" \
    vault read -format=json "sys/policies/egp/$EGP_NAME" | jq -r '.data.policy'

  # Pretty summary for screenshots
  echo "  ↳ EGP summary:"
  VAULT_NAMESPACE="$NS" VAULT_ADDR="$VAULT_ADDR" VAULT_TOKEN="$VAULT_TOKEN" \
    vault read -format=json "sys/policies/egp/$EGP_NAME" \
    | jq -r '"    name: \(.data.name)\n    enforcement: \(.data.enforcement_level)\n    paths: \(.data.paths | join(", "))"'

  rm -f "$pol" "$tmp_json"
  echo "  ↳ EGP '$EGP_NAME' ensured in ${NS} (enforcement: $ENFORCEMENT, paths: ${MOUNT}/*)"
}

run_demo(){
  echo "🧭 DEMO 5 (EGP): business-hours gate for ${MOUNT}/* in ${NS} (enforcement: $ENFORCEMENT)"
  local health ver; health="$(v status -format=json || true)"
  [[ -n "$health" ]] || { echo "❌ Cannot reach Vault"; exit 1; }
  ver="$(echo "$health" | jq -r '.version')"
  [[ "$ver" == *"+ent"* ]] || { echo "❌ Enterprise-only feature (EGP) required. Detected: $ver"; exit 1; }
  echo "✅ Vault Enterprise detected ($ver)"

  ensure_namespace "$NS"
  enable_kv_if_missing "$NS" "$MOUNT"

  # base ACL: allow R/W on secret/*
  ensure_policy "$NS" "plain-rw" '
path "secret/*"                 { capabilities = ["create", "read", "update", "delete", "list"] }
path "sys/internal/ui/mounts"   { capabilities = ["read"] }
path "sys/internal/ui/mounts/*" { capabilities = ["read"] }
'

  seed_secret
  write_egp_policy

  # Tester token
  issue_reader_token "$TEST_TOKEN_FILE"
  local TOK; TOK="$(cat "$TEST_TOKEN_FILE")"

  echo; echo "### Tests"
  echo "# 1) Write with tester token (no override):"
  set +e
  VAULT_NAMESPACE="$NS" VAULT_TOKEN="$TOK" \
    vault kv put -mount="$MOUNT" "$CLASS_KEY" s="$TEST_VALUE" >/dev/null
  rc_no_override=$?
  set -e

  if [[ "$ENFORCEMENT" == "soft-mandatory" ]]; then
    if (( rc_no_override != 0 )); then
      echo "#    ❌ denied by EGP (as expected outside business hours or current weekday)"
      echo "# 2) Write again with policy override (soft-mandatory allows override):"
      VAULT_NAMESPACE="$NS" VAULT_TOKEN="$TOK" \
        vault kv put -policy-override -mount="$MOUNT" "$CLASS_KEY" s="$TEST_VALUE" >/dev/null && \
        echo "#    ✅ succeeded with -policy-override"
    else
      echo "#    ✅ allowed (we are currently inside business hours on a weekday)"
      if $SIMULATE_AFTER_HOURS; then
        echo "#    ↪ forcing after-hours style demo: using -policy-override anyway (soft only)"
        VAULT_NAMESPACE="$NS" VAULT_TOKEN="$TOK" \
          vault kv put -policy-override -mount="$MOUNT" "$CLASS_KEY" s="$TEST_VALUE" >/dev/null && \
          echo "#    ✅ succeeded with -policy-override"
      fi
    fi
  else
    # hard/advisory variations: no override allowed for hard; advisory always passes
    if [[ "$ENFORCEMENT" == "hard-mandatory" ]]; then
      if (( rc_no_override != 0 )); then
        echo "#    ❌ denied by EGP (hard-mandatory; override not permitted)"
      else
        echo "#    ✅ allowed (inside business hours)"
      fi
    else
      # advisory
      echo "#    ✅ advisory mode: allowed (policy is informational)"
    fi
  fi

  echo; echo "✅ DEMO 5 complete"
  if $TRACE; then
    echo
    echo "ℹ️  Token file:"
    echo "    TEST: $TEST_TOKEN_FILE"
    echo "    Try read (no override):"
    echo "      VAULT_NAMESPACE=$NS VAULT_TOKEN=\$(cat \"$TEST_TOKEN_FILE\") vault kv get -mount=$MOUNT $CLASS_KEY"
    if [[ "$ENFORCEMENT" == "soft-mandatory" ]]; then
      echo "    Try write with override (soft only):"
      echo "      VAULT_NAMESPACE=$NS VAULT_TOKEN=\$(cat \"$TEST_TOKEN_FILE\") vault kv put -policy-override -mount=$MOUNT ${CLASS_KEY} s=override"
      echo "    API hint (override header):"
      echo "      X-Vault-Policy-Override: true"
    fi
  fi
}

clean_demo(){
  echo "🧽 Cleanup: removing Demo 5 artifacts …"
  VAULT_NAMESPACE="$NS" v delete "sys/policies/egp/${EGP_NAME}" >/dev/null 2>&1 || true
  echo "  ↳ deleted EGP '${EGP_NAME}' in ${NS} (if existed)"
  rm -f ".vault-demo/${NS}.egp-bh.token" 2>/dev/null || true
  # keep mount/NS intact, only remove test key metadata
  VAULT_NAMESPACE="$NS" v kv metadata delete "${MOUNT}/classified" >/dev/null 2>&1 || true
  echo "✅ Cleanup complete."
}

if [[ "${1:-}" == "--clean" ]]; then clean_demo; exit 0; fi
run_demo
# --- end of file ----------------------------------------------------------------
