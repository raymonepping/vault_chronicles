#!/usr/bin/env bash
set -euo pipefail

# ent_integrations_control_groups_05.sh
# Vault Enterprise/HCP: Control Groups (dual authorization) + controlled_capabilities demo
#
# Scenario:
# - REQUESTER can read EU_GDPR_data/orders/* only after approval from acct_manager (APPROVER).
# - For paris-kv/*, reads are open; create/update/delete require approval (controlled_capabilities).
#
# Personas:
#   admin (you, with ADMIN token) • requester (e.g., joey) • approver (e.g., michelle, in acct_manager)

OK="✅"; INFO="🧭"; WARN="⚠️"

# ===== Defaults =====
VAULT_ADDR="${VAULT_ADDR:-http://127.0.0.1:18200}"
NAMESPACE="${NAMESPACE:-teamA}"
USERPASS_PATH="${USERPASS_PATH:-userpass}"

# Back-compat ENV (BOB/ELLEN) + new flexible names (REQUESTER/APPROVER)
REQUESTER_USER="${REQUESTER_USER:-${BOB_USER:-bob}}"
REQUESTER_PASS="${REQUESTER_PASS:-${BOB_PASS:-training}}"
APPROVER_USER="${APPROVER_USER:-${ELLEN_USER:-ellen}}"
APPROVER_PASS="${APPROVER_PASS:-${ELLEN_PASS:-training}}"

POL_READ_GDPR="read-gdpr-order"
POL_ACCT_MGR="acct_manager"
POL_RESTRICT_PARIS="restrict-paris"
GROUP_ACCT_MGR="acct_manager"

KV_GDPR_PATH="${KV_GDPR_PATH:-EU_GDPR_data}"  # kv-v2
KV_PARIS_PATH="${KV_PARIS_PATH:-paris-kv}"    # kv-v2

# Flags
NAMES_ONLY=false
QUIET=false
RESULTS_ONLY=false
JSON_OUT=false
FRESH=false
CLEAN_ONLY=false
VERIFY_ONLY=false
SKIP_PARIS=false
KEEP_ENV_TOKEN=false
DEBUG=false

# Admin token intake (order: --admin-token > VAULT_ADMIN_TOKEN > VAULT_TOKEN)
ADMIN_TOKEN="${ADMIN_TOKEN:-${VAULT_ADMIN_TOKEN:-${VAULT_TOKEN:-}}}"

usage() {
  cat <<'EOF'
ent_integrations_control_groups_05.sh — Vault Enterprise/HCP Control Groups demo

USAGE
  ent_integrations_control_groups_05.sh
    [--namespace NAME] [--auth-path PATH]
    [--requester NAME] [--requester-pass PASS]
    [--requestor NAME] [--requestor-pass PASS]   # alias spelling
    [--approver NAME] [--approver-pass PASS]
    [--admin-token TOKEN] [--keep-env-token] [--debug]
    [--fresh] [--clean] [--verify-only] [--skip-paris]
    [--json] [--quiet] [--results-only] [-h|--help]

NOTES
  - Script unsets VAULT_TOKEN by default to avoid login contamination.
    Provide admin token with --admin-token or VAULT_ADMIN_TOKEN, or use --keep-env-token.
EOF
}

