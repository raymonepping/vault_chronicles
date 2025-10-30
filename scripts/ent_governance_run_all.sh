#!/usr/bin/env bash
set -euo pipefail

# ==============================================
# HashiCorp Vault Enterprise Governance Demo Orchestrator
# Runs demos 1–5 sequentially, or specific ones via --demo flag
# ==============================================

need() { command -v "$1" >/dev/null 2>&1 || { echo "❌ Missing dependency: $1"; exit 1; }; }
need bash; need jq; need vault

# ----- Load .env -----
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

# ----- Default behavior -----
TRACE=false
HARD_EGP=false
SIMULATE_AFTER_HOURS=false
CONTINUE_ON_ERROR=false
DEMOS_TO_RUN=("1" "2" "3" "4" "5")

# ----- Parse arguments -----
for a in "$@"; do
  case "$a" in
    --trace) TRACE=true ;;
    --hard) HARD_EGP=true ;;
    --simulate-after-hours) SIMULATE_AFTER_HOURS=true ;;
    --continue-on-error) CONTINUE_ON_ERROR=true ;;
    --demo=*)
      IFS=',' read -ra DEMOS_TO_RUN <<<"${a#*=}"
      ;;
    *)
      echo "⚠️  Unknown arg: $a"
      ;;
  esac
done

# ----- Helper -----
run_step() {
  local title="$1"; shift
  echo
  echo "▶️  ${title}"
  echo "    → $*"
  if "$@"; then
    echo "✅ ${title} — ok"
  else
    echo "❌ ${title} — failed"
    if ! $CONTINUE_ON_ERROR; then
      exit 1
    fi
  fi
}

# ----- Build arguments -----
common_args=()
$TRACE && common_args+=(--trace)

demo05_args=("${common_args[@]}")
$HARD_EGP && demo05_args+=(--hard)
$SIMULATE_AFTER_HOURS && demo05_args+=(--simulate-after-hours)

# ----- Execute -----
echo "🚀 Starting Vault Governance Demo Orchestrator"
echo "   Selected demos: ${DEMOS_TO_RUN[*]}"
echo

for demo in "${DEMOS_TO_RUN[@]}"; do
  case "$demo" in
    1) run_step "Demo 01" bash ./ent_governance_demo_01.sh "${common_args[@]}" ;;
    2) run_step "Demo 02" bash ./ent_governance_demo_02.sh "${common_args[@]}" ;;
    3) run_step "Demo 03" bash ./ent_governance_demo_03.sh "${common_args[@]}" ;;
    4) run_step "Demo 04" bash ./ent_governance_demo_04.sh "${common_args[@]}" ;;
    5) run_step "Demo 05" bash ./ent_governance_demo_05.sh "${demo05_args[@]}" ;;
    *) echo "⚠️  Unknown demo number: $demo" ;;
  esac
done

echo
echo "🎉 Selected demos completed."
