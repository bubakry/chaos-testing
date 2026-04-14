#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

AWS_REGION="${AWS_REGION:-us-east-1}"
EXPECTED_ACCOUNT_ID="${EXPECTED_ACCOUNT_ID:-}"
PROJECT_NAME="${PROJECT_NAME:-chaos-game-day}"
ENVIRONMENT="${ENVIRONMENT:-dev-$(date +%m%d%H%M)}"
AWS_PROFILE_NAME="${AWS_PROFILE:-${AWS_DEFAULT_PROFILE:-}}"
PRIMARY_ONCALL_EMAIL="${PRIMARY_ONCALL_EMAIL:-}"
SECONDARY_ONCALL_EMAIL="${SECONDARY_ONCALL_EMAIL:-}"
SKIP_IMAGE_BUILD="${SKIP_IMAGE_BUILD:-false}"
IMAGE_URI="${IMAGE_URI:-}"
SOURCE_IMAGE_REPO_NAME="${SOURCE_IMAGE_REPO_NAME:-}"
TF_WORKSPACE_NAME="${TF_WORKSPACE_NAME:-${PROJECT_NAME}-${ENVIRONMENT}}"
HEALTH_TIMEOUT_SECONDS="${HEALTH_TIMEOUT_SECONDS:-600}"
HEALTH_POLL_SECONDS="${HEALTH_POLL_SECONDS:-5}"
DESTROY_AT_END="${DESTROY_AT_END:-false}"

BASELINE_DURATION_SECONDS="${BASELINE_DURATION_SECONDS:-30}"
BASELINE_SLEEP_MS="${BASELINE_SLEEP_MS:-60}"
RECOVERY_DURATION_SECONDS="${RECOVERY_DURATION_SECONDS:-60}"
RECOVERY_SLEEP_MS="${RECOVERY_SLEEP_MS:-60}"

require() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

require aws
require curl
require terraform

bool_is_true() {
  local lower
  lower="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')"
  case "$lower" in
    true|1|yes|y) return 0 ;;
    *) return 1 ;;
  esac
}

AWS_PROFILE_ARGS=()
if [ -n "$AWS_PROFILE_NAME" ]; then
  AWS_PROFILE_ARGS+=(--profile "$AWS_PROFILE_NAME")
else
  # Avoid passing empty profile variables; AWS CLI treats them as profile "()".
  unset AWS_PROFILE || true
  unset AWS_DEFAULT_PROFILE || true
fi

HEALTH_TMP_FILE="/tmp/chaos-health-$$.json"

wait_for_health() {
  local base_url="$1"
  local elapsed=0

  echo "Waiting for healthy endpoint at ${base_url}/healthz ..."
  while [ "$elapsed" -lt "$HEALTH_TIMEOUT_SECONDS" ]; do
    code=$(curl -m 4 --connect-timeout 2 -s -o "$HEALTH_TMP_FILE" -w '%{http_code}' "${base_url}/healthz" || true)
    echo "- health check: code=${code:-none}, elapsed=${elapsed}s"

    if [ "$code" = "200" ]; then
      echo "Service is healthy."
      cat "$HEALTH_TMP_FILE" || true
      echo
      return 0
    fi

    sleep "$HEALTH_POLL_SECONDS"
    elapsed=$((elapsed + HEALTH_POLL_SECONDS))
  done

  echo "Timed out waiting for healthy service after ${HEALTH_TIMEOUT_SECONDS}s" >&2
  cat "$HEALTH_TMP_FILE" 2>/dev/null || true
  return 1
}

wait_for_alarm_state() {
  local alarm_name="$1"
  local expected_state="$2"
  local timeout_seconds="${3:-480}"
  local poll_seconds="${4:-30}"
  local elapsed=0

  echo "Waiting for alarm '${alarm_name}' to reach state '${expected_state}' ..."
  while [ "$elapsed" -lt "$timeout_seconds" ]; do
    state=$(aws cloudwatch describe-alarms \
      "${AWS_PROFILE_ARGS[@]}" \
      --region "$AWS_REGION" \
      --alarm-names "$alarm_name" \
      --query 'MetricAlarms[0].StateValue' \
      --output text 2>/dev/null || echo "UNKNOWN")

    echo "- alarm state=${state}, elapsed=${elapsed}s"
    if [ "$state" = "$expected_state" ]; then
      return 0
    fi

    sleep "$poll_seconds"
    elapsed=$((elapsed + poll_seconds))
  done

  echo "Alarm '${alarm_name}' did not reach '${expected_state}' within ${timeout_seconds}s" >&2
  return 1
}

cleanup() {
  rm -f "$HEALTH_TMP_FILE" || true

  if bool_is_true "$DESTROY_AT_END"; then
    echo
    echo "Destroying AWS stack because DESTROY_AT_END=${DESTROY_AT_END}"
    if [ -n "$AWS_PROFILE_NAME" ]; then
      AWS_PROFILE="$AWS_PROFILE_NAME" \
      AWS_REGION="$AWS_REGION" \
      EXPECTED_ACCOUNT_ID="$EXPECTED_ACCOUNT_ID" \
      PROJECT_NAME="$PROJECT_NAME" \
      ENVIRONMENT="$ENVIRONMENT" \
      PRIMARY_ONCALL_EMAIL="$PRIMARY_ONCALL_EMAIL" \
      SECONDARY_ONCALL_EMAIL="$SECONDARY_ONCALL_EMAIL" \
      "${SCRIPT_DIR}/destroy_aws_stack.sh" || true
    else
      AWS_REGION="$AWS_REGION" \
      EXPECTED_ACCOUNT_ID="$EXPECTED_ACCOUNT_ID" \
      PROJECT_NAME="$PROJECT_NAME" \
      ENVIRONMENT="$ENVIRONMENT" \
      PRIMARY_ONCALL_EMAIL="$PRIMARY_ONCALL_EMAIL" \
      SECONDARY_ONCALL_EMAIL="$SECONDARY_ONCALL_EMAIL" \
      "${SCRIPT_DIR}/destroy_aws_stack.sh" || true
    fi
  fi
}

