#!/usr/bin/env bash
set -euo pipefail

CONFIG_FILE="${1:-config.json}"
command -v jq >/dev/null 2>&1 || { echo "jq is required"; exit 1; }

# --- time helpers (portable ms) ---
now_ms() {
  if command -v python3 >/dev/null 2>&1; then
    python3 - <<'PY'
import time
print(int(time.time() * 1000))
PY
  elif command -v gdate >/dev/null 2>&1; then
    gdate +%s%3N
  else
    printf '%s000\n' "$(date +%s)"
  fi
}

sleep_ms() {
  local ms="$1"
  awk -v ms="$ms" 'BEGIN { printf "%.3f\n", ms/1000 }' | xargs sleep
}

jq_val() { jq -r "$1" "$CONFIG_FILE"; }

PRIMARY_ADDR=$(jq_val '.primary.addr')
PRIMARY_TOKEN=$(jq_val '.primary.token')
SECONDARY_ADDR=$(jq_val '.secondary.addr')
SECONDARY_TOKEN=$(jq_val '.secondary.token')
NAMESPACE=$(jq_val '.namespace')
MOUNT=$(jq_val '.mount')
SECRET_PATH=$(jq_val '.secret_path')
ITERATIONS=$(jq_val '.iterations')
SLEEP_SECONDS=$(jq_val '.sleep_seconds')
MAX_WAIT_MS=$(jq -r '.max_wait_ms // 5000' "$CONFIG_FILE")
POLL_INTERVAL_MS=$(jq -r '.poll_interval_ms // 50' "$CONFIG_FILE")
CSV_OUT=$(jq -r '.csv_out // empty' "$CONFIG_FILE")
JSON_SUMMARY=$(jq -r '.json_summary // false' "$CONFIG_FILE")

echo "🏓 Performance Replication Ping-Pong"
echo "Primary:   $PRIMARY_ADDR"
echo "Secondary: $SECONDARY_ADDR"
echo "Namespace: $NAMESPACE"
echo "Path:      $MOUNT/$SECRET_PATH"
echo "Iterations: $ITERATIONS"
echo "Max wait:  ${MAX_WAIT_MS}ms, poll every ${POLL_INTERVAL_MS}ms"
echo

# --- preflight: reachability & role sanity ---
preflight() {
  local addr="$1" token="$2" who="$3"
  VAULT_ADDR="$addr" VAULT_TOKEN="$token" vault status >/dev/null 2>&1 || {
    echo "❌ $who not reachable/auth failed ($addr)"; exit 1;
  }
}
preflight "$PRIMARY_ADDR" "$PRIMARY_TOKEN" "Primary"
preflight "$SECONDARY_ADDR" "$SECONDARY_TOKEN" "Secondary"

# Optional: confirm the secondary is a perf secondary (won't fail the run; just warns)
if perf_state=$(VAULT_ADDR="$SECONDARY_ADDR" VAULT_TOKEN="$SECONDARY_TOKEN" vault read -format=json sys/replication/status 2>/dev/null); then
  mode=$(jq -r '.data.performance.mode // "unknown"' <<<"$perf_state")
  state=$(jq -r '.data.performance.state // "unknown"' <<<"$perf_state")
  if [[ "$mode" != "secondary" ]]; then
    echo "⚠️  Secondary perf mode is '$mode' (expected 'secondary'). Replication may not work."
  fi
  echo "ℹ️  Secondary replication state: $state"
fi

SUCCESS=0
FAIL=0
SUM=0
MIN_LAT=
MAX_LAT=
LAT_SERIES=()

# CSV header
if [[ -n "${CSV_OUT:-}" ]]; then
  echo "iteration,latency_ms,timestamp_ms,matched" > "$CSV_OUT"
fi

