#!/usr/bin/env bash

# ------------------------------------------------------------------------------
# vault_activity_counters.sh — Vault Chronicles Toolkit (MIT)
# Clean wrapper for sys/internal/counters/activity with date shortcuts,
# multiple output modes (json/csv/md), and optional file output.
# ------------------------------------------------------------------------------

set -euo pipefail

VERSION="1.3.0"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"

# --- Colors & icons (stderr only, never in JSON/CSV/MD) -----------------------

RESET=$'\e[0m'
BOLD=$'\e[1m'
RED=$'\e[31m'
GREEN=$'\e[32m'
YELLOW=$'\e[33m'
BLUE=$'\e[34m'

ICON_OK="✅"
ICON_INFO="ℹ️"
ICON_ERR="❌"

log_info() {
  echo "${BLUE}${ICON_INFO} ${*}${RESET}" >&2
}

log_ok() {
  echo "${GREEN}${ICON_OK} ${*}${RESET}" >&2
}

log_err() {
  echo "${RED}${ICON_ERR} ${*}${RESET}" >&2
}

# --- Load .env ----------------------------------------------------------------

if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  set -a
  . "$ENV_FILE"
  set +a
fi

print_help() {
  cat <<EOF
${BOLD}vault_activity_counters.sh v${VERSION}${RESET}

${BLUE}Query Vault sys/internal/counters/activity and extract usage counters.${RESET}

${YELLOW}Required (one of):${RESET}
  ${BOLD}EITHER:${RESET}
    ${GREEN}--start${RESET}   RFC3339 timestamp (UTC) or date-only.
              Examples:
                2025-10-01T00:00:00Z
                2025-10-01    (interpreted as 2025-10-01T00:00:00Z)
    ${GREEN}--end${RESET}     RFC3339 timestamp (UTC) or date-only.
              Examples:
                2025-11-01T00:00:00Z
                2025-11-01    (interpreted as 2025-11-01T00:00:00Z)

  ${BOLD}OR one shortcut (mutually exclusive with --start/--end):${RESET}
    ${GREEN}--last-24h${RESET}        Last 24 hours until now (UTC)
    ${GREEN}--last-7d${RESET}         Last 7 days until now (UTC)
    ${GREEN}--last-14d${RESET}        Last 14 days until now (UTC)
    ${GREEN}--last-30d${RESET}        Last 30 days until now (UTC)
    ${GREEN}--last-month${RESET}      Previous full calendar month (UTC)
    ${GREEN}--last-year${RESET}       Last 12 months (rolling, UTC)
    ${GREEN}--last-days N${RESET}     Last N days (rolling, UTC)
    ${GREEN}--last-months N${RESET}   Last N months (rolling, UTC)

${YELLOW}Optional:${RESET}
  ${GREEN}--mode${RESET}         1|2|3|4|5 or total|non-entity|secret-syncs|summary|env
                 1 / total        -> full .data.total object
                 2 / non-entity   -> .data.total.non_entity_clients
                 3 / secret-syncs -> .data.total.secret_syncs
                 4 / summary      -> { non_entity_clients, secret_syncs }
                 5 / env          -> non_entity_clients=.. and secret_syncs=..
                                      (format flag is ignored in this mode)
  ${GREEN}--format${RESET}       json|csv|md (default: json)
  ${GREEN}--output-file${RESET}  Path to write the result to (in addition to stdout)
  ${GREEN}--help${RESET}         Show this help
  ${GREEN}--version${RESET}      Show version

${YELLOW}Examples:${RESET}
  JSON full total block for explicit range:
    ${BLUE}./vault_activity_counters.sh --start 2025-10-01 --end 2025-11-01 --mode total${RESET}

  CSV summary (non_entity_clients, secret_syncs) for last 7 days:
    ${BLUE}./vault_activity_counters.sh --last-7d --mode summary --format csv --output-file summary.csv${RESET}

  Markdown table, previous full month:
    ${BLUE}./vault_activity_counters.sh --last-month --mode total --format md --output-file activity.md${RESET}
EOF
}

