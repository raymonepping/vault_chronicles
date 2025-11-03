#!/usr/bin/env bash
set -euo pipefail

# ent_integrations_mfa_05.sh (fixed)
# Enterprise demo: Namespace + userpass + TOTP MFA login enforcement (Identity)
# - Enables userpass in a namespace
# - Creates user + entity + alias
# - Creates Identity TOTP method + login enforcement on the userpass accessor
# - Admin-generates TOTP seed, mirrors seed into `totp/` to mint codes
# - Performs login via API with X-Vault-MFA header
# - Verifies token identity fields

# ========== Emojis / UI ==========
OK="✅"; INFO="🧭"; WARN="⚠️"; ARROW="↳"

# ========== Defaults (overridable) ==========
VAULT_ADDR="${VAULT_ADDR:-http://127.0.0.1:18200}"
VAULT_TOKEN="${VAULT_TOKEN:-}"

NAMESPACE="${NAMESPACE:-teamA}"
USERPASS_PATH="${USERPASS_PATH:-userpass}"

USERNAME="${USERNAME:-alice}"
PASSWORD="${PASSWORD:-s3cretP@ss}"

POLICY_NAME="${POLICY_NAME:-totp-policy}"
MFA_ENF_NAME="${MFA_ENF_NAME:-chronicles-enf}"
ISSUER="${ISSUER:-Vault}"
ALG="${ALG:-SHA1}"
DIGITS="${DIGITS:-6}"
PERIOD="${PERIOD:-30}"

# Flags
QUIET=false
RESULTS_ONLY=false
JSON_OUT=false
SHOW_CURL=false
REDACT_TOKEN=true
CLEAN_ONLY=false
FRESH=false
VERIFY_ONLY=false
ENFORCE_ENTITY=false       # (supported but we default to accessor)
PRINT_ONLY=false
SHOW_QR=false              # save QR to file
CLEAN_USER=""
REVOKE_TOKEN=false

# ========== Helpers ==========
need() { command -v "$1" >/dev/null 2>&1 || { echo "$WARN Missing dependency: $1"; exit 1; }; }
say_info(){ $QUIET && $RESULTS_ONLY && return || echo "$INFO $*"; }
say_ok(){ echo "$OK $*"; }
say_warn(){ $QUIET && $RESULTS_ONLY && return || echo "$WARN $*"; }
err(){ echo "❌ $*" >&2; }

