#!/usr/bin/env bash
set -euo pipefail

# Orchestrator: clean all demos + final sweep.
#
# Flags:
#   --nuke-namespaces=true|false  : passthrough to the final cleanup script
#   --disable-userpass=true|false : passthrough to the final cleanup script
#   --continue-on-error           : keep going if a clean step fails

need() { command -v "$1" >/dev/null 2>&1 || { echo "❌ Missing dependency: $1"; exit 1; }; }
need bash
need jq
need vault

NUKE="--nuke-namespaces=false"
DISABLE_USERPASS="--disable-userpass=false"
CONTINUE_ON_ERROR=false

for a in "$@"; do
  case "$a" in
    --nuke-namespaces=true|--nuke-namespaces=false) NUKE="$a" ;;
    --disable-userpass=true|--disable-userpass=false) DISABLE_USERPASS="$a" ;;
    --continue-on-error) CONTINUE_ON_ERROR=true ;;
    *) echo "⚠️  Unknown arg: $a" ;;
  esac
done

run_step() {
  local title="$1"; shift
  echo
  echo "🧽 ${title}"
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

# Call each demo’s own cleaner (they know their artifacts best)
run_step "Clean Demo 01" bash ./ent_governance_demo_01.sh --clean
run_step "Clean Demo 02" bash ./ent_governance_demo_02.sh --clean
run_step "Clean Demo 03" bash ./ent_governance_demo_03.sh --clean
run_step "Clean Demo 04" bash ./ent_governance_demo_04.sh --clean
run_step "Clean Demo 05" bash ./ent_governance_demo_05.sh --clean

# Final global sweep (covers extra identities/policies/secrets from older runs)
# Note: your uploaded cleanup targets broader artifacts (team-a/team-b, kv, userpass).
# Keep it last so per-demo cleanup runs first. :contentReference[oaicite:1]{index=1}
run_step "Global cleanup" bash ./ent_governance_cleanup.sh "$NUKE" "$DISABLE_USERPASS"

echo
echo "🧹 All cleanup steps complete."
