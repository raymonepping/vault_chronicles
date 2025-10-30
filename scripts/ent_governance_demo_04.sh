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

NS="teamA"                     # reuse teamA
MOUNT="secret"                 # kv-v2
EGP_NAME="egp-cutover-required"  # kept for compatibility (not used in RGP path)
RGP_NAME="rgp-cutover-required"  # actual RGP name we create
MARKER_POLICY="cutover-2025"
CLASS_KEY="classified/topsecret"
OLD_TOKEN_FILE=".vault-demo/${NS}.old-reader.token"
NEW_TOKEN_FILE=".vault-demo/${NS}.new-reader.token"

TRACE=false
NUKE_NAMESPACES=false
for a in "$@"; do
  case "$a" in
    --clean) MODE="CLEAN" ;;
    --nuke-namespaces=true)  NUKE_NAMESPACES=true ;;
    --nuke-namespaces=false) NUKE_NAMESPACES=false ;;
    --trace) TRACE=true ;;
  esac
done

v(){ VAULT_ADDR="$VAULT_ADDR" VAULT_TOKEN="$VAULT_TOKEN" vault "$@"; }
ns_v(){ local ns="$1"; shift; VAULT_NAMESPACE="$ns" v "$@"; }
has_ns(){ v namespace list 2>/dev/null | grep -qx "${1}/"; }
has_mount(){ ns_v "$1" secrets list -format=json 2>/dev/null | jq -r 'keys[]? // empty' | grep -q "^${2}/$"; }

ensure_namespace(){ local ns="$1"; has_ns "$ns" || { v namespace create "$ns" >/dev/null; echo "  ↳ created namespace '$ns'"; }; }
enable_kv_if_missing(){ local ns="$1" m="$2"; has_mount "$ns" "$m" || { ns_v "$ns" secrets enable -path="$m" kv-v2 >/dev/null; echo "  ↳ $ns: enabled kv-v2 at '${m}/'"; }; }
ensure_policy(){ local ns="$1" name="$2" hcl="$3"; ns_v "$ns" policy write "$name" - <<<"$hcl" >/dev/null; echo "  ↳ $ns: policy '$name' ensured"; }

# Issue a plain token + attach the RGP (governance policy)
ensure_token() {
  local ns="$1" pols_csv="$2" out="$3"
  mkdir -p "$(dirname "$out")"; rm -f "$out"

  # Split CSV into multiple policies=... args (trim spaces)
  local -a args
  IFS=',' read -ra _pols <<<"$pols_csv"
  for p in "${_pols[@]}"; do
    p="${p#"${p%%[![:space:]]*}"}"; p="${p%"${p##*[![:space:]]}"}"  # trim
    [[ -n "$p" ]] && args+=("policies=$p")
  done

  local token_json
  token_json="$(
    VAULT_NAMESPACE="$ns" VAULT_ADDR="$VAULT_ADDR" VAULT_TOKEN="$VAULT_TOKEN" \
      vault write -format=json auth/token/create \
        token_ttl="1h" \
        token_type="service" \
        token_governance_policies="$RGP_NAME" \
        "${args[@]}"
  )"

  printf '%s' "$(echo "$token_json" | jq -r .auth.client_token)" > "$out"
  chmod 0600 "$out"
  echo "  ↳ $ns: issued fresh token [${pols_csv}] + $RGP_NAME → $out"
}