usage() {
  cat <<'EOF'
ent_integrations_mfa_05.sh — Vault Enterprise: userpass + TOTP MFA (Identity)

USAGE
  ent_integrations_mfa_05.sh
    [--namespace NAME] [--user NAME] [--pass PASS]
    [--auth-path PATH] [--policy NAME]
    [--issuer NAME] [--alg ALG] [--digits N] [--period SEC]
    [--show-qr] [--show-curl] [--json] [--quiet] [--results-only]
    [--print-only] [--verify-only] [--enforce-entity]
    [--revoke]
    [--fresh] [--clean] [--clean-user NAME]
    [-h|--help]

WHAT IT DOES
  • Ensures/uses a namespace (Enterprise).
  • Enables userpass auth at the given path in that namespace.
  • Creates a user + Identity entity + alias (bound to the userpass accessor).
  • Creates an Identity TOTP method and enforces it for the userpass accessor.
  • Admin-generates a TOTP secret (if new), optionally saves a QR PNG,
    mirrors the base32 seed into `totp/` to mint codes for the demo.
  • Performs a login via API with X-Vault-MFA header and verifies token identity.
  • (Optional) Revokes the issued token and confirms revocation.

OPTIONS
  --namespace NAME        Namespace to use/create (default: teamA)
  --auth-path PATH        Auth mount path for userpass (default: userpass)
  --user NAME             Username to create/login (default: alice)
  --pass PASS             Password to set/use (default: s3cretP@ss)

  --policy NAME           Policy to attach to the user (default: totp-policy)
  --issuer NAME           TOTP issuer label (default: Vault)
  --alg ALG               TOTP algorithm (default: SHA1)
  --digits N              TOTP code digits (default: 6)
  --period SEC            TOTP period in seconds (default: 30)

  --show-qr               Save the admin-generated QR to ./qr_<user>.png (if new seed)
  --show-curl             Echo equivalent curl calls (redacts token unless --no-redact)
  --redact-token          (default) Redact admin token in curl output
  --no-redact             Show real admin token in curl output (careful!)
  --json                  Emit a compact JSON summary at the end
  --quiet                 Minimize chatty output
  --results-only          Only show key results (pairs well with --quiet)
  --print-only            Stop after printing accessor/entity hints (no changes)
  --verify-only           Show enforcement/targets; skip login flow
  --enforce-entity        (Advanced) Enforce MFA on the entity instead of accessor
  --revoke                After successful login, revoke the issued token and verify it

CLEANUP / RESET
  --fresh                 Run full cleanup first, then proceed
  --clean                 Cleanup and exit (remove enforcement/method/user/entity; disable userpass)
  --clean-user NAME       Remove just that user + entity in the namespace (quick re-enroll)

NOTES & BEHAVIOR
  • If the entity already has a TOTP credential, admin-generate returns no URI;
    the script warns and expects an existing `totp/keys/<user>` to mint codes.
  • CLI `vault login` can be finicky for MFA challenges; this script uses curl with X-Vault-MFA.
  • Accessor-based enforcement is simple for demos; entity-based is more resilient if auth mounts rotate.

PREREQUISITES
  - VAULT_TOKEN: admin token (exported in your shell)
  - Tools: vault, jq, base64
  - VAULT_ADDR: http://127.0.0.1:18200 (override via env if needed)

ENV DEFAULTS (current)
  VAULT_ADDR=http://127.0.0.1:18200
  NAMESPACE=teamA         USERPASS_PATH=userpass
  USERNAME=alice          PASSWORD=s3cretP@ss
  POLICY_NAME=totp-policy
  MFA_ENF_NAME=chronicles-enf   ISSUER=Vault
  ALG=SHA1  DIGITS=6  PERIOD=30

EXAMPLES
  # Quick demo in teamA with a new user, save the QR, and revoke the token afterwards
  VAULT_TOKEN=<root-or-admin> ./ent_integrations_mfa_05.sh \
    --namespace teamA --user Quintus --pass swordfish --show-qr --revoke

  # Show only the targets for enforcement (accessor/entity), without doing the login flow
  ./ent_integrations_mfa_05.sh --namespace teamA --user Alice --verify-only

  # Clean just a user/entity to re-enroll
  ./ent_integrations_mfa_05.sh --namespace teamA --clean-user Alice

  # Full cleanup of the demo artifacts and exit
  ./ent_integrations_mfa_05.sh --namespace teamA --clean
EOF
}

# ========== Parse args ==========
while [[ $# -gt 0 ]]; do
  case "$1" in
    --namespace) NAMESPACE="$2"; shift 2 ;;
    --user) USERNAME="$2"; shift 2 ;;
    --pass) PASSWORD="$2"; shift 2 ;;
    --show-curl) SHOW_CURL=true; shift ;;
    --redact-token) REDACT_TOKEN=true; shift ;;
    --no-redact) REDACT_TOKEN=false; shift ;;
    --json) JSON_OUT=true; shift ;;
    --quiet) QUIET=true; shift ;;
    --results-only) RESULTS_ONLY=true; shift ;;
    --fresh) FRESH=true; shift ;;
    --clean) CLEAN_ONLY=true; shift ;;
    --verify-only) VERIFY_ONLY=true; shift ;;
    --enforce-entity) ENFORCE_ENTITY=true; shift ;;
    --print-only) PRINT_ONLY=true; shift ;;
    --show-qr) SHOW_QR=true; shift ;;
    --revoke) REVOKE_TOKEN=true; shift ;;
    --clean-user) CLEAN_USER="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) err "Unknown arg: $1"; usage; exit 1 ;;
  esac