START_TIME=""
END_TIME=""
MODE="summary"      # default to your option 4
FORMAT="json"
RANGE_SHORTCUT=""   # last-24h | last-7d | last-month
OUTPUT_FILE=""

# --- Argument parsing ---------------------------------------------------------

while [[ $# -gt 0 ]]; do
  case "$1" in
    --start)
      START_TIME="${2:-}"
      shift 2
      ;;
    --end)
      END_TIME="${2:-}"
      shift 2
      ;;
    --last-24h|--last-7d|--last-14d|--last-30d|--last-month|--last-year)
      RANGE_SHORTCUT="${1#--}"
      shift 1
      ;;
    --last-days)
      RANGE_SHORTCUT="last-days"
      LAST_DAYS="${2:?Missing value for --last-days}"
      shift 2
      ;;
    --last-months)
      RANGE_SHORTCUT="last-months"
      LAST_MONTHS="${2:?Missing value for --last-months}"
      shift 2
      ;;
    --mode)
      MODE="${2:-}"
      shift 2
      ;;
    --format)
      FORMAT="${2:-}"
      shift 2
      ;;
    --output-file)
      OUTPUT_FILE="${2:-}"
      shift 2
      ;;
    --help|-h)
      print_help
      exit 0
      ;;
    --version)
      echo "vault_activity_counters.sh v${VERSION}"
      exit 0
      ;;
    *)
      log_err "Unknown argument: $1"
      echo "Use --help for usage." >&2
      exit 1
      ;;
  esac
done

# --- Validation ---------------------------------------------------------------

if [[ -n "$RANGE_SHORTCUT" && ( -n "$START_TIME" || -n "$END_TIME" ) ]]; then
  log_err "Shortcut ranges cannot be combined with --start/--end."
  exit 1
fi

if [[ -z "$RANGE_SHORTCUT" && -z "$START_TIME" && -z "$END_TIME" ]]; then
  RANGE_SHORTCUT="last-month"
fi

if [[ -z "$RANGE_SHORTCUT" && ( -z "$START_TIME" || -z "$END_TIME" ) ]]; then
  log_err "Either provide --start/--end or a shortcut range."
  exit 1
fi

case "$FORMAT" in
  json|csv|md) ;;
  *)
    log_err "Invalid format '$FORMAT'."
    exit 1
    ;;
esac

# --- Mode normalization --------------------------------------------------------

normalize_mode() {
  local m="$1"
  case "$m" in
    1|total)          echo "total" ;;
    2|"non-entity")   echo "non-entity" ;;
    3|"secret-syncs") echo "secret-syncs" ;;
    4|summary)        echo "summary" ;;
    5|env)            echo "env" ;;
    *)
      log_err "Invalid --mode '$m'. Use 1..5 or total|non-entity|secret-syncs|summary|env."
      exit 1
      ;;
  esac
}

MODE_NORM="$(normalize_mode "$MODE")"

# --- Date helpers (BSD vs GNU) -----------------------------------------------

is_bsd_date=false
if date -v1d '+%Y-%m-%d' >/dev/null 2>&1; then
  is_bsd_date=true
fi