# ===== Helpers =====
need() { command -v "$1" >/dev/null 2>&1 || { echo "$WARN Missing dependency: $1"; exit 1; }; }
say_info(){ $QUIET && $RESULTS_ONLY && return || echo "$INFO $*"; }
say_ok(){ echo "$OK $*"; }
say_warn(){ $QUIET && $RESULTS_ONLY && return || echo "$WARN $*"; }
err(){ echo "❌ $*" >&2; }
dbg(){ $DEBUG && echo "🔎 $*" >&2 || true; }
trim() { sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'; }

need vault; need jq
export VAULT_ADDR

# ===== Parse args =====
while [[ $# -gt 0 ]]; do
  case "$1" in
    --namespace) NAMESPACE="$2"; shift 2 ;;
    --auth-path) USERPASS_PATH="$2"; shift 2 ;;
    --names-only) NAMES_ONLY=true; shift ;;
    --requester|--requestor) REQUESTER_USER="$2"; shift 2 ;;
    --requester-pass|--requestor-pass) REQUESTER_PASS="$2"; shift 2 ;;
    --approver) APPROVER_USER="$2"; shift 2 ;;
    --approver-pass) APPROVER_PASS="$2"; shift 2 ;;
    --admin-token) ADMIN_TOKEN="$2"; shift 2 ;;
    --keep-env-token) KEEP_ENV_TOKEN=true; shift ;;
    --verify-only) VERIFY_ONLY=true; shift ;;
    --skip-paris) SKIP_PARIS=true; shift ;;
    --fresh) FRESH=true; shift ;;
    --clean) CLEAN_ONLY=true; shift ;;
    --json) JSON_OUT=true; shift ;;
    --quiet) QUIET=true; shift ;;
    --results-only) RESULTS_ONLY=true; shift ;;
    --debug) DEBUG=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) err "Unknown arg: $1"; usage; exit 1 ;;
  esac
done

if $NAMES_ONLY; then
  if $JSON_OUT; then
    jq -n \
      --arg namespace "${NAMESPACE}" \
      --arg auth_path "${USERPASS_PATH}" \
      --arg requester "${REQUESTER_USER}" \
      --arg approver "${APPROVER_USER}" \
      --arg admin_token "${ADMIN_TOKEN:+provided}" \
      '{namespace:$namespace, auth:$auth_path, requester:$requester, approver:$approver, admin_token:$admin_token}'
  else
    echo "🧭 Effective configuration:"
    echo "  Namespace:    ${NAMESPACE}"
    echo "  Auth path:    ${USERPASS_PATH}"
    echo "  Requester:    ${REQUESTER_USER}"
    echo "  Approver:     ${APPROVER_USER}"
    echo "  Admin token:  ${ADMIN_TOKEN:+(provided)}"
  fi
  exit 0
fi

# ===== Token hygiene =====
if ! $KEEP_ENV_TOKEN; then
  : "${ADMIN_TOKEN:?Admin token missing. Pass --admin-token or set VAULT_ADMIN_TOKEN/VAULT_TOKEN before running.}"
  unset VAULT_TOKEN
fi
export VAULT_TOKEN="$ADMIN_TOKEN"

# Namespace-aware wrappers (admin context)
vns()   { VAULT_NAMESPACE="$NAMESPACE" vault "$@"; }
vroot() { VAULT_NAMESPACE= vault "$@"; }

ns_exists() { vroot read -format=json "sys/namespaces/$NAMESPACE" >/dev/null 2>&1; }
current_userpass_accessor() { vns auth list -format=json | jq -r '."'"$USERPASS_PATH"'/".accessor'; }

# Approval status (by accessor)
_check_approved() { # $1=approver_token  $2=accessor
  local etok="$1" acc="$2" js approved
  js="$(VAULT_NAMESPACE="$NAMESPACE" VAULT_TOKEN="$etok" vault write -format=json sys/control-group/request accessor="$acc" 2>/dev/null || true)"
  dbg "request status: $js"
  approved="$(jq -r '.data.approved // empty' <<<"$js")"
  [[ "$approved" == "true" ]] && echo true || echo false
}

wait_for_approval() { # $1=accessor  $2=approver_token
  local acc="$1" etok="$2" tries=60
  while ((tries-- > 0)); do
    [[ "$(_check_approved "$etok" "$acc")" == "true" ]] && return 0
    sleep 0.5
  done
  return 1
}

unwrap_with_retries() { # $1=wrap_token  $2=requester_token
  local wt="$1" bt="$2" tries=8
  while ((tries-- > 0)); do
    if VAULT_NAMESPACE="$NAMESPACE" VAULT_TOKEN="$bt" vault unwrap "$wt"; then return 0; fi
    sleep 0.4
  done
  return 1
}

