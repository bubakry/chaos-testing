#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TF_DIR="${ROOT_DIR}/aws"

SCENARIO="${1:-full-game-day}"
BASE_URL="${BASE_URL:-}"

if [ -z "$BASE_URL" ] && [ -d "$TF_DIR" ]; then
  if [ -f "${TF_DIR}/terraform.tfstate" ] || [ -f "${TF_DIR}/terraform.tfstate.backup" ]; then
    BASE_URL="$(terraform -chdir="$TF_DIR" output -raw chaos_base_url 2>/dev/null || true)"
  fi
fi

if [ -z "$BASE_URL" ]; then
  cat >&2 <<MSG
BASE_URL is not set and could not be inferred from Terraform output.
Set BASE_URL explicitly, e.g.:
  BASE_URL=http://<alb-dns-name> $0 ${SCENARIO}
MSG
  exit 1
fi

echo "Running scenario '${SCENARIO}' against ${BASE_URL}"
BASE_URL="$BASE_URL" "${SCRIPT_DIR}/chaos_scenarios.sh" "$SCENARIO"

echo
if command -v aws >/dev/null 2>&1; then
  echo "Current AWS alarm states:"
  AWS_REGION="${AWS_REGION:-us-east-1}" \
    PROJECT_NAME="${PROJECT_NAME:-chaos-game-day}" \
    ENVIRONMENT="${ENVIRONMENT:-demo}" \
    "${SCRIPT_DIR}/aws_alarm_status.sh" || true
fi