for i in $(seq 1 "$ITERATIONS"); do
  # tiny jitter (0–50ms) to avoid synchronous polling patterns
  JITTER=$(( RANDOM % 50 ))
  [[ $JITTER -gt 0 ]] && sleep_ms "$JITTER"

  VALUE="pong-$i-$(date +%s)"
  START=$(now_ms)

  # write on primary
  if ! VAULT_ADDR="$PRIMARY_ADDR" VAULT_TOKEN="$PRIMARY_TOKEN" \
      vault kv put -namespace="$NAMESPACE" "$MOUNT/$SECRET_PATH" value="$VALUE" >/dev/null 2>&1; then
    echo "[$i/$ITERATIONS] ❌ write failed on primary"
    FAIL=$((FAIL + 1))
    continue
  fi

  # poll on secondary until it matches or timeout
  MATCHED="no"
  READ_ERR=""
  while :; do
    set +e
    READ_VAL=$(VAULT_ADDR="$SECONDARY_ADDR" VAULT_TOKEN="$SECONDARY_TOKEN" \
      vault kv get -namespace="$NAMESPACE" -field=value "$MOUNT/$SECRET_PATH" 2>&1)
    rc=$?
    set -e

    NOW=$(now_ms)
    ELAPSED=$((NOW - START))

    if (( rc == 0 )) && [[ "$READ_VAL" == "$VALUE" ]]; then
      MATCHED="yes"; break
    fi

    # keep a short error tail for context
    READ_ERR="$READ_VAL"

    if (( ELAPSED >= MAX_WAIT_MS )); then
      break
    fi
    sleep_ms "$POLL_INTERVAL_MS"
  done

  if [[ "$MATCHED" == "yes" ]]; then
    echo "[$i/$ITERATIONS] ✅ replicated in ${ELAPSED} ms"
    SUCCESS=$((SUCCESS + 1))
    LAT_SERIES+=("$ELAPSED")
    SUM=$((SUM + ELAPSED))
    if [[ -z "${MIN_LAT:-}" || ELAPSED -lt MIN_LAT ]]; then MIN_LAT=$ELAPSED; fi
    if [[ -z "${MAX_LAT:-}" || ELAPSED -gt MAX_LAT ]]; then MAX_LAT=$ELAPSED; fi
  else
    short_err=$(echo "$READ_ERR" | tail -n1)
    [[ -z "$short_err" ]] && short_err="no match"
    echo "[$i/$ITERATIONS] ❌ timeout after ${ELAPSED} ms (expected $VALUE; got: $short_err)"
    FAIL=$((FAIL + 1))
  fi

  sleep "$SLEEP_SECONDS"
done

if (( SUCCESS > 0 )); then
  AVG=$((SUM / SUCCESS))
else
  MIN_LAT=0; MAX_LAT=0; AVG=0
fi

# percentiles (p50, p95)
p50="n/a"; p95="n/a"
if (( ${#LAT_SERIES[@]} > 0 )); then
  # shell-safe sort + percentile pick
  sorted=$(printf "%s\n" "${LAT_SERIES[@]}" | sort -n)
  count=${#LAT_SERIES[@]}
  idx_p50=$(( (50 * (count - 1) + 50) / 100 ))
  idx_p95=$(( (95 * (count - 1) + 50) / 100 ))
  # clamp
  (( idx_p50 < 0 )) && idx_p50=0
  (( idx_p50 >= count )) && idx_p50=$((count-1))
  (( idx_p95 < 0 )) && idx_p95=0
  (( idx_p95 >= count )) && idx_p95=$((count-1))
  p50=$(echo "$sorted" | awk -v n=$((idx_p50+1)) 'NR==n{print; exit}')
  p95=$(echo "$sorted" | awk -v n=$((idx_p95+1)) 'NR==n{print; exit}')
fi

echo
echo "Summary:"
echo "  Successes: $SUCCESS"
echo "  Failures:  $FAIL"
echo "  Min latency: ${MIN_LAT} ms"
echo "  Max latency: ${MAX_LAT} ms"
echo "  Avg latency: ${AVG} ms"
echo "  p50 latency: ${p50} ms"
echo "  p95 latency: ${p95} ms"
[[ -n "${CSV_OUT:-}" ]] && echo "  CSV saved: $CSV_OUT"

echo -e "\n📊 Scoreboard: $SUCCESS – $FAIL"
if (( FAIL == 0 )); then
  echo -e "🎾 Game, set, and match — replication held serve! 🏆"
else
  echo -e "🎾 Match interrupted — replication double faulted!"
fi

if [[ "$JSON_SUMMARY" == "true" ]]; then
  jq -n --arg primary "$PRIMARY_ADDR" \
        --arg secondary "$SECONDARY_ADDR" \
        --arg namespace "$NAMESPACE" \
        --arg mount "$MOUNT" \
        --arg path "$SECRET_PATH" \
        --argjson iterations "$ITERATIONS" \
        --argjson success "$SUCCESS" \
        --argjson fail "$FAIL" \
        --argjson min "$MIN_LAT" \
        --argjson max "$MAX_LAT" \
        --argjson avg "$AVG" \
        --argjson p50 "${p50:-0}" \
        --argjson p95 "${p95:-0}" \
        '{primary:$primary, secondary:$secondary, namespace:$namespace, mount:$mount, path:$path,
          iterations:$iterations, success:$success, fail:$fail, lat_ms:{min:$min,max:$max,avg:$avg,p50:$p50,p95:$p95}}'
fi
exit 0