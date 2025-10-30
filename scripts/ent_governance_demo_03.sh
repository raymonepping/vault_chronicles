#!/usr/bin/env bash
set -euo pipefail

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

NS="teamA"
MOUNT="secret"
RGP_NAME="rgp-prod-writer-required"
TEST_KEY="prod/demo"
PLAIN_TOKEN_FILE=".vault-demo/${NS}.plain-reader.token"
WRITER_TOKEN_FILE=".vault-demo/${NS}.prod-writer.token"

NUKE_NAMESPACES=false; MODE="RUN"
for a in "$@"; do case "$a" in
  --clean) MODE="CLEAN" ;;
  --nuke-namespaces=true)  NUKE_NAMESPACES=true ;;
  --nuke-namespaces=false) NUKE_NAMESPACES=false ;;
esac; done

v(){ VAULT_ADDR="$VAULT_ADDR" VAULT_TOKEN="$VAULT_TOKEN" vault "$@"; }
ns_v(){ local ns="$1"; shift; VAULT_NAMESPACE="$ns" v "$@"; }
has_ns(){ v namespace list 2>/dev/null | grep -qx "${1}/"; }
has_mount(){ ns_v "$1" secrets list -format=json 2>/dev/null | jq -r 'keys[]? // empty' | grep -q "^${2}/$"; }
disable_mount_if_present(){ has_mount "$1" "$2" && ns_v "$1" secrets disable "$2" >/dev/null 2>&1 || true; }

ensure_namespace(){ local ns="$1"; has_ns "$ns" || { v namespace create "$ns" >/dev/null; echo "  ↳ created namespace '$ns'"; }; }
enable_kv_if_missing(){ local ns="$1" m="$2"; has_mount "$ns" "$m" || { ns_v "$ns" secrets enable -path="$m" kv-v2 >/dev/null; echo "  ↳ $ns: enabled kv-v2 at '${m}/'"; }; }
ensure_policy(){ local ns="$1" name="$2" hcl="$3"; ns_v "$ns" policy write "$name" - <<<"$hcl" >/dev/null; echo "  ↳ $ns: policy '$name' ensured"; }

ensure_token(){
  local ns="$1" pols_csv="$2" out="$3"
  mkdir -p "$(dirname "$out")"; rm -f "$out"
  local -a args=()
  IFS=',' read -ra _pols <<<"$pols_csv"
  for p in "${_pols[@]}"; do p="${p//[[:space:]]/}"; [[ -n "$p" ]] && args+=("-policy=${p}"); done
  local t
  t="$(ns_v "$ns" token create -orphan -format=json "${args[@]}" | jq -r .auth.client_token)"
  printf '%s' "$t" >"$out"
  chmod 0600 "$out"
  echo "  ↳ $ns: issued fresh token [${pols_csv}] → $out"
}

check_token_caps() {
  local ns="$1" token="$2" path="$3"
  echo -n "  ↪ token capabilities on '${path}': "
  VAULT_NAMESPACE="$ns" VAULT_TOKEN="$token" vault token capabilities "$path" | xargs echo
}

write_rgp_policy(){
  local tmp
  tmp="$(mktemp -t rgp.XXXXXX.sentinel)"
  cat >"$tmp" <<'SENTINEL'
import "request"
import "identity"

main = rule { not (request.operation in ["create","update","patch"]) or (identity.policy_names contains "prod-writer") }
SENTINEL

  VAULT_NAMESPACE="$NS" VAULT_ADDR="$VAULT_ADDR" VAULT_TOKEN="$VAULT_TOKEN" vault write "sys/policies/rgp/${RGP_NAME}" \
    enforcement_level="hard-mandatory" \
    paths="secret/data/prod/*" \
    policy=@"$tmp"

  rm -f "$tmp"
  echo "  ↳ RGP '${RGP_NAME}' ensured in ${NS}"
}