# User login (explicitly without admin token)
login_user() {  # $1=username $2=password -> prints token
  VAULT_NAMESPACE="$NAMESPACE" env -u VAULT_TOKEN \
    vault login -method=userpass -format=json username="$1" password="$2" \
    | jq -r .auth.client_token
}

# Assert the login token maps to the intended Identity entity (alias sanity check)
assert_alias_maps() { # $1=login_token  $2=expected_entity_name
  local tok="$1" want="$2" eid self name
  eid="$(vns read -format=json "identity/entity/name/$want" 2>/dev/null | jq -r '.data.id // empty')"
  [[ -n "$eid" ]] || { err "Identity entity '$want' not found in namespace '$NAMESPACE'"; exit 1; }
  self="$(VAULT_NAMESPACE="$NAMESPACE" VAULT_TOKEN="$tok" vault token lookup -format=json)"
  name="$(jq -r '.data.entity_id // empty' <<<"$self")"
  dbg "expected entity_id=$(jq -r '.data.id' <<<"$(vns read -format=json identity/entity/name/"$want")") ; got entity_id=$name"
  [[ -n "$name" && "$name" == "$eid" ]] || {
    err "Login alias did not map to entity '$want' (entity_id mismatch). Check entity-alias mount_accessor and username."
    echo "Hint: expected=$eid ; got=${name:-<empty>} ; USERPASS_PATH=$USERPASS_PATH ; accessor=$(current_userpass_accessor)" >&2
    exit 1
  }
}

cleanup() {
  say_info "🧽 Cleanup in namespace '${NAMESPACE}' ..."
  vns delete "identity/group/name/${GROUP_ACCT_MGR}" >/dev/null 2>&1 || true
  vns delete "identity/entity/name/${REQUESTER_USER}" >/dev/null 2>&1 || true
  vns delete "identity/entity/name/${APPROVER_USER}"  >/dev/null 2>&1 || true
  vns delete "auth/${USERPASS_PATH}/users/${REQUESTER_USER}" >/dev/null 2>&1 || true
  vns delete "auth/${USERPASS_PATH}/users/${APPROVER_USER}"  >/dev/null 2>&1 || true
  vns policy delete "${POL_READ_GDPR}"      >/dev/null 2>&1 || true
  vns policy delete "${POL_ACCT_MGR}"       >/dev/null 2>&1 || true
  vns policy delete "${POL_RESTRICT_PARIS}" >/dev/null 2>&1 || true
  vns secrets disable "${KV_GDPR_PATH}" >/dev/null 2>&1 || true
  vns secrets disable "${KV_PARIS_PATH}" >/dev/null 2>&1 || true
  if vns auth list -format=json | jq -e 'has("'"${USERPASS_PATH}"'/")' >/dev/null 2>&1; then
    vns auth disable "${USERPASS_PATH}" >/dev/null 2>&1 || true
  fi
  say_ok "Cleanup complete."
}

ensure_ns_and_userpass() {
  if ns_exists; then say_info "Namespace '${NAMESPACE}' exists."
  else
    say_info "Creating namespace '${NAMESPACE}' ..."
    vroot namespace create "${NAMESPACE}" >/dev/null
    say_ok "Namespace ready."
  fi

  if vns auth list -format=json | jq -e 'has("'"${USERPASS_PATH}"'/")' >/dev/null 2>&1; then
    say_info "userpass already enabled at '${USERPASS_PATH}'."
  else
    say_info "Enabling userpass at '${USERPASS_PATH}' ..."
    vns auth enable -path="${USERPASS_PATH}" userpass >/dev/null
    say_ok "userpass enabled."
  fi
}

