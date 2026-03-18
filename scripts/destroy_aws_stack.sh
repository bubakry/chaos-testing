#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TF_DIR="${ROOT_DIR}/aws"

AWS_REGION="${AWS_REGION:-us-east-1}"
EXPECTED_ACCOUNT_ID="${EXPECTED_ACCOUNT_ID:-}"
PROJECT_NAME="${PROJECT_NAME:-chaos-game-day}"
ENVIRONMENT="${ENVIRONMENT:-demo}"
PRIMARY_ONCALL_EMAIL="${PRIMARY_ONCALL_EMAIL:-}"
SECONDARY_ONCALL_EMAIL="${SECONDARY_ONCALL_EMAIL:-}"
IMAGE_URI="${IMAGE_URI:-public.ecr.aws/docker/library/nginx:alpine}"
TF_WORKSPACE_NAME="${TF_WORKSPACE_NAME:-${PROJECT_NAME}-${ENVIRONMENT}}"
DELETE_WORKSPACE_AFTER_DESTROY="${DELETE_WORKSPACE_AFTER_DESTROY:-true}"

bool_is_true() {
  local lower
  lower="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')"
  case "$lower" in
    true|1|yes|y) return 0 ;;
    *) return 1 ;;
  esac
}

sanitize_workspace_name() {
  local value="$1"
  value="$(echo "$value" | tr -cs '[:alnum:]_-' '-')"
  value="${value#-}"
  value="${value%-}"
  if [ -z "$value" ]; then
    value="default"
  fi
  echo "$value"
}

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
if [ -z "$EXPECTED_ACCOUNT_ID" ]; then
  EXPECTED_ACCOUNT_ID="$ACCOUNT_ID"
fi

if [ "$ACCOUNT_ID" != "$EXPECTED_ACCOUNT_ID" ]; then
  cat >&2 <<MSG
Authenticated AWS account is $ACCOUNT_ID, but EXPECTED_ACCOUNT_ID is $EXPECTED_ACCOUNT_ID.
Switch credentials before destroying resources.
MSG
  exit 1
fi

cd "$TF_DIR"
terraform init -input=false
TF_WORKSPACE_NAME="$(sanitize_workspace_name "$TF_WORKSPACE_NAME")"

if ! terraform workspace select "$TF_WORKSPACE_NAME" >/dev/null 2>&1; then
  echo "Terraform workspace '${TF_WORKSPACE_NAME}' does not exist. Nothing to destroy." >&2
  exit 0
fi

echo "Using Terraform workspace: ${TF_WORKSPACE_NAME}"
terraform destroy -auto-approve \
  -var "aws_region=${AWS_REGION}" \
  -var "expected_account_id=${EXPECTED_ACCOUNT_ID}" \
  -var "project_name=${PROJECT_NAME}" \
  -var "environment=${ENVIRONMENT}" \
  -var "primary_oncall_email=${PRIMARY_ONCALL_EMAIL}" \
  -var "secondary_oncall_email=${SECONDARY_ONCALL_EMAIL}" \
  -var "image_uri=${IMAGE_URI}"

if bool_is_true "$DELETE_WORKSPACE_AFTER_DESTROY" && [ "$TF_WORKSPACE_NAME" != "default" ]; then
  terraform workspace select default >/dev/null
  terraform workspace delete "$TF_WORKSPACE_NAME" >/dev/null || true
fi

cat <<SUMMARY
Destroy complete for ${PROJECT_NAME}-${ENVIRONMENT} in account ${ACCOUNT_ID}.
Workspace: ${TF_WORKSPACE_NAME}
SUMMARY