write_rgp_policy(){
  local pol tmp_json out rc
  pol="$(mktemp -t rgp.XXXXXX.sentinel)"
  tmp_json="$(mktemp -t rgp.XXXXXX.json)"

  # RGP: require the "cutover-2025" policy for reads to secret/classified/*
  # Use a precondition to scope to your KV v2 read path.
  cat >"$pol" <<'SENTINEL'
import "strings"

# Only care about kv-v2 data reads for secret/classified/*
precond = rule {
  request.operation is "read" and strings.has_prefix(request.path, "secret/data/classified/")
}

main = rule when precond {
  identity.token is not null and
  identity.token.policies is not null and
  "cutover-2025" in identity.token.policies
}
SENTINEL

  echo "---- RGP policy being written ----"
  sed -n '1,200p' "$pol"
  echo "----------------------------------"

  # Clean install
  VAULT_NAMESPACE="$NS" VAULT_ADDR="$VAULT_ADDR" VAULT_TOKEN="$VAULT_TOKEN" \
    vault delete "sys/policies/rgp/$RGP_NAME" >/dev/null 2>&1 || true

  # Write via JSON using the 'policy' field
  jq -n \
    --rawfile policy "$pol" \
    --arg level "hard-mandatory" \
    '{enforcement_level:$level, policy:$policy}' >"$tmp_json"

  set +e
  out=$(VAULT_NAMESPACE="$NS" VAULT_ADDR="$VAULT_ADDR" VAULT_TOKEN="$VAULT_TOKEN" \
    vault write "sys/policies/rgp/$RGP_NAME" @"$tmp_json" 2>&1)
  rc=$?
  set -e

  if (( rc != 0 )); then
    echo "❌ RGP write failed. Vault said:"
    echo "$out"
    rm -f "$pol" "$tmp_json"
    exit 1
  fi

  echo "✔ Stored RGP policy body:"
  VAULT_NAMESPACE="$NS" VAULT_ADDR="$VAULT_ADDR" VAULT_TOKEN="$VAULT_TOKEN" \
    vault read -format=json "sys/policies/rgp/$RGP_NAME" | jq -r '.data.policy'

  rm -f "$pol" "$tmp_json"
  echo "  ↳ RGP '$RGP_NAME' ensured in ${NS}"
}

seed_secret(){
  # write once as root so the key exists
  ns_v "$NS" kv put -mount="$MOUNT" "$CLASS_KEY" s=t >/dev/null
  echo "  ↳ seeded ${MOUNT}/${CLASS_KEY}"
}