done

need vault; need jq
[[ -n "$VAULT_TOKEN" ]] || { err "VAULT_TOKEN not set"; exit 1; }
export VAULT_ADDR

curl_ns=""
[[ -n "$NAMESPACE" ]] && curl_ns='-H "X-Vault-Namespace: '"$NAMESPACE"'" '

say_curl() {
  $SHOW_CURL || return 0
  local method="$1"; local path="$2"; local data="${3:-}"
  local tok='-H "X-Vault-Token: ********" '; $REDACT_TOKEN || tok='-H "X-Vault-Token: $VAULT_TOKEN" '
  local ns="$curl_ns"
  [[ -n "$ns" ]] || ns=""
  local base="command curl -sS -X $method \"$VAULT_ADDR/v1/$path\" $tok${ns}-H \"Content-Type: application/json\""
  if [[ -n "$data" ]]; then
    echo " $ARROW $base -d '$data'"
  else
    echo " $ARROW $base"
  fi
}

# Returns 0 if POST succeeded; prints body on error.
_try_post() {
  local path="$1"
  local data="${2:-{}}"
  local ns="${3-}"
  local ns_hdr=()
  [[ -n "$ns" ]] && ns_hdr=(-H "X-Vault-Namespace: $ns")
  local resp http body
  resp="$(command curl -sS -w '\n%{http_code}' -X POST \
    "$VAULT_ADDR/v1/$path" \
    -H "X-Vault-Token: $VAULT_TOKEN" \
    "${ns_hdr[@]}" \
    -H "Content-Type: application/json" \
    -d "$data" 2>/dev/null)"
  http="${resp##*$'\n'}"
  body="${resp%$'\n'*}"
  if [[ "$http" =~ ^2 ]]; then printf '%s' "$body"; return 0; fi
  printf '%s' "$body" >&2; return 1
}

# Namespace-aware vault wrappers
vns()   { VAULT_NAMESPACE="$NAMESPACE" vault "$@"; }
vroot() { VAULT_NAMESPACE= vault "$@"; } # root ns
v()     { vns "$@"; }

# Robust namespace existence check
ns_exists() { vroot read -format=json "sys/namespaces/$NAMESPACE" >/dev/null 2>&1; }

current_userpass_accessor() {
  vns auth list -format=json | jq -r '."'"$USERPASS_PATH"'/".accessor'
}

clean_user() {
  local user="$1"
  local eid
  eid="$(vns read -format=json "identity/entity/name/$user" 2>/dev/null | jq -r '.data.id // empty')"
  [[ -n "$eid" ]] && vns delete "identity/entity/id/$eid" >/dev/null 2>&1 || true
  vns delete "auth/$USERPASS_PATH/users/$user" >/dev/null 2>&1 || true
  say_ok "Cleaned user + entity for $user"
}

get_qp() { # Extract ?key=value from an otpauth:// URL
  local url="$1" key="$2"
  printf '%s' "${url#*\?}" | tr '&' '\n' | awk -F= -v k="$key" '$1==k {print $2; exit}'
}

# ====== Steps ======
enable_userpass_if_needed() {
  if vns auth list -format=json | jq -e 'has("'"$USERPASS_PATH"'/")' >/dev/null 2>&1; then
    say_info "userpass already enabled in '$NAMESPACE'."
  else
    say_info "Enabling userpass in '$NAMESPACE'…"
    say_curl POST "sys/auth/$USERPASS_PATH" '{"type":"userpass"}'
    vns auth enable -path="$USERPASS_PATH" userpass >/dev/null
    say_ok "userpass enabled."
  fi
  say_info "Current userpass accessor in '$NAMESPACE': $(current_userpass_accessor || echo "<unknown>")"
}

