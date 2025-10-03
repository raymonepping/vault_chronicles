#!/usr/bin/env bash
set -euo pipefail

# ================================
# Config (override via env)
# ================================
# Cluster nodes (Vault API ports exposed on localhost)
PORTS=(${PORTS:-18200 18210 18220})

# Where to read init output
INIT_OUT_PATH="${INIT_OUT_PATH:-ops/INIT.out}"

# Bootstrap options (set ONLY_UNSEAL=true to only unseal nodes)
ONLY_UNSEAL="${ONLY_UNSEAL:-false}"

# Mount paths / names
KV_MOUNT_PATH="${KV_MOUNT_PATH:-kv}"                 # kv-v2
TRANSIT_MOUNT_PATH="${TRANSIT_MOUNT_PATH:-transit}"
DB_MOUNT_PATH="${DB_MOUNT_PATH:-database}"
TRANSIT_KEY_NAME="${TRANSIT_KEY_NAME:-couchbase_key}"

# Audit (must be a writable, mounted path in the container per your HCL)
AUDIT_PATH="file/"
AUDIT_FILE="/vault/logs/vault_audit.log"

# ================================
# Pretty printing
# ================================
print() {
  local level="$1"; shift
  case "$level" in
    INFO)    printf "\033[1;34m[INFO]\033[0m %s\n" "$*" ;;
    SUCCESS) printf "\033[1;32m[SUCCESS]\033[0m %s\n" "$*" ;;
    WARN)    printf "\033[1;33m[WARN]\033[0m %s\n" "$*" ;;
    ERROR)   printf "\033[1;31m[ERROR]\033[0m %s\n" "$*" ;;
    *)       printf "[%s] %s\n" "$level" "$*" ;;
  esac
}

# ================================
# Helpers
# ================================
need_file() { [[ -f "$1" ]] || { print ERROR "Missing file: $1"; exit 1; }; }

v() { VAULT_ADDR="$1" VAULT_TOKEN="${2:-}" vault "$3" "${@:4}"; }
v_json() { VAULT_ADDR="$1" VAULT_TOKEN="${2:-}" vault "$3" -format=json "${@:4}"; }

# Read all unseal keys + root token from INIT.out if not provided
UNSEAL_KEYS=()
ROOT_TOKEN="${VAULT_TOKEN:-}"

if [[ -z "${ROOT_TOKEN}" || -z "${UNSEAL_KEYS[*]:-}" ]]; then
  need_file "$INIT_OUT_PATH"
  print INFO "Reading unseal keys & root token from $INIT_OUT_PATH"
  mapfile -t UNSEAL_KEYS < <(grep -E 'Unseal Key [0-9]+:' "$INIT_OUT_PATH" | awk -F': ' '{print $2}')
  ROOT_TOKEN="${ROOT_TOKEN:-$(grep -E 'Initial Root Token:' "$INIT_OUT_PATH" | awk -F': ' '{print $2}')}"