write_policies() {
  say_info "Writing policies ..."
  local f1 f2 f3
  f1="$(mktemp)"; f2="$(mktemp)"; f3="$(mktemp)"

  cat > "$f1" <<'HCL'
path "EU_GDPR_data/data/orders/*" {
  capabilities = ["read"]
  control_group = {
    factor "authorizer" {
      identity {
        group_names = ["acct_manager"]
        approvals = 1
      }
    }
  }
}
HCL
  vns policy write "${POL_READ_GDPR}" "$f1" >/dev/null

  cat > "$f2" <<'HCL'
path "sys/control-group/authorize" { capabilities = ["create","update"] }
path "sys/control-group/request"   { capabilities = ["create","update"] }
HCL
  vns policy write "${POL_ACCT_MGR}" "$f2" >/dev/null

  cat > "$f3" <<'HCL'
path "paris-kv/*" {
  capabilities = ["create","read","update","delete","list"]
  control_group = {
    factor "managers" {
      controlled_capabilities = ["create","update","delete"]
      identity {
        group_names = ["acct_manager"]
        approvals = 1
      }
    }
  }
}
HCL
  vns policy write "${POL_RESTRICT_PARIS}" "$f3" >/dev/null

  say_ok "Policies uploaded: ${POL_READ_GDPR}, ${POL_ACCT_MGR}, ${POL_RESTRICT_PARIS}"
}

create_personas() {
  say_info "Creating users and identities ..."
  vns write "auth/${USERPASS_PATH}/users/${REQUESTER_USER}" password="${REQUESTER_PASS}" policies="${POL_READ_GDPR},${POL_RESTRICT_PARIS}" >/dev/null || true
  vns write "auth/${USERPASS_PATH}/users/${APPROVER_USER}"  password="${APPROVER_PASS}"  policies="${POL_ACCT_MGR}" >/dev/null || true

  # Identity entities match login usernames (keeps alias mapping simple)
  REQ_ID="$(vns write -format=json identity/entity name="${REQUESTER_USER}" policies="${POL_READ_GDPR},${POL_RESTRICT_PARIS}" metadata=team="Processor" | jq -r .data.id)"
  APP_ID="$(vns write -format=json identity/entity name="${APPROVER_USER}" policies="${POL_ACCT_MGR}" metadata=team="AcctController" | jq -r .data.id)"

  UP_ACC="$(current_userpass_accessor || true)"
  [[ -n "$UP_ACC" && "$UP_ACC" != "null" ]] || { err "Could not resolve userpass accessor; abort."; exit 1; }

  vns write identity/entity-alias name="${REQUESTER_USER}" canonical_id="${REQ_ID}" mount_accessor="${UP_ACC}" >/dev/null || true
  vns write identity/entity-alias name="${APPROVER_USER}"  canonical_id="${APP_ID}" mount_accessor="${UP_ACC}" >/dev/null || true

  # Identity group for approvers
  vns write -format=json identity/group name="${GROUP_ACCT_MGR}" policies="${POL_ACCT_MGR}" member_entity_ids="${APP_ID}" >/dev/null

  say_ok "Personas ready: ${REQUESTER_USER} (requester), ${APPROVER_USER} (approver in ${GROUP_ACCT_MGR})"
}

setup_kv_and_sample() {
  say_info "Enabling kv-v2 at ${KV_GDPR_PATH} and writing sample order ..."
  vns secrets enable -path="${KV_GDPR_PATH}" -version=2 kv >/dev/null 2>&1 || true
  vns kv put "${KV_GDPR_PATH}/orders/acct1" order_number="12345678" product_id="987654321" >/dev/null

  $SKIP_PARIS && return 0
  say_info "Enabling kv-v2 at ${KV_PARIS_PATH} and writing sample product ..."
  vns secrets enable -path="${KV_PARIS_PATH}" -version=2 kv >/dev/null 2>&1 || true
  vns kv put "${KV_PARIS_PATH}/product" name="Boundary" version="0.4.0" >/dev/null
}