write_policy() {
  say_info "Writing policy '$POLICY_NAME' in '$NAMESPACE'…"
  local tf; tf="$(mktemp)"; cat > "$tf" <<'HCL'
path "cubbyhole/*" { capabilities = ["read","list"] }
HCL
  vns policy write "$POLICY_NAME" "$tf" >/dev/null
  say_ok "Policy ready: $POLICY_NAME"
}

ensure_user() {
  say_info "Creating user '$USERNAME' with policy '$POLICY_NAME'…"
  say_curl POST "auth/$USERPASS_PATH/users/$USERNAME" "{\"password\":\"$PASSWORD\",\"policies\":\"$POLICY_NAME\"}"
  vns write "auth/$USERPASS_PATH/users/$USERNAME" password="$PASSWORD" policies="$POLICY_NAME" >/dev/null || true
  say_ok "User ready: $USERNAME"
}

ensure_entity_and_alias() {
  say_info "Ensuring identity entity + alias…"
  local eid=""; eid="$(vns read -format=json "identity/entity/name/$USERNAME" 2>/dev/null | jq -r '.data.id // empty' || true)"
  if [[ -z "$eid" ]]; then
    eid="$(vns write -format=json identity/entity name="$USERNAME" metadata=username="$USERNAME" | jq -r '.data.id')"
  fi
  say_ok "Entity id: $eid"
  local up_accessor; up_accessor="$(current_userpass_accessor || echo "")"
  if [[ -n "$up_accessor" && "$up_accessor" != "null" ]]; then
    vns write identity/entity-alias name="$USERNAME" canonical_id="$eid" mount_accessor="$up_accessor" >/dev/null || true
    say_ok "Entity alias linked."
  else
    say_warn "Could not resolve userpass accessor; alias link skipped."
  fi
  ENTITY_ID="$eid"
}

configure_mfa_identity() {
  say_info "Configuring Identity TOTP method …"
  METHOD_ID="$(vns write -field=method_id identity/mfa/method/totp issuer="$ISSUER" algorithm="$ALG" digits="$DIGITS" period="$PERIOD")" || true
  if [[ -z "${METHOD_ID:-}" || "$METHOD_ID" == "null" ]]; then
    # Fallback: resolve from an existing enforcement if present
    METHOD_ID="$(vns read -format=json "identity/mfa/login-enforcement/$MFA_ENF_NAME" 2>/dev/null | jq -r '.data.mfa_method_ids[0] // empty')"
  fi
  [[ -n "$METHOD_ID" ]] || { err "Could not resolve MFA method_id"; exit 1; }
  echo "  ↳ method_id: $METHOD_ID"
}

enforce_mfa_on_userpass() {
  local acc; acc="$(current_userpass_accessor || echo "")"
  [[ -n "$acc" && "$acc" != "null" ]] || { err "Cannot enforce on auth mount: accessor not found."; exit 1; }

  say_info "Creating login enforcement '$MFA_ENF_NAME' on userpass accessor …"
  vns write "identity/mfa/login-enforcement/$MFA_ENF_NAME" \
    mfa_method_ids="$METHOD_ID" \
    auth_method_accessors="$acc" >/dev/null
  say_ok "Enforcement active."
}