trap cleanup EXIT

if [ -n "$AWS_PROFILE_NAME" ]; then
  export AWS_PROFILE="$AWS_PROFILE_NAME"
  unset AWS_DEFAULT_PROFILE || true
else
  unset AWS_PROFILE || true
  unset AWS_DEFAULT_PROFILE || true
fi
export AWS_REGION EXPECTED_ACCOUNT_ID PROJECT_NAME ENVIRONMENT PRIMARY_ONCALL_EMAIL SECONDARY_ONCALL_EMAIL
export SKIP_IMAGE_BUILD IMAGE_URI SOURCE_IMAGE_REPO_NAME TF_WORKSPACE_NAME

echo "Starting full AWS chaos automation"
if [ -n "$AWS_PROFILE_NAME" ]; then
  echo "- AWS_PROFILE=${AWS_PROFILE_NAME}"
else
  echo "- AWS_PROFILE=<default provider chain>"
fi
echo "- AWS_REGION=${AWS_REGION}"
echo "- EXPECTED_ACCOUNT_ID=${EXPECTED_ACCOUNT_ID}"
echo "- PROJECT_NAME=${PROJECT_NAME}"
echo "- ENVIRONMENT=${ENVIRONMENT}"
echo "- SKIP_IMAGE_BUILD=${SKIP_IMAGE_BUILD}"
echo "- TF_WORKSPACE_NAME=${TF_WORKSPACE_NAME}"
echo "- DESTROY_AT_END=${DESTROY_AT_END}"
echo

identity_account=$(aws sts get-caller-identity "${AWS_PROFILE_ARGS[@]}" --query Account --output text)
if [ -z "$EXPECTED_ACCOUNT_ID" ]; then
  EXPECTED_ACCOUNT_ID="$identity_account"
  export EXPECTED_ACCOUNT_ID
fi

if [ "$identity_account" != "$EXPECTED_ACCOUNT_ID" ]; then
  echo "Authenticated account is ${identity_account}, expected ${EXPECTED_ACCOUNT_ID}." >&2
  exit 1
fi

"${SCRIPT_DIR}/deploy_to_aws.sh"

terraform -chdir="${ROOT_DIR}/aws" workspace select "$TF_WORKSPACE_NAME" >/dev/null 2>&1 || true
BASE_URL=$(terraform -chdir="${ROOT_DIR}/aws" output -raw chaos_base_url)
ALARM_5XX="${PROJECT_NAME}-${ENVIRONMENT}-high-5xx-rate"

echo
echo "Deployment URL: ${BASE_URL}"
wait_for_health "$BASE_URL"

echo
"${SCRIPT_DIR}/load_generator.sh" "${BASE_URL}/api/orders" "$BASELINE_DURATION_SECONDS" "$BASELINE_SLEEP_MS"

echo
BASE_URL="$BASE_URL" "${SCRIPT_DIR}/chaos_scenarios.sh" error-storm

# Give CloudWatch a short window to ingest datapoints before polling alarm state.
sleep 30
wait_for_alarm_state "$ALARM_5XX" "ALARM" 600 30

echo
if [ -n "$AWS_PROFILE_NAME" ]; then
  AWS_PROFILE="$AWS_PROFILE_NAME" AWS_REGION="$AWS_REGION" PROJECT_NAME="$PROJECT_NAME" ENVIRONMENT="$ENVIRONMENT" \
    "${SCRIPT_DIR}/aws_alarm_status.sh"
else
  AWS_REGION="$AWS_REGION" PROJECT_NAME="$PROJECT_NAME" ENVIRONMENT="$ENVIRONMENT" \
    "${SCRIPT_DIR}/aws_alarm_status.sh"
fi

echo
curl -sS -X POST "${BASE_URL}/chaos/reset" -H 'Content-Type: application/json' -d '{}'
echo
"${SCRIPT_DIR}/load_generator.sh" "${BASE_URL}/api/orders" "$RECOVERY_DURATION_SECONDS" "$RECOVERY_SLEEP_MS"

echo
if [ -n "$AWS_PROFILE_NAME" ]; then
  AWS_PROFILE="$AWS_PROFILE_NAME" AWS_REGION="$AWS_REGION" PROJECT_NAME="$PROJECT_NAME" ENVIRONMENT="$ENVIRONMENT" \
    "${SCRIPT_DIR}/aws_alarm_status.sh"
else
  AWS_REGION="$AWS_REGION" PROJECT_NAME="$PROJECT_NAME" ENVIRONMENT="$ENVIRONMENT" \
    "${SCRIPT_DIR}/aws_alarm_status.sh"
fi

echo
if wait_for_alarm_state "$ALARM_5XX" "OK" 900 30; then
  echo "Recovery confirmed: high-5xx alarm returned to OK."
else
  echo "Recovery check warning: high-5xx alarm did not return to OK within timeout." >&2
fi

echo
cat <<SUMMARY
Full automation run completed.
- Base URL: ${BASE_URL}
- High-5xx alarm: ${ALARM_5XX}
- Destroy at end: ${DESTROY_AT_END}
SUMMARY
