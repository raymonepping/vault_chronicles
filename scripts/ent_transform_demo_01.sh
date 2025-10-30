#!/usr/bin/env bash
set -euo pipefail

# ===========================================
# ent_transform_demo_01.sh
# - Transit encrypt/decrypt (OSS-style)
# - Transform (Enterprise/HCP): masking (default) or FPE (--mode fpe)
# - Idempotent, --fresh, --json, --no-transit, --namespace, --show-curl
# - .env auto-load (next to script)
# ===========================================

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

# ---- Config (override via env or flags) ----
TRANSIT_PATH="${TRANSIT_PATH:-transit}"
TRANSIT_KEY="${TRANSIT_KEY:-demo-transit-key}"
TRANSIT_DELETION_ALLOWED="${TRANSIT_DELETION_ALLOWED:-true}"

TRANSFORM_PATH="${TRANSFORM_PATH:-transform}"
TRANSFORM_ROLE_NAME="${TRANSFORM_ROLE_NAME:-payments}"
# Distinct names per mode to avoid collisions
TRANSFORM_MASK_NAME="${TRANSFORM_MASK_NAME:-ccn-mask}"
TRANSFORM_FPE_NAME="${TRANSFORM_FPE_NAME:-ccn-fpe}"
TRANSFORM_MODE="${TRANSFORM_MODE:-masking}"   # masking | fpe

# Demo values
PLAINTEXT="${PLAINTEXT:-In my Mind my Dreams are Real.}"
CREDIT_CARD_NUMBER="${CREDIT_CARD_NUMBER:-1111-2222-3333-4444}"

# Runtime data for JSON output
CIPHERTEXT=""
DECRYPTED=""
MASKED=""
FPE_ENCODED=""
FPE_DECODED=""

# Flags
QUIET=false
REDACT_TOKEN=false
CLEAN_ONLY=false
FRESH=false
JSON_OUT=false
SHOW_CURL=false
NO_TRANSIT=false
NAMESPACE_ARG=""

# ---- UI helpers ----
ok() {
  # Always show in normal mode.
  if ! "$QUIET"; then
    echo "✅ $*"
    return
  fi
  # In --quiet, only show key result lines:
  case "$*" in
    Ciphertext:*|Decrypted\ plaintext:*|Masked\ value:*|FPE\ encoded:*|FPE\ decoded:*|All\ done!*|Enterprise\ Transform\ demo\ complete.*)
      echo "✅ $*"
      ;;
    *)
      # suppress non-essential ok lines in quiet mode
      :
      ;;
  esac
}

info() {
  if ! "$QUIET"; then
    echo "🧭  $*"
  fi
}

warn() { echo "${warning} $*"; }
err()  { echo "❌ $*" >&2; }

need() { command -v "$1" >/dev/null 2>&1 || { err "Missing dependency: $1"; exit 1; }; }

usage() {
  cat <<EOF
Usage: $(basename "$0")
  [--clean] [--fresh] [--json] [--show-curl] [--no-transit]
  [--namespace NAME]
  [--mode masking|fpe]
  [--value "PLAINTEXT"] [--cc "1111-2222-3333-4444"]
  [--transit-path PATH] [--transform-path PATH]

Options:
  --clean                 Remove demo artifacts (transit key, transform role + transformations). Leaves engines mounted.
  --fresh                 Cleanup first, then run the full demo.
  --json                  Print machine-readable JSON summary at the end.
  --show-curl             Echo the equivalent HTTP calls for each step (for slides).
  --no-transit            Skip the Transit section (Transform-only quick demo).
  --namespace NAME        Convenience flag; sets VAULT_NAMESPACE=NAME for this run.
  --mode masking|fpe      Transform mode to demo (default: masking).
  --value "PLAINTEXT"     Plaintext for Transit (default: "$PLAINTEXT").
  --cc "1111-2222-3333-4444"
                          CC-like input for Transform (default: "$CREDIT_CARD_NUMBER").
  --transit-path PATH     Transit mount (default: $TRANSIT_PATH).
  --transform-path PATH   Transform mount (default: $TRANSFORM_PATH).
  -h, --help              Show this help.

Environment:
  .env next to this script is auto-loaded (VAULT_ADDR, VAULT_TOKEN, optional VAULT_NAMESPACE).
  Flags take precedence over .env where applicable (e.g., --namespace).
EOF
}