admin_generate_seed_and_mirror() {
  say_info "Admin-generating TOTP seed for entity …"
  local j; j="$(vns write -format=json identity/mfa/method/totp/admin-generate method_id="$METHOD_ID" entity_id="$ENTITY_ID" || true)"
  ADMIN_JSON="$j"

  local uri; uri="$(jq -r '.data.url // .data.provisioning_uri // empty' <<<"$j")"
  if [[ -z "$uri" || "$uri" == "null" ]]; then
    say_warn "Entity already has a secret for this MFA method (no URI returned)."
  else
    TOTP_SECRET="$(get_qp "$uri" secret)"
    [[ -n "$TOTP_SECRET" && "$TOTP_SECRET" != "null" ]] || { err "Could not extract base32 secret from URI"; exit 1; }
    echo "  ↳ (seed extracted) SECRET=<hidden>"
  fi

  if $SHOW_QR; then
    local b64; b64="$(jq -r '.data.barcode // empty' <<<"$j")"
    if [[ -n "$b64" && "$b64" != "null" ]]; then
      local out="qr_${USERNAME}.png"
      (echo "$b64" | base64 -D > "$out" 2>/dev/null) || (echo "$b64" | base64 -d > "$out")
      say_ok "Saved QR to ./$out"
    fi
  fi

  say_info "Ensuring 'totp/' engine and mirroring (if seed available) …"
  vns secrets enable -path=totp totp >/dev/null 2>&1 || true
  local key_name; key_name="$(echo "$USERNAME" | tr '[:upper:]' '[:lower:]')"
  if [[ -n "${TOTP_SECRET:-}" ]]; then
    vns write "totp/keys/$key_name" issuer="$ISSUER" account_name="$USERNAME" \
      key="$TOTP_SECRET" algorithm="$ALG" digits="$DIGITS" period="$PERIOD" >/dev/null
  else
    say_warn "No seed available to mirror. Expecting an existing totp/keys/$key_name."
  fi
  KEY_NAME="$key_name"
}

mint_code_and_login() {
  say_info "Generating a fresh TOTP code …"
  CODE="$(vns read -field=code "totp/code/$KEY_NAME" 2>/dev/null || true)"
  [[ -n "$CODE" ]] || { err "No code available from totp/; mirror seed or use fresh user."; exit 1; }
  echo "  ↳ code: $CODE"

  say_info "Logging in with MFA (curl) …"
  local login_json
  login_json="$(command curl -sS -X POST \
      -H "X-Vault-Namespace: $NAMESPACE" \
      -H "Content-Type: application/json" \
      -H "X-Vault-MFA: ${METHOD_ID}:${CODE}" \
      -d '{"password":"'"$PASSWORD"'"}' \
      "$VAULT_ADDR/v1/auth/$USERPASS_PATH/login/$USERNAME")"

  local token; token="$(echo "$login_json" | jq -r '.auth.client_token // empty')"
  if [[ -z "$token" ]]; then
    echo "$login_json" | jq . >&2
    err "Login failed (see response above)."
    exit 1
  fi
  LOGIN_TOKEN="$token"
  say_ok "Login succeeded. Token acquired."
}

verify_token_identity() {
  say_info "Verifying token identity fields …"
  VAULT_NAMESPACE="$NAMESPACE" VAULT_TOKEN="$LOGIN_TOKEN" vault token lookup -format=json \
    | jq '.data | {display_name, entity_id, meta, policies}'
  say_ok "MFA login test completed for user '$USERNAME' in namespace '$NAMESPACE'."
}

revoke_and_confirm() {
  $REVOKE_TOKEN || return 0
  say_info "Revoking issued token to validate lifecycle …"
  # Use admin token to revoke the just-issued user token:
  VAULT_NAMESPACE="$NAMESPACE" VAULT_TOKEN="$VAULT_TOKEN" vault token revoke "$LOGIN_TOKEN" >/dev/null 2>&1 || true
  say_ok "Token revoked."

  say_info "Confirming token is invalid (lookup should fail) …"
  if VAULT_NAMESPACE="$NAMESPACE" VAULT_TOKEN="$LOGIN_TOKEN" vault token lookup >/dev/null 2>&1; then
    say_warn "Token lookup still succeeded; revocation may not have propagated yet."
    return 1
  else
    say_ok "Revocation confirmed — token no longer valid."
  fi
}