compute_range_shortcut() {
  local s="$1"
  local start=""
  local end=""

  if $is_bsd_date; then
    case "$s" in
      last-24h)  end="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"; start="$(date -u -v-24H '+%Y-%m-%dT%H:%M:%SZ')" ;;
      last-7d)   end="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"; start="$(date -u -v-7d  '+%Y-%m-%dT%H:%M:%SZ')" ;;
      last-14d)  end="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"; start="$(date -u -v-14d '+%Y-%m-%dT%H:%M:%SZ')" ;;
      last-30d)  end="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"; start="$(date -u -v-30d '+%Y-%m-%dT%H:%M:%SZ')" ;;
      last-month) start="$(date -u -v1d -v-1m '+%Y-%m-%dT00:00:00Z')"; end="$(date -u -v1d '+%Y-%m-%dT00:00:00Z')" ;;
      last-year) end="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"; start="$(date -u -v-1y '+%Y-%m-%dT%H:%M:%SZ')" ;;
      last-days)
        end="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
        start="$(date -u -v-"${LAST_DAYS}"d '+%Y-%m-%dT%H:%M:%SZ')"
        ;;
      last-months)
        end="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
        start="$(date -u -v-"${LAST_MONTHS}"m '+%Y-%m-%dT%H:%M:%SZ')"
        ;;
    esac

  else
    case "$s" in
      last-24h)  end="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"; start="$(date -u -d '24 hours ago' '+%Y-%m-%dT%H:%M:%SZ')" ;;
      last-7d)   end="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"; start="$(date -u -d '7 days ago'  '+%Y-%m-%dT%H:%M:%SZ')" ;;
      last-14d)  end="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"; start="$(date -u -d '14 days ago' '+%Y-%m-%dT%H:%M:%SZ')" ;;
      last-30d)  end="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"; start="$(date -u -d '30 days ago' '+%Y-%m-%dT%H:%M:%SZ')" ;;
      last-month)
        end="$(date -u -d "$(date -u +%Y-%m-01)" '+%Y-%m-%dT00:00:00Z')"
        start="$(date -u -d "$end -1 month" '+%Y-%m-%dT00:00:00Z')"
        ;;
      last-year) end="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"; start="$(date -u -d '1 year ago' '+%Y-%m-%dT%H:%M:%SZ')" ;;
      last-days)
        end="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
        start="$(date -u -d "${LAST_DAYS} days ago" '+%Y-%m-%dT%H:%M:%SZ')"
        ;;
      last-months)
        end="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
        start="$(date -u -d "${LAST_MONTHS} months ago" '+%Y-%m-%dT%H:%M:%SZ')"
        ;;
    esac
  fi

  echo "${start}|${end}"
}

# Allow date-only input and convert to RFC3339 UTC at midnight
normalize_timestamp() {
  local ts="$1"
  [[ "$ts" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] && echo "${ts}T00:00:00Z" || echo "$ts"
}

if [[ -n "$RANGE_SHORTCUT" ]]; then
  IFS="|" read -r START_NORM END_NORM <<<"$(compute_range_shortcut "$RANGE_SHORTCUT")"
else
  START_NORM="$(normalize_timestamp "$START_TIME")"
  END_NORM="$(normalize_timestamp "$END_TIME")"
fi

log_info " Using range: ${BOLD}${START_NORM}${RESET}${BLUE} -> ${BOLD}${END_NORM}${RESET}"

# --- Tool checks & env --------------------------------------------------------

for cmd in vault jq; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    log_err "Required command '$cmd' is not installed or not in PATH."
    exit 1
  fi
done

: "${VAULT_ADDR:?VAULT_ADDR must be set in environment or .env}"
: "${VAULT_TOKEN:?VAULT_TOKEN must be set in environment or .env}"

# --- Vault query --------------------------------------------------------------

VAULT_JSON="$(vault read -format=json sys/internal/counters/activity \
  -start-time="${START_NORM}" \
  -end-time="${END_NORM}")"

# --- Output helpers -----------------------------------------------------------

output_total_json() {
  jq -r '.data.total' <<<"$VAULT_JSON"
}

output_total_csv() {
  jq -r '
    .data.total as $t
    | ($t | keys_unsorted) as $k
    | ($k | @csv),
      ($k | map($t[.]) | @csv)
  ' <<<"$VAULT_JSON"
}

output_total_md() {
  echo "| key               | value |"
  echo "|-------------------|-------|"
  jq -r '.data.total | to_entries[] | "| \(.key) | \(.value) |"' <<<"$VAULT_JSON"
}

output_non_entity_json() {
  jq -r '.data.total.non_entity_clients' <<<"$VAULT_JSON"
}

output_non_entity_csv() {
  {
    echo "non_entity_clients"
    jq -r '.data.total.non_entity_clients' <<<"$VAULT_JSON"
  }
}

output_non_entity_md() {
  echo "| metric              | value |"
  echo "|---------------------|-------|"
  printf '| non_entity_clients | %s |\n' "$(jq -r '.data.total.non_entity_clients' <<<"$VAULT_JSON")"
}

output_secret_syncs_json() {
  jq -r '.data.total.secret_syncs' <<<"$VAULT_JSON"
}

output_secret_syncs_csv() {
  {
    echo "secret_syncs"
    jq -r '.data.total.secret_syncs' <<<"$VAULT_JSON"
  }
}

output_secret_syncs_md() {
  echo "| metric       | value |"
  echo "|--------------|-------|"
  printf '| secret_syncs | %s |\n' "$(jq -r '.data.total.secret_syncs' <<<"$VAULT_JSON")"
}

output_summary_json() {
  jq -r '{
    clients: .data.total.clients,
    entity_clients: .data.total.entity_clients,
    distinct_entities: .data.total.distinct_entities,
    non_entity_clients: .data.total.non_entity_clients,
    secret_syncs: .data.total.secret_syncs
  }' <<<"$VAULT_JSON"
}