# ---- Parse args ----
while [[ $# -gt 0 ]]; do
  case "$1" in
    --clean) CLEAN_ONLY=true; shift ;;
    --fresh) FRESH=true; shift ;;
    --quiet) QUIET=true; shift ;;
    --json) JSON_OUT=true; shift ;;
    --show-curl) SHOW_CURL=true; shift ;;
    --redact-token) REDACT_TOKEN=true; shift ;;
    --no-transit) NO_TRANSIT=true; shift ;;
    --namespace) NAMESPACE_ARG="$2"; shift 2 ;;
    --mode) TRANSFORM_MODE="$2"; shift 2 ;;
    --value) PLAINTEXT="$2"; shift 2 ;;
    --cc) CREDIT_CARD_NUMBER="$2"; shift 2 ;;
    --transit-path) TRANSIT_PATH="$2"; shift 2 ;;
    --transform-path) TRANSFORM_PATH="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) err "Unknown argument: $1"; usage; exit 1 ;;
  esac
done

# ---- Load .env (from script directory) ----
SCRIPT_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
if [[ -f "$SCRIPT_DIR/.env" ]]; then
  info "Loading environment from $SCRIPT_DIR/.env"
  set -a
  # shellcheck disable=SC1090
  source "$SCRIPT_DIR/.env"
  set +a
fi

# Apply --namespace if provided
if [[ -n "$NAMESPACE_ARG" ]]; then
  export VAULT_NAMESPACE="$NAMESPACE_ARG"
fi

# ---- Preflight ----
need vault
need jq
need base64

[[ -n "${VAULT_ADDR:-}" ]]  || { err "VAULT_ADDR not set (set in .env or env, or export before run)"; exit 1; }
[[ -n "${VAULT_TOKEN:-}" ]] || { err "VAULT_TOKEN not set (set in .env or env, or export before run)"; exit 1; }

# ---- Helpers ----
selected_transformation_name() {
  case "$TRANSFORM_MODE" in
    masking) echo "$TRANSFORM_MASK_NAME" ;;
    fpe)     echo "$TRANSFORM_FPE_NAME" ;;
    *)       err "Unknown --mode '$TRANSFORM_MODE' (use 'masking' or 'fpe')" ;;
  esac
}

# Pretty curl echo (does not execute; for slides)
echo_curl() {
  if "$SHOW_CURL"; then
    local method="$1"; local path="$2"; local data="${3:-}"
    local nsHeader=""
    if [[ -n "${VAULT_NAMESPACE:-}" ]]; then
      nsHeader='-H "X-Vault-Namespace: '"$VAULT_NAMESPACE"'" '
    fi
    # redact token if requested (echo only; actual calls still use command curl)
    local tokenHeader='-H "X-Vault-Token: $VAULT_TOKEN" '
    if "$REDACT_TOKEN"; then
      tokenHeader='-H "X-Vault-Token: ********" '
    fi
    local pretty="curl -X $method \"${VAULT_ADDR}/v1/${path}\" ${tokenHeader}${nsHeader}-H \"Content-Type: application/json\""
    if [[ -n "$data" ]]; then
      pretty+=" -d '$data'"
    fi
    echo " ${arrow} ${pretty}"
  fi
}

secrets_enabled() {
  local path="$1/"
  vault secrets list -format=json | jq -e --arg p "$path" 'has($p)' >/dev/null
}

enable_engine_if_needed() {
  local path="$1" type="$2"
  if secrets_enabled "$path"; then
    info "Secrets engine '$type' already enabled at '$path/'."
  else
    info "Enabling '$type' at '$path/'…"
    # curl equivalent for slides
    if "$SHOW_CURL"; then
      echo_curl POST "sys/mounts/${path}" "{\"type\":\"${type}\"}"
    fi
    vault secrets enable -path="$path" "$type" >/dev/null
    ok   "Enabled '$type' at '$path/'."
  fi
}

