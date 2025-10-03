#!/usr/bin/env bash
set -euo pipefail
export VAULT_ADDR=http://127.0.0.1:18200
export VAULT_TOKEN="$(awk -F': ' '/Initial Root Token:/ {print $2}' ops/INIT.out)"

vault login -no-print "$VAULT_TOKEN" >/dev/null 2>&1 || true
echo "## Raft peers"
vault operator raft list-peers
echo
for PORT in 18200 18210 18220; do
  echo "## Status @ ${PORT}"
  VAULT_ADDR="http://127.0.0.1:${PORT}" vault status | awk '/Sealed|HA Mode|Active Node Address|Performance Standby|Raft Committed/'
  echo
done