print_accessor_hint() {
  local acc; acc="$(current_userpass_accessor || true)"
  local eid; eid="$(vns read -format=json "identity/entity/name/$USERNAME" 2>/dev/null | jq -r '.data.id // empty')"
  echo
  say_info "Targets for MFA enforcement (UI):"
  [[ -n "$acc" && "$acc" != "null" ]] && echo "  • Auth mount accessor: $acc"
  [[ -n "$eid" && "$eid" != "null" ]] && echo "  • Entity: $eid (name=$USERNAME)"
  echo "UI: Access → Multi-Factor Authentication → (TOTP) → Enforcements → Create"
  echo
}

cleanup() {
  say_info "🧽 Cleanup in namespace '$NAMESPACE'…"
  # Remove enforcements (best-effort)
  vns delete "identity/mfa/enforcement/${MFA_ENF_NAME}" >/dev/null 2>&1 || true
  vns delete "identity/mfa/login-enforcement/${MFA_ENF_NAME}" >/dev/null 2>&1 || true
  # Delete MFA method (Identity)
  vns delete "identity/mfa/method/totp" >/dev/null 2>&1 || true
  # Delete entity by name
  local eid; eid="$(vns read -format=json "identity/entity/name/$USERNAME" 2>/dev/null | jq -r '.data.id // empty' || true)"
  [[ -n "$eid" ]] && vns delete "identity/entity/id/$eid" >/dev/null 2>&1 || true
  # Disable userpass
  if vns auth list -format=json | jq -e 'has("'"$USERPASS_PATH"'/")' >/dev/null 2>&1; then
    vns auth disable "$USERPASS_PATH" >/dev/null 2>&1 || true
  fi
  say_ok "Cleanup complete."
}

main() {
  $QUIET || say_info "Using VAULT_ADDR=$VAULT_ADDR  namespace=$NAMESPACE  user=$USERNAME"

  if [[ -n "$CLEAN_USER" ]]; then clean_user "$CLEAN_USER"; exit 0; fi
  if $FRESH; then cleanup; $QUIET || echo; fi
  if $CLEAN_ONLY; then cleanup; exit 0; fi

  # Ensure namespace
  if ns_exists; then say_info "Namespace '$NAMESPACE' exists."
  else
    say_info "Creating namespace '$NAMESPACE'…"
    say_curl POST "sys/namespaces/$NAMESPACE" '{}'
    vroot namespace create "$NAMESPACE" >/dev/null
    say_ok "Namespace ready: $NAMESPACE"
  fi

  enable_userpass_if_needed
  write_policy
  ensure_user
  ensure_entity_and_alias
  [[ "$PRINT_ONLY" == true ]] && exit 0

  configure_mfa_identity

  if $ENFORCE_ENTITY; then
    say_warn "Entity-based enforcement not used in this run (accessor-based shown)."
  fi
  enforce_mfa_on_userpass

  # Optional verification (pre-login): keep your existing probe if desired
  if $VERIFY_ONLY; then
    say_info "Verify-only mode: showing accessor/enforcement hints."
    print_accessor_hint
    exit 0
  fi

  admin_generate_seed_and_mirror
  mint_code_and_login
  verify_token_identity
  revoke_and_confirm

  $JSON_OUT && jq -n --arg namespace "$NAMESPACE" \
        --arg username "$USERNAME" \
        --arg userpass_path "$USERPASS_PATH" \
        --arg policy "$POLICY_NAME" \
        --arg mfa_enforcement "$MFA_ENF_NAME" \
        --arg issuer "$ISSUER" \
        --arg method_id "$METHOD_ID" \
        --arg entity_id "$ENTITY_ID" \
        --arg key_name "$KEY_NAME" \
        '{namespace:$namespace, username:$username, userpass_path:$userpass_path, policy:$policy,
          mfa:{enforcement:$mfa_enforcement, issuer:$issuer, method_id:$method_id},
          entity_id:$entity_id, totp_key:$key_name }'
}

main
# ========== End of Script ==========