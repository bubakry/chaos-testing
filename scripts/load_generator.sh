#!/usr/bin/env bash

set -euo pipefail

TARGET_URL="${1:-http://localhost:8080/api/orders}"
DURATION_SECONDS="${2:-30}"
SLEEP_MS="${3:-50}"

if ! [[ "$DURATION_SECONDS" =~ ^[0-9]+$ ]]; then
  echo "DURATION_SECONDS must be an integer" >&2
  exit 1
fi

if ! [[ "$SLEEP_MS" =~ ^[0-9]+$ ]]; then
  echo "SLEEP_MS must be an integer" >&2
  exit 1
fi

START_TS=$(date +%s)
END_TS=$((START_TS + DURATION_SECONDS))
TOTAL=0
SUCCESS=0
ERRORS=0
FIVE_XX=0

sleep_between_requests() {
  local seconds
  seconds=$(awk "BEGIN { printf \"%.3f\", ${SLEEP_MS} / 1000 }")
  sleep "$seconds"
}

while [ "$(date +%s)" -lt "$END_TS" ]; do
  STATUS=$(curl -s -o /dev/null -w "%{http_code}" "$TARGET_URL" || true)

  TOTAL=$((TOTAL + 1))
  if [[ "$STATUS" =~ ^2 ]]; then
    SUCCESS=$((SUCCESS + 1))
  else
    ERRORS=$((ERRORS + 1))
  fi

  if [[ "$STATUS" =~ ^5 ]]; then
    FIVE_XX=$((FIVE_XX + 1))
  fi

  sleep_between_requests
done

ERROR_RATE="0.00"
if [ "$TOTAL" -gt 0 ]; then
  ERROR_RATE=$(awk "BEGIN { printf \"%.2f\", (${ERRORS} / ${TOTAL}) * 100 }")
fi

cat <<REPORT
Load test complete:
- Target: ${TARGET_URL}
- Duration: ${DURATION_SECONDS}s
- Total requests: ${TOTAL}
- Success responses (2xx): ${SUCCESS}
- Error responses (!2xx): ${ERRORS}
- Server errors (5xx): ${FIVE_XX}
- Error rate: ${ERROR_RATE}%
REPORT