run_gdpr_flow() {
  say_info "Requester ${REQUESTER_USER} requests ${KV_GDPR_PATH}/orders/acct1 (should return wrapping token) ..."
  local requester_token approver_token out wrap_token wrap_acc

  requester_token="$(login_user "${REQUESTER_USER}" "${REQUESTER_PASS}")"
  assert_alias_maps "${requester_token}" "${REQUESTER_USER}"
  approver_token="$(login_user "${APPROVER_USER}" "${APPROVER_PASS}")"
  assert_alias_maps "${approver_token}" "${APPROVER_USER}"

  out="$(VAULT_NAMESPACE="${NAMESPACE}" VAULT_TOKEN="${requester_token}" vault kv get -format=json "${KV_GDPR_PATH}/orders/acct1" 2>/dev/null || true)"
  wrap_token="$(jq -r '.wrap_info.token // empty' <<<"$out")"
  wrap_acc="$(jq -r '.wrap_info.accessor // empty' <<<"$out")"
  if [[ -z "$wrap_token" || -z "$wrap_acc" ]]; then
    local pretty
    pretty="$(VAULT_NAMESPACE="${NAMESPACE}" VAULT_TOKEN="${requester_token}" vault kv get "${KV_GDPR_PATH}/orders/acct1" 2>/dev/null || true)"
    echo "$pretty" | grep -q "wrapping_token:" || { echo "$pretty"; err "Expected wrapping token in response; check policies/namespace."; exit 1; }
    wrap_token="$(echo "$pretty" | awk '/wrapping_token:/ {print $2}' | trim)"
    wrap_acc="$(echo "$pretty"   | awk '/wrapping_accessor:/ {print $2}' | trim)"
  fi
  dbg "WRAP_TOKEN=$wrap_token"
  dbg "WRAP_ACCESSOR=$wrap_acc"
  [[ -n "$wrap_acc" && ${#wrap_acc} -ge 10 ]] || { err "Invalid wrapping accessor"; exit 1; }
  say_ok "${REQUESTER_USER} received wrapping_token + accessor."

  $VERIFY_ONLY && { echo "  (verify-only: not approving/unwrap)"; WRAP_TOKEN="$wrap_token"; WRAP_ACCESSOR="$wrap_acc"; return 0; }

  VAULT_NAMESPACE="${NAMESPACE}" VAULT_TOKEN="${approver_token}" vault write sys/control-group/request accessor="${wrap_acc}" >/dev/null || true
  VAULT_NAMESPACE="${NAMESPACE}" VAULT_TOKEN="${approver_token}" vault write sys/control-group/authorize accessor="${wrap_acc}" >/dev/null || true

  if ! wait_for_approval "${wrap_acc}" "${approver_token}"; then
    VAULT_NAMESPACE="${NAMESPACE}" VAULT_TOKEN="${approver_token}" vault write -format=json sys/control-group/request accessor="${wrap_acc}" || true
    err "Approval did not reach 'approved:true' — verify ${APPROVER_USER} is in Identity group '${GROUP_ACCT_MGR}' (namespace '${NAMESPACE}')."
    exit 1
  fi

  say_info "Requester ${REQUESTER_USER} unwraps the secret ..."
  if ! unwrap_with_retries "${wrap_token}" "${requester_token}"; then
    err "Unwrap failed after approval (race/propagation?)"; exit 1
  fi

  WRAP_TOKEN="${wrap_token}"
  WRAP_ACCESSOR="${wrap_acc}"
}

run_paris_flow() {
  $SKIP_PARIS && return 0
  say_info "Controlled capabilities @ ${KV_PARIS_PATH}/product"

  local requester_token; requester_token="$(login_user "${REQUESTER_USER}" "${REQUESTER_PASS}")"
  assert_alias_maps "${requester_token}" "${REQUESTER_USER}"

  say_info "Read should pass without approval ..."
  VAULT_NAMESPACE="${NAMESPACE}" VAULT_TOKEN="${requester_token}" vault kv get "${KV_PARIS_PATH}/product" >/dev/null
  say_ok "Read OK."

  say_info "Delete should trigger wrapping (requires approval) ..."
  local del_json; del_json="$(VAULT_NAMESPACE="${NAMESPACE}" VAULT_TOKEN="${requester_token}" vault kv delete -format=json "${KV_PARIS_PATH}/product" 2>/dev/null || true)"
  PARIS_WRAP_TOKEN="$(jq -r '.wrap_info.token // empty' <<<"$del_json")"
  PARIS_WRAP_ACC="$(jq -r '.wrap_info.accessor // empty' <<<"$del_json")"

  if [[ -z "${PARIS_WRAP_TOKEN}" || -z "${PARIS_WRAP_ACC}" ]]; then
    local del_out; del_out="$(VAULT_NAMESPACE="${NAMESPACE}" VAULT_TOKEN="${requester_token}" vault kv delete "${KV_PARIS_PATH}/product" 2>/dev/null || true)"
    if echo "$del_out" | grep -q "wrapping_token:"; then
      PARIS_WRAP_TOKEN="$(echo "$del_out" | awk '/wrapping_token:/ {print $2}' | trim)"
      PARIS_WRAP_ACC="$(echo "$del_out"   | awk '/wrapping_accessor:/ {print $2}' | trim)"
    else
      echo "$del_out"
      say_warn "Delete did not produce wrapping_token; verify ${POL_RESTRICT_PARIS} is applied to ${REQUESTER_USER}."
      return 0
    fi
  fi
  dbg "PARIS_WRAP_TOKEN=${PARIS_WRAP_TOKEN}"
  dbg "PARIS_WRAP_ACCESSOR=${PARIS_WRAP_ACC}"
  say_ok "Delete wrapped as intended."

  say_info "Approving delete as ${APPROVER_USER} ..."
  local approver_token; approver_token="$(login_user "${APPROVER_USER}" "${APPROVER_PASS}")"
  assert_alias_maps "${approver_token}" "${APPROVER_USER}"
  VAULT_NAMESPACE="${NAMESPACE}" VAULT_TOKEN="${approver_token}" vault write sys/control-group/request accessor="${PARIS_WRAP_ACC}" >/dev/null
  VAULT_NAMESPACE="${NAMESPACE}" VAULT_TOKEN="${approver_token}" vault write sys/control-group/authorize accessor="${PARIS_WRAP_ACC}" >/dev/null

  if ! wait_for_approval "${PARIS_WRAP_ACC}" "${approver_token}"; then
    say_warn "Approval for paris delete did not reach 'approved:true' in time"
  fi
}

main() {
  $QUIET || say_info "Using VAULT_ADDR=${VAULT_ADDR}  namespace=${NAMESPACE}  requester/approver: ${REQUESTER_USER}/${APPROVER_USER}"

  if $FRESH; then cleanup; $QUIET || echo; fi
  if $CLEAN_ONLY; then cleanup; exit 0; fi

  ensure_ns_and_userpass
  write_policies
  create_personas
  setup_kv_and_sample

  if $VERIFY_ONLY; then
    say_info "Verify-only mode: setup complete; skipping request/approval."
  else
    run_gdpr_flow
    run_paris_flow
  fi

  if $JSON_OUT; then
    jq -n \
      --arg namespace "${NAMESPACE}" \
      --arg userpass_path "${USERPASS_PATH}" \
      --arg requester "${REQUESTER_USER}" \
      --arg approver "${APPROVER_USER}" \
      --arg policy_read "${POL_READ_GDPR}" \
      --arg policy_mgr "${POL_ACCT_MGR}" \
      --arg policy_paris "${POL_RESTRICT_PARIS}" \
      --arg kv1 "${KV_GDPR_PATH}" \
      --arg kv2 "${KV_PARIS_PATH}" \
      --arg wrap_token "${WRAP_TOKEN:-}" \
      --arg wrap_accessor "${WRAP_ACCESSOR:-}" \
      --arg paris_wrap_token "${PARIS_WRAP_TOKEN:-}" \
      --arg paris_wrap_accessor "${PARIS_WRAP_ACC:-}" \
      '{namespace:$namespace, auth:$userpass_path, users:{requester:$requester, approver:$approver},
        policies:{read_gdpr:$policy_read, acct_mgr:$policy_mgr, restrict_paris:$policy_paris},
        kv:{gdpr:$kv1, paris:$kv2},
        gdpr_wrap:{token:$wrap_token, accessor:$wrap_accessor},
        paris_wrap:{token:$paris_wrap_token, accessor:$paris_wrap_accessor}}'
  fi

  say_ok "Control Groups demo complete."
}

main
say_ok "🎉 All done."