fi
[[ ${#UNSEAL_KEYS[@]} -gt 0 ]] || { print ERROR "No unseal keys found."; exit 1; }
[[ -n "$ROOT_TOKEN" ]] || { print ERROR "No root token found."; exit 1; }

translate_to_host() {
  # Translate container URL (vault-1:8200) -> host URL (127.0.0.1:18200)
  local url="$1"
  case "$url" in
    http://vault-1:8200|https://vault-1:8201)
      echo "http://127.0.0.1:18200";;
    http://vault-2:8200|https://vault-2:8201)
      echo "http://127.0.0.1:18210";;
    http://vault-3:8200|https://vault-3:8201)
      echo "http://127.0.0.1:18220";;
    *)
      # If the leader already looks like a host URL, keep it
      echo "$url";;
  esac
}

# ================================
# Unseal all nodes (idempotent)
# ================================
unseal_node() {
  local addr="$1"
  print INFO "Unsealing $addr ..."
  # Try keys until unsealed
  for key in "${UNSEAL_KEYS[@]}"; do
    if VAULT_ADDR="$addr" vault operator unseal "$key" >/dev/null 2>&1; then :; fi
    local sealed
    sealed="$(VAULT_ADDR="$addr" vault status -format=json | jq -r '.sealed' || echo true)"
    if [[ "$sealed" == "false" ]]; then
      print SUCCESS "$addr is unsealed."
      return 0
    fi
  done
  print ERROR "$addr still sealed after applying keys."
  return 1
}

# ================================
# Detect leader
# ================================
get_leader_addr() {
  # query each node until one answers with leader info
  for port in "${PORTS[@]}"; do
    local addr="http://127.0.0.1:${port}"
    if out="$(curl -sf "$addr/v1/sys/leader" 2>/dev/null)"; then
      local leader
      leader="$(jq -r '.leader_address' <<<"$out" 2>/dev/null || true)"
      if [[ -n "$leader" && "$leader" != "null" ]]; then
        # translate container DNS URL -> host-mapped URL
        translate_to_host "$leader"
        return 0
      fi
    fi
  done
  return 1
}

# ================================
# Bootstrap mounts/audit (leader only)
# ================================
bootstrap_on_leader() {
  local leader_addr="$1"
  local token="$2"

  print INFO "Logging into leader ($leader_addr)"
  if ! VAULT_ADDR="$leader_addr" VAULT_TOKEN="$token" vault token lookup >/dev/null 2>&1; then
    print ERROR "Root token failed on leader."
    exit 1
  fi
  print SUCCESS "Authenticated on leader."

  print INFO "Ensuring secrets engines exist (idempotent)..."
  local mounts_json
  mounts_json="$(v_json "$leader_addr" "$token" secrets list || echo '{}')"

  # KV v2
  if jq -e --arg p "${KV_MOUNT_PATH}/" 'has($p)' <<<"$mounts_json" >/dev/null; then
    print SUCCESS "KV already mounted at '${KV_MOUNT_PATH}/'."
  else
    v "$leader_addr" "$token" secrets enable -version=2 -path="${KV_MOUNT_PATH}" kv >/dev/null
    print SUCCESS "Enabled KV v2 at '${KV_MOUNT_PATH}/'."
  fi

  # Transit
  if jq -e --arg p "${TRANSIT_MOUNT_PATH}/" 'has($p)' <<<"$mounts_json" >/dev/null; then
    print SUCCESS "Transit already mounted at '${TRANSIT_MOUNT_PATH}/'."
  else
    v "$leader_addr" "$token" secrets enable -path="${TRANSIT_MOUNT_PATH}" transit >/dev/null
    print SUCCESS "Enabled Transit at '${TRANSIT_MOUNT_PATH}/'."
  fi

  # Database
  if jq -e --arg p "${DB_MOUNT_PATH}/" 'has($p)' <<<"$mounts_json" >/dev/null; then
    print SUCCESS "Database already mounted at '${DB_MOUNT_PATH}/'."
  else
    v "$leader_addr" "$token" secrets enable -path="${DB_MOUNT_PATH}" database >/dev/null
    print SUCCESS "Enabled Database at '${DB_MOUNT_PATH}/'."
  fi

  print INFO "Ensuring transit key '${TRANSIT_KEY_NAME}' exists..."
  if v "$leader_addr" "$token" read "${TRANSIT_MOUNT_PATH}/keys/${TRANSIT_KEY_NAME}" >/dev/null 2>&1; then
    print SUCCESS "Transit key already exists."
  else
    v "$leader_addr" "$token" write -f "${TRANSIT_MOUNT_PATH}/keys/${TRANSIT_KEY_NAME}" >/dev/null
    print SUCCESS "Transit key created."
  fi

  print INFO "Ensuring audit --> ${AUDIT_FILE}"
  local audits_json
  audits_json="$(VAULT_ADDR="$leader_addr" VAULT_TOKEN="$token" vault audit list -format=json 2>/dev/null || echo '{}')"
  if jq -e --arg p "$AUDIT_PATH" 'has($p)' <<<"$audits_json" >/dev/null; then
    print SUCCESS "Audit already enabled at '${AUDIT_PATH}'."
  else
    VAULT_ADDR="$leader_addr" VAULT_TOKEN="$token" vault audit enable file file_path="${AUDIT_FILE}" >/dev/null
    print SUCCESS "Audit logging enabled."
  fi
}

# ================================
# Main
# ================================
print INFO "Starting cluster unseal across ports: ${PORTS[*]}"

# 1) Unseal all
for port in "${PORTS[@]}"; do
  unseal_node "http://127.0.0.1:${port}"
done

# 2) Early exit if ONLY_UNSEAL=true
if [[ "$ONLY_UNSEAL" == "true" ]]; then
  print SUCCESS "All nodes unsealed. (ONLY_UNSEAL=true) Skipping bootstrap."
  exit 0
fi

# 3) Find leader and bootstrap once
leader_addr="$(get_leader_addr || true)"
if [[ -z "${leader_addr:-}" ]]; then
  print WARN "Could not resolve leader via /v1/sys/leader just yet. Using first node."
  leader_addr="http://127.0.0.1:${PORTS[0]}"
fi

print INFO "Leader appears to be: ${leader_addr}"
bootstrap_on_leader "$leader_addr" "$ROOT_TOKEN"

print SUCCESS "Cluster unseal & bootstrap complete."
echo
print INFO "Quick verify:"
for port in "${PORTS[@]}"; do
  addr="http://127.0.0.1:${port}"
  VAULT_ADDR="$addr" vault status | awk -v a="$addr" '
    /Sealed|HA Mode|Active Node Address|Performance Standby/ {print a " :: " $0}'
done