run_demo(){
  echo "🧭 DEMO 3: RGP — require 'prod-writer' for writes to ${MOUNT}/prod/* in ${NS}"
  local health ver; health="$(v status -format=json || true)"
  [[ -n "$health" ]] || { echo "❌ Cannot reach Vault"; exit 1; }
  ver="$(echo "$health" | jq -r '.version')"
  [[ "$ver" == *"+ent"* ]] || { echo "❌ Enterprise-only feature (RGP) required. Detected: $ver"; exit 1; }
  echo "✅ Vault Enterprise detected ($ver)"

  ensure_namespace "$NS"
  enable_kv_if_missing "$NS" "$MOUNT"
  write_rgp_policy

  ensure_policy "$NS" "plain-reader" '
path "secret/"                        { capabilities = ["create", "read", "update", "list"] }
path "secret/metadata/*"             { capabilities = ["read", "list"] }
path "secret/data/*"                 { capabilities = ["read", "list"] }
path "sys/internal/ui/mounts"        { capabilities = ["read"] }
path "sys/internal/ui/mounts/secret" { capabilities = ["read"] }
'

  ensure_policy "$NS" "prod-writer" '
path "secret/"                        { capabilities = ["create", "read", "update", "list"] }
path "secret/data/prod/*"            { capabilities = ["create", "update", "read", "list"] }
path "secret/metadata/*"             { capabilities = ["read", "list"] }
path "sys/internal/ui/mounts"        { capabilities = ["read"] }
path "sys/internal/ui/mounts/secret" { capabilities = ["read"] }
'

  ensure_token "$NS" "plain-reader"             "$PLAIN_TOKEN_FILE"
  ensure_token "$NS" "plain-reader,prod-writer" "$WRITER_TOKEN_FILE"
  PLAIN_TOKEN="$(cat "$PLAIN_TOKEN_FILE")"
  WRITER_TOKEN="$(cat "$WRITER_TOKEN_FILE")"

  echo; echo "## 🔍 Capabilities check"
  check_token_caps "$NS" "$PLAIN_TOKEN"  "$MOUNT/"
  check_token_caps "$NS" "$WRITER_TOKEN" "$MOUNT/"
  echo

  echo "### Tests (non-root tokens)"
  echo "# Write with plain-reader (should be denied)"
  set +e
  VAULT_CLI_NO_MOUNT_PERM_CHECK=1 VAULT_NAMESPACE="$NS" VAULT_TOKEN="$PLAIN_TOKEN" vault kv put -mount="$MOUNT" "$TEST_KEY" a=b &>/dev/null
  rc_plain=$?
  set -e
  [[ $rc_plain -ne 0 ]] && echo "# ❌ blocked / denied as expected" || echo "# ⚠️ expected denial"

  echo; echo "# Write with prod-writer (allowed)"
  VAULT_CLI_NO_MOUNT_PERM_CHECK=1 VAULT_NAMESPACE="$NS" VAULT_TOKEN="$WRITER_TOKEN" vault kv put -mount="$MOUNT" "$TEST_KEY" a=b >/dev/null && echo "# ✅ write ok"

  echo; echo "# Read with plain-reader (allowed)"
  VAULT_CLI_NO_MOUNT_PERM_CHECK=1 VAULT_NAMESPACE="$NS" VAULT_TOKEN="$PLAIN_TOKEN" vault kv get -mount="$MOUNT" "$TEST_KEY" >/dev/null && echo "# ✅ read ok"

  echo; echo "✅ DEMO 3 complete"
}

clean_demo(){
  echo "🧽 Cleanup: removing Demo 3 artifacts …"
  VAULT_NAMESPACE="$NS" v delete "sys/policies/rgp/${RGP_NAME}" >/dev/null 2>&1 || true
  VAULT_NAMESPACE="$NS" v policy delete "plain-reader" >/dev/null 2>&1 || true
  VAULT_NAMESPACE="$NS" v policy delete "prod-writer"  >/dev/null 2>&1 || true
  rm -f "$PLAIN_TOKEN_FILE" "$WRITER_TOKEN_FILE" 2>/dev/null || true
  VAULT_NAMESPACE="$NS" v kv metadata delete "${MOUNT}/prod" >/dev/null 2>&1 || true
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

if [[ "${1:-}" == "--clean" ]]; then
  [[ "${2:-}" == "--nuke-namespaces=true" ]] && NUKE_NAMESPACES=true
  clean_demo
  exit 0
fi
run_demo
# --- end of file ----------------------------------------------------------------