#!/usr/bin/env bash
set -euo pipefail
nodes=(vault_enterprise_1 18200 vault_enterprise_2 18210 vault_enterprise_3 18220 vault_enterprise_sec_1 18300 vault_enterprise_sec_2 18400)

for ((i=0;i<${#nodes[@]};i+=2)); do
  cname="${nodes[i]}"
  port="${nodes[i+1]}"
  echo "[INFO] Restarting $cname..."
  docker restart "$cname" >/dev/null
  # wait for it to come up and auto-unseal
  for _ in {1..40}; do
    out=$(VAULT_ADDR="http://127.0.0.1:$port" vault status 2>/dev/null || true)
    if grep -q "Sealed *false" <<<"$out"; then
      mode=$(grep -E "HA Mode|Mode" <<<"$out" | head -1 | awk -F':' '{print $2}' | xargs)
      echo "[SUCCESS] $cname unsealed (${mode})"
      break
    fi
    sleep 0.5
  done
done
echo "[INFO] All nodes processed."