run_demo(){
  echo "🧭 DEMO 4 (RGP): require '${MARKER_POLICY}' to access ${MOUNT}/classified/* in ${NS}"
  local health ver; health="$(v status -format=json || true)"
  [[ -n "$health" ]] || { echo "❌ Cannot reach Vault"; exit 1; }
  ver="$(echo "$health" | jq -r '.version')"
  [[ "$ver" == *"+ent"* ]] || { echo "❌ Enterprise-only feature (RGP/EGP) required. Detected: $ver"; exit 1; }
  echo "✅ Vault Enterprise detected ($ver)"

  ensure_namespace "$NS"
  enable_kv_if_missing "$NS" "$MOUNT"
  seed_secret
  write_rgp_policy

  # ACLs: both readers can read classified/* — RGP will differentiate by marker.
  ensure_policy "$NS" "plain-reader" '
path "secret/"                        { capabilities = ["create", "read", "update", "list"] }
path "secret/data/*"                  { capabilities = ["read", "list"] }
path "secret/metadata/*"              { capabilities = ["read", "list"] }
path "sys/internal/ui/mounts"         { capabilities = ["read"] }
path "sys/internal/ui/mounts/secret"  { capabilities = ["read"] }
'
  # Marker policy (empty ACL body; exists purely as an identity marker)
  ensure_policy "$NS" "${MARKER_POLICY}" "# marker policy for cutover"

# Same, but also inject metadata on the token (optional)
ensure_token_with_meta() {
  local ns="$1" pols_csv="$2" out="$3"; shift 3
  mkdir -p "$(dirname "$out")"; rm -f "$out"

  # Split CSV into multiple policies=... args
  local -a args
  IFS=',' read -ra _pols <<<"$pols_csv"
  for p in "${_pols[@]}"; do
    p="${p#"${p%%[![:space:]]*}"}"; p="${p%"${p##*[![:space:]]}"}"
    [[ -n "$p" ]] && args+=("policies=$p")
  done

  # Metadata: pass as meta_<key>=<value>, e.g., meta_marker="cutover-2025"
  # Any extra meta pairs passed to this function are appended via "$@"
  local token_json
  token_json="$(
    VAULT_NAMESPACE="$ns" VAULT_ADDR="$VAULT_ADDR" VAULT_TOKEN="$VAULT_TOKEN" \
      vault write -format=json auth/token/create \
        token_ttl="1h" \
        token_type="service" \
        token_governance_policies="$RGP_NAME" \
        "${args[@]}" \
        "$@"
  )"

  printf '%s' "$(echo "$token_json" | jq -r .auth.client_token)" > "$out"
  chmod 0600 "$out"
  echo "  ↳ $ns: issued fresh token [${pols_csv} + metadata] + $RGP_NAME → $out"
}

  ensure_token "$NS" "plain-reader" "$OLD_TOKEN_FILE"
  ensure_token_with_meta "$NS" "plain-reader,${MARKER_POLICY}" "$NEW_TOKEN_FILE" \
    meta_marker="cutover-2025"

  OLD_TOKEN="$(command cat "$OLD_TOKEN_FILE")"
  NEW_TOKEN="$(command cat "$NEW_TOKEN_FILE")"

  echo "## Token policies (new):"
  VAULT_NAMESPACE="$NS" VAULT_TOKEN="$NEW_TOKEN" vault token lookup -format=json | jq -r '.data.policies, .data.identity_policies'

  echo; echo "### Tests"
  echo "# Old token (no marker) — should be denied by RGP"
  set +e
  VAULT_NAMESPACE="$NS" VAULT_TOKEN="$OLD_TOKEN" vault kv get -mount="$MOUNT" "$CLASS_KEY" 1>/dev/null 2>./.vault-demo/deny.trace; rc1=$?
  set -e
  if [[ $rc1 -ne 0 ]]; then
    echo "# ❌ denied as expected"
    if $TRACE; then
      echo "----- Sentinel trace (denial) -----"
      # Print trace section if present
      sed -n '/A trace of the execution/,$p' ./.vault-demo/deny.trace || true
      echo "-----------------------------------"
    fi
  else
    echo "# ⚠️ expected denial"
  fi

  echo; echo "# New token (has marker) — should be allowed"
  VAULT_NAMESPACE="$NS" VAULT_TOKEN="$NEW_TOKEN" vault kv get -mount="$MOUNT" "$CLASS_KEY" >/dev/null && echo "# ✅ read ok"

  echo
  echo "✅ DEMO 4 complete"
  echo "ℹ️  Token files:"
  echo "    OLD: $OLD_TOKEN_FILE"
  echo "    NEW: $NEW_TOKEN_FILE"
  echo "    Try: VAULT_NAMESPACE=$NS VAULT_TOKEN=\$(cat \"$NEW_TOKEN_FILE\") vault kv get -mount=$MOUNT $CLASS_KEY"
}

clean_demo(){
  echo "🧽 Cleanup: removing Demo 4 artifacts …"
  # Delete the RGP policy we created
  VAULT_NAMESPACE="$NS" v delete "sys/policies/rgp/${RGP_NAME}" >/dev/null 2>&1 || true
  # (EGP_NAME kept for compatibility in case of older runs)
  VAULT_NAMESPACE="$NS" v delete "sys/policies/egp/${EGP_NAME}" >/dev/null 2>&1 || true
  VAULT_NAMESPACE="$NS" v policy delete "${MARKER_POLICY}" >/dev/null 2>&1 || true
  rm -f "$OLD_TOKEN_FILE" "$NEW_TOKEN_FILE" ./.vault-demo/deny.trace 2>/dev/null || true
  VAULT_NAMESPACE="$NS" v kv metadata delete "${MOUNT}/classified" >/dev/null 2>&1 || true
  echo "✅ Cleanup complete."
}

if [[ "${1:-}" == "--clean" ]]; then clean_demo; exit 0; fi
run_demo
