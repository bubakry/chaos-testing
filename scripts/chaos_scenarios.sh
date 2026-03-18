#!/usr/bin/env bash

set -euo pipefail

BASE_URL="${BASE_URL:-http://localhost:8080}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

post_json() {
  local endpoint="$1"
  local payload="$2"

  curl -sS -X POST "${BASE_URL}${endpoint}" \
    -H "Content-Type: application/json" \
    -d "$payload"
  echo
}

show_state() {
  echo "Current chaos state:"
  curl -sS "${BASE_URL}/chaos/state"
  echo
}

baseline() {
  echo "Running baseline load (healthy state)..."
  "${SCRIPT_DIR}/load_generator.sh" "${BASE_URL}/api/orders" 30 40
}

error_storm() {
  echo "Injecting high random error rate (70%)..."
  post_json "/chaos/error-rate" '{"percent":70}'
  show_state
  "${SCRIPT_DIR}/load_generator.sh" "${BASE_URL}/api/orders" 150 40
}

latency_spike() {
  echo "Injecting 1500ms latency..."
  post_json "/chaos/latency" '{"ms":1500}'
  show_state
  "${SCRIPT_DIR}/load_generator.sh" "${BASE_URL}/api/payments" 360 100
}

dependency_outage() {
  echo "Simulating dependency outage..."
  post_json "/chaos/dependency" '{"down":true}'
  show_state
  "${SCRIPT_DIR}/load_generator.sh" "${BASE_URL}/api/notifications" 120 60
}

memory_pressure() {
  echo "Injecting retained memory (+250MB)..."
  post_json "/chaos/memory" '{"mb":250}'
  show_state
  "${SCRIPT_DIR}/load_generator.sh" "${BASE_URL}/api/orders" 90 50
}

cpu_burst() {
  echo "Burning CPU for 20 seconds..."
  post_json "/chaos/cpu" '{"seconds":20}'
  show_state
}

reset_state() {
  echo "Resetting chaos state..."
  post_json "/chaos/reset" '{}'
  show_state
}

full_game_day() {
  baseline
  error_storm
  reset_state

  latency_spike
  reset_state

  dependency_outage
  reset_state

  memory_pressure
  cpu_burst
  reset_state

  echo "Full game-day scenario sequence completed."
}

usage() {
  cat <<USAGE
Usage: $0 <scenario>

Available scenarios:
- baseline
- error-storm
- latency-spike
- dependency-outage
- memory-pressure
- cpu-burst
- reset
- full-game-day

Optional environment variable:
- BASE_URL (default: http://localhost:8080)
USAGE
}

SCENARIO="${1:-}"

case "$SCENARIO" in
  baseline)
    baseline
    ;;
  error-storm)
    error_storm
    ;;
  latency-spike)
    latency_spike
    ;;
  dependency-outage)
    dependency_outage
    ;;
  memory-pressure)
    memory_pressure
    ;;
  cpu-burst)
    cpu_burst
    ;;
  reset)
    reset_state
    ;;
  full-game-day)
    full_game_day
    ;;
  *)
    usage
    exit 1
    ;;
esac
