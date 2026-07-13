#!/bin/bash
# CE-5 RPO/RTO load harness — logs every POST /orders attempt with ms timestamps.
# Log format (CSV): epoch_ms,worker,http_status,curl_time_s,orderId(or error)
# An HTTP 202 line is an ACKED write: that orderId MUST exist in ordersdb after failover (RPO=0).
BASE="${BASE_URL:-https://eurotransit.vojtechn.dev}"
ROUTE="${ROUTE_ID:-00000000-0000-0000-0000-000000000001}"
OUT="${OUT:-$(dirname "$0")/ce5-acks.csv}"
WORKERS="${WORKERS:-3}"
STOP_FILE="$(dirname "$0")/ce5-stop"

rm -f "$STOP_FILE"
worker() {
  local w=$1 i=0
  while [ ! -f "$STOP_FILE" ]; do
    i=$((i+1))
    local key="ce5-w${w}-${i}-$(date +%s%N)"
    local ts=$(($(date +%s%N)/1000000))
    # -m 5: bound each attempt to 5s so the harness keeps sampling during the outage window
    local resp
    resp=$(curl -sS -m 5 -w '\n%{http_code} %{time_total}' \
      -H 'Content-Type: application/json' -H "Idempotency-Key: $key" \
      -d "{\"routeId\":\"$ROUTE\",\"seats\":1}" \
      "$BASE/api/orders" 2>&1)
    local meta=$(echo "$resp" | tail -1)
    local body=$(echo "$resp" | sed '$d' | tr -d '\n')
    local code=$(echo "$meta" | cut -d' ' -f1)
    local t=$(echo "$meta" | cut -d' ' -f2)
    local oid=""
    case "$code" in
      202|200) oid=$(echo "$body" | sed -n 's/.*"orderId":"\([0-9a-f-]*\)".*/\1/p');;
      *) oid=$(echo "$body" | head -c 60 | tr ',' ';');;
    esac
    echo "$ts,$w,$code,$t,$oid" >> "$OUT"
    sleep 0.3
  done
}
echo "epoch_ms,worker,status,time_s,orderId" > "$OUT"
for w in $(seq 1 "$WORKERS"); do worker "$w" & done
echo "harness pid=$$ workers=$WORKERS out=$OUT (touch $STOP_FILE to stop)"
wait