upsert_transit_key() {
  if vault list -format=json "${TRANSIT_PATH}/keys" 2>/dev/null | jq -er --arg k "$TRANSIT_KEY" '.[] | select(.==$k)' >/dev/null; then
    info "Transit key '$TRANSIT_KEY' exists."
  else
    info "Creating transit key '$TRANSIT_KEY'…"
    echo_curl POST "${TRANSIT_PATH}/keys/${TRANSIT_KEY}" '{}'   # create key
    vault write -f "${TRANSIT_PATH}/keys/${TRANSIT_KEY}" >/dev/null
  fi
  info "Ensuring deletion_allowed=${TRANSIT_DELETION_ALLOWED} on '${TRANSIT_KEY}'…"
  echo_curl POST "${TRANSIT_PATH}/keys/${TRANSIT_KEY}/config" "{\"deletion_allowed\": ${TRANSIT_DELETION_ALLOWED}}"
  vault write "${TRANSIT_PATH}/keys/${TRANSIT_KEY}/config" deletion_allowed="${TRANSIT_DELETION_ALLOWED}" >/dev/null || true
  ok "Transit key ready: ${TRANSIT_KEY}"
}

do_transit_encrypt_decrypt() {
  info "${lock} Encrypting via Transit (OSS-style)…"
  local pt_b64
  pt_b64="$(printf %s "$PLAINTEXT" | base64)"
  echo_curl POST "${TRANSIT_PATH}/encrypt/${TRANSIT_KEY}" "{\"plaintext\":\"${pt_b64}\"}"
  CIPHERTEXT="$(vault write -format=json "${TRANSIT_PATH}/encrypt/${TRANSIT_KEY}" plaintext="$pt_b64" | jq -r '.data.ciphertext')"
  ok "Ciphertext: $CIPHERTEXT"

  info "Decrypting via Transit…"
  echo_curl POST "${TRANSIT_PATH}/decrypt/${TRANSIT_KEY}" "{\"ciphertext\":\"${CIPHERTEXT}\"}"
  local pt_back_b64
  pt_back_b64="$(vault write -format=json "${TRANSIT_PATH}/decrypt/${TRANSIT_KEY}" ciphertext="$CIPHERTEXT" | jq -r '.data.plaintext')"
  DECRYPTED="$(printf %s "$pt_back_b64" | base64 --decode)"
  ok "Decrypted plaintext: $DECRYPTED"
}

setup_transform_objects() {
  enable_engine_if_needed "$TRANSFORM_PATH" "transform"

  local TNAME; TNAME="$(selected_transformation_name)"

  info "Upserting Transform role '${TRANSFORM_ROLE_NAME}'…"
  echo_curl POST "${TRANSFORM_PATH}/role/${TRANSFORM_ROLE_NAME}" "{\"transformations\":\"${TNAME}\"}"
  vault write "${TRANSFORM_PATH}/role/${TRANSFORM_ROLE_NAME}" transformations="${TNAME}" >/dev/null || true

  case "$TRANSFORM_MODE" in
    masking)
      info "Upserting masking transformation '${TNAME}'…"
      echo_curl POST "${TRANSFORM_PATH}/transformations/masking/${TNAME}" \
        "{\"template\":\"builtin/creditcardnumber\",\"masking_character\":\"*\",\"allowed_roles\":\"${TRANSFORM_ROLE_NAME}\"}"
      vault write "${TRANSFORM_PATH}/transformations/masking/${TNAME}" \
        template="builtin/creditcardnumber" \
        masking_character="*" \
        allowed_roles="${TRANSFORM_ROLE_NAME}" >/dev/null || true
      ;;
    fpe)
      info "Upserting FPE transformation '${TNAME}' (FF3-1, tweak_source=internal)…"
      echo_curl POST "${TRANSFORM_PATH}/transformations/fpe/${TNAME}" \
        "{\"template\":\"builtin/creditcardnumber\",\"alphabet\":\"builtin/numeric\",\"tweak_source\":\"internal\",\"allowed_roles\":\"${TRANSFORM_ROLE_NAME}\"}"
      vault write "${TRANSFORM_PATH}/transformations/fpe/${TNAME}" \
        template="builtin/creditcardnumber" \
        alphabet="builtin/numeric" \
        tweak_source="internal" \
        allowed_roles="${TRANSFORM_ROLE_NAME}" >/dev/null || true
      ;;
  esac

  # Ensure the role points to our transformation (repeat-safe)
  echo_curl POST "${TRANSFORM_PATH}/role/${TRANSFORM_ROLE_NAME}" "{\"transformations\":\"${TNAME}\"}"
  vault write "${TRANSFORM_PATH}/role/${TRANSFORM_ROLE_NAME}" transformations="${TNAME}" >/dev/null || true

  ok "Transform role + transformation ready."
}

do_transform_run() {
  local TNAME; TNAME="$(selected_transformation_name)"
  case "$TRANSFORM_MODE" in
    masking)
      info "Encoding via role '${TRANSFORM_ROLE_NAME}' (masking; non-reversible)…"
      echo_curl POST "${TRANSFORM_PATH}/encode/${TRANSFORM_ROLE_NAME}" "{\"value\":\"${CREDIT_CARD_NUMBER}\"}"
      MASKED="$(vault write -format=json "${TRANSFORM_PATH}/encode/${TRANSFORM_ROLE_NAME}" value="$CREDIT_CARD_NUMBER" | jq -r '.data.encoded_value')"
      ok "Masked value: $MASKED"
      ;;
    fpe)
      info "Encoding via role '${TRANSFORM_ROLE_NAME}' (FPE using '${TNAME}')…"
      echo_curl POST "${TRANSFORM_PATH}/encode/${TRANSFORM_ROLE_NAME}" "{\"value\":\"${CREDIT_CARD_NUMBER}\"}"
      FPE_ENCODED="$(vault write -format=json "${TRANSFORM_PATH}/encode/${TRANSFORM_ROLE_NAME}" value="$CREDIT_CARD_NUMBER" | jq -r '.data.encoded_value')"
      ok "FPE encoded: $FPE_ENCODED"

      info "Decoding via role '${TRANSFORM_ROLE_NAME}' (FPE)…"
      echo_curl POST "${TRANSFORM_PATH}/decode/${TRANSFORM_ROLE_NAME}" "{\"value\":\"${FPE_ENCODED}\"}"
      FPE_DECODED="$(vault write -format=json "${TRANSFORM_PATH}/decode/${TRANSFORM_ROLE_NAME}" value="$FPE_ENCODED" | jq -r '.data.decoded_value')"
      ok "FPE decoded: $FPE_DECODED"
      ;;
  esac
}

cleanup() {
  info "🧽 Cleanup: removing demo artifacts…"

  # Transit key
  if secrets_enabled "$TRANSIT_PATH"; then
    if vault list -format=json "${TRANSIT_PATH}/keys" 2>/dev/null | jq -er --arg k "$TRANSIT_KEY" '.[] | select(.==$k)' >/dev/null; then
      info "Deleting transit key '${TRANSIT_KEY}'…"
      echo_curl DELETE "${TRANSIT_PATH}/keys/${TRANSIT_KEY}"
      if vault delete "${TRANSIT_PATH}/keys/${TRANSIT_KEY}" >/dev/null 2>&1; then
        ok "Deleted transit key '${TRANSIT_KEY}'."
      else
        warn "Could not delete transit key '${TRANSIT_KEY}'. (Check deletion_allowed or permissions.)"
      fi
    fi
  fi

  # Transform role + BOTH transformations (safe to delete if present)
  if secrets_enabled "$TRANSFORM_PATH"; then
    info "Deleting transform role '${TRANSFORM_ROLE_NAME}' (if exists)…"
    echo_curl DELETE "${TRANSFORM_PATH}/role/${TRANSFORM_ROLE_NAME}"
    vault delete "${TRANSFORM_PATH}/role/${TRANSFORM_ROLE_NAME}" >/dev/null 2>&1 || true

    info "Deleting masking transformation '${TRANSFORM_MASK_NAME}' (if exists)…"
    echo_curl DELETE "${TRANSFORM_PATH}/transformations/masking/${TRANSFORM_MASK_NAME}"
    vault delete "${TRANSFORM_PATH}/transformations/masking/${TRANSFORM_MASK_NAME}" >/dev/null 2>&1 || true

    info "Deleting FPE transformation '${TRANSFORM_FPE_NAME}' (if exists)…"
    echo_curl DELETE "${TRANSFORM_PATH}/transformations/fpe/${TRANSFORM_FPE_NAME}"
    vault delete "${TRANSFORM_PATH}/transformations/fpe/${TRANSFORM_FPE_NAME}" >/dev/null 2>&1 || true

    ok "Transform artifacts removed."
  fi

  ok "Cleanup complete."
}

run_demo() {
  local TNAME; TNAME="$(selected_transformation_name)"

  info "${lock} DEMO: Transit (encrypt/decrypt) + Transform (${TRANSFORM_MODE})"
  info "VAULT_ADDR=${VAULT_ADDR}${VAULT_NAMESPACE:+  |  VAULT_NAMESPACE=$VAULT_NAMESPACE}"
  info "Transit path: ${TRANSIT_PATH}/, key: ${TRANSIT_KEY}"
  info "Transform path: ${TRANSFORM_PATH}/, role: ${TRANSFORM_ROLE_NAME}, transformation: ${TNAME}, mode: ${TRANSFORM_MODE}"

  # Transit (optional)
  if ! "$NO_TRANSIT"; then
    enable_engine_if_needed "$TRANSIT_PATH" "transit"
    upsert_transit_key
    do_transit_encrypt_decrypt
  else
    info "Skipping Transit section (--no-transit)."
  fi

  # Transform (Enterprise/HCP only)
  local TRANSFORM_OK=true
  if secrets_enabled "$TRANSFORM_PATH"; then
    info "Transform engine already enabled at '${TRANSFORM_PATH}/'."
  else
    info "Attempting to enable Transform (Enterprise feature)…"
    echo_curl POST "sys/mounts/${TRANSFORM_PATH}" "{\"type\":\"transform\"}"
    if vault secrets enable -path="$TRANSFORM_PATH" transform >/dev/null 2>&1; then
      ok "Enabled Transform at '${TRANSFORM_PATH}/'."
    else
      TRANSFORM_OK=false
      warn "Transform engine not available (likely OSS or insufficient perms). Skipping transform demo."
    fi
  fi

  if $TRANSFORM_OK; then
    setup_transform_objects
    do_transform_run
    ok "Enterprise Transform demo complete."
  else
    warn "Transform step skipped."
  fi

  ok "All done! Use '--clean' to remove demo artifacts."
}

emit_json_summary() {
  jq -n \
    --arg plaintext "$PLAINTEXT" \
    --arg ciphertext "$CIPHERTEXT" \
    --arg decrypted "$DECRYPTED" \
    --arg cc "$CREDIT_CARD_NUMBER" \
    --arg masked "${MASKED:-""}" \
    --arg fpe_encoded "${FPE_ENCODED:-""}" \
    --arg fpe_decoded "${FPE_DECODED:-""}" \
    --arg mode "$TRANSFORM_MODE" \
    '{
      plaintext: $plaintext,
      ciphertext: $ciphertext,
      decrypted: $decrypted,
      credit_card_input: $cc,
      mode: $mode,
      masked_output: (if $mode == "masking" then $masked else null end),
      fpe_encoded: (if $mode == "fpe" then $fpe_encoded else null end),
      fpe_decoded: (if $mode == "fpe" then $fpe_decoded else null end)
    }
    | with_entries(select(.value != null))
    | with_entries(select(.value != ""))'
}

# ---- Execute ----
if "$CLEAN_ONLY"; then
  cleanup
  exit 0
fi

if "$FRESH"; then
  cleanup
  echo
fi

run_demo

if "$JSON_OUT"; then
  echo
  emit_json_summary
fi

# ---- End of script ----