output_summary_csv() {
  jq -r '
    {
      clients: .data.total.clients,
      entity_clients: .data.total.entity_clients,
      distinct_entities: .data.total.distinct_entities,
      non_entity_clients: .data.total.non_entity_clients,
      secret_syncs: .data.total.secret_syncs
    } as $s
    | "clients,entity_clients,distinct_entities,non_entity_clients,secret_syncs",
      "\($s.clients),\($s.entity_clients),\($s.distinct_entities),\($s.non_entity_clients),\($s.secret_syncs)"
  ' <<<"$VAULT_JSON"
}

output_summary_md() {
  jq -r '
    {
      clients: .data.total.clients,
      entity_clients: .data.total.entity_clients,
      distinct_entities: .data.total.distinct_entities,
      non_entity_clients: .data.total.non_entity_clients,
      secret_syncs: .data.total.secret_syncs
    } as $s
    | "| metric            | value |",
      "|-------------------|-------|",
      "| clients           | \($s.clients) |",
      "| entity_clients    | \($s.entity_clients) |",
      "| distinct_entities | \($s.distinct_entities) |",
      "| non_entity_clients| \($s.non_entity_clients) |",
      "| secret_syncs      | \($s.secret_syncs) |"
  ' <<<"$VAULT_JSON"
}

output_env() {
  jq -r '
    .data.total as $t
    | "non_entity_clients=\($t.non_entity_clients)",
      "secret_syncs=\($t.secret_syncs)"
  ' <<<"$VAULT_JSON"
}

# --- Dispatch + capture for --output-file -------------------------------------

RESULT="$(
  case "$MODE_NORM" in
    total)
      case "$FORMAT" in
        json) output_total_json ;;
        csv)  output_total_csv ;;
        md)   output_total_md ;;
      esac
      ;;
    non-entity)
      case "$FORMAT" in
        json) output_non_entity_json ;;
        csv)  output_non_entity_csv ;;
        md)   output_non_entity_md ;;
      esac
      ;;
    secret-syncs)
      case "$FORMAT" in
        json) output_secret_syncs_json ;;
        csv)  output_secret_syncs_csv ;;
        md)   output_secret_syncs_md ;;
      esac
      ;;
    summary)
      case "$FORMAT" in
        json) output_summary_json ;;
        csv)  output_summary_csv ;;
        md)   output_summary_md ;;
      esac
      ;;
    env)
      output_env
      ;;
  esac
)"

# Print to stdout (for pipes / jq / etc.)
printf '%s\n' "$RESULT"

# Optionally write to file
if [[ -n "$OUTPUT_FILE" ]]; then
  printf '%s\n' "$RESULT" >"$OUTPUT_FILE"
  echo ""
  log_ok "Wrote output to ${BOLD}${OUTPUT_FILE}${RESET}"
fi
