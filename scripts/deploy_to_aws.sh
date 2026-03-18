#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
APP_DIR="${ROOT_DIR}/app"
TF_DIR="${ROOT_DIR}/aws"

AWS_REGION="${AWS_REGION:-us-east-1}"
EXPECTED_ACCOUNT_ID="${EXPECTED_ACCOUNT_ID:-}"
PROJECT_NAME="${PROJECT_NAME:-chaos-game-day}"
ENVIRONMENT="${ENVIRONMENT:-demo}"
IMAGE_TAG="${IMAGE_TAG:-$(date +%Y%m%d%H%M%S)}"
PRIMARY_ONCALL_EMAIL="${PRIMARY_ONCALL_EMAIL:-}"
SECONDARY_ONCALL_EMAIL="${SECONDARY_ONCALL_EMAIL:-}"
IMAGE_PLATFORM="${IMAGE_PLATFORM:-linux/amd64}"
SKIP_IMAGE_BUILD="${SKIP_IMAGE_BUILD:-false}"
IMAGE_URI="${IMAGE_URI:-}"
SOURCE_IMAGE_REPO_NAME="${SOURCE_IMAGE_REPO_NAME:-}"
TF_WORKSPACE_NAME="${TF_WORKSPACE_NAME:-${PROJECT_NAME}-${ENVIRONMENT}}"

require() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

require aws
require terraform

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
  # Keep workspace names portable and deterministic.
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
Switch your AWS credentials/profile to account $EXPECTED_ACCOUNT_ID and rerun.
MSG
  exit 1
fi

echo "Deploying chaos-testing stack to account ${ACCOUNT_ID} in ${AWS_REGION}..."

TF_ARGS=(
  -var "aws_region=${AWS_REGION}"
  -var "expected_account_id=${EXPECTED_ACCOUNT_ID}"
  -var "project_name=${PROJECT_NAME}"
  -var "environment=${ENVIRONMENT}"
  -var "primary_oncall_email=${PRIMARY_ONCALL_EMAIL}"
  -var "secondary_oncall_email=${SECONDARY_ONCALL_EMAIL}"
)

cd "$TF_DIR"
terraform init -input=false

TF_WORKSPACE_NAME="$(sanitize_workspace_name "$TF_WORKSPACE_NAME")"
if terraform workspace select "$TF_WORKSPACE_NAME" >/dev/null 2>&1; then
  echo "Using Terraform workspace: ${TF_WORKSPACE_NAME}"
else
  terraform workspace new "$TF_WORKSPACE_NAME" >/dev/null
  echo "Created Terraform workspace: ${TF_WORKSPACE_NAME}"
fi

if bool_is_true "$SKIP_IMAGE_BUILD"; then
  if [ -z "$IMAGE_URI" ] && [ -n "$SOURCE_IMAGE_REPO_NAME" ]; then
    LATEST_TAG="$(aws ecr describe-images --region "$AWS_REGION" --repository-name "$SOURCE_IMAGE_REPO_NAME" --query 'sort_by(imageDetails,& imagePushedAt)[-1].imageTags[0]' --output text)"
    if [ -z "$LATEST_TAG" ] || [ "$LATEST_TAG" = "None" ]; then
      echo "Could not resolve latest image tag from repository ${SOURCE_IMAGE_REPO_NAME}." >&2
      exit 1
    fi
    IMAGE_URI="${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${SOURCE_IMAGE_REPO_NAME}:${LATEST_TAG}"
  fi

  if [ -z "$IMAGE_URI" ]; then
    cat >&2 <<MSG
SKIP_IMAGE_BUILD=true requires one of:
- IMAGE_URI=<full ECR image URI>
- SOURCE_IMAGE_REPO_NAME=<repo name with at least one tagged image>
MSG
    exit 1
  fi

  echo "Skipping Docker build. Using prebuilt image: ${IMAGE_URI}"
else
  require docker

  if ! docker info >/dev/null 2>&1; then
    echo "Docker daemon is not running. Start Docker and retry." >&2
    exit 1
  fi

  # Phase 1: create ECR repository with account guardrail in place.
  terraform apply -input=false -auto-approve \
    "${TF_ARGS[@]}" \
    -target=terraform_data.account_guardrail \
    -target=aws_ecr_repository.chaos_api

  ECR_REPO_URL="$(terraform output -raw ecr_repository_url)"
  IMAGE_URI="${ECR_REPO_URL}:${IMAGE_TAG}"

  aws ecr get-login-password --region "$AWS_REGION" | docker login \
    --username AWS \
    --password-stdin "${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"

  echo "Building and pushing image: ${IMAGE_URI}"
  if docker buildx version >/dev/null 2>&1; then
    docker buildx build --platform "$IMAGE_PLATFORM" -t "$IMAGE_URI" --push "$APP_DIR"
  else
    echo "docker buildx not found; falling back to classic docker build/push." >&2
    docker build -t "$IMAGE_URI" "$APP_DIR"
    docker push "$IMAGE_URI"
  fi
fi

# Phase 2: deploy full stack (ECS, ALB, alarms, SNS).
terraform apply -input=false -auto-approve \
  "${TF_ARGS[@]}" \
  -var "image_uri=${IMAGE_URI}"

BASE_URL="$(terraform output -raw chaos_base_url)"

cat <<SUMMARY

Deployment complete.
- AWS Account: ${ACCOUNT_ID}
- Region: ${AWS_REGION}
- Image URI: ${IMAGE_URI}
- Service URL: ${BASE_URL}

Next steps:
1. Verify health: curl -s ${BASE_URL}/healthz
2. Run scenario: BASE_URL=${BASE_URL} ${SCRIPT_DIR}/chaos_scenarios.sh error-storm
3. Check alarms: AWS_REGION=${AWS_REGION} ${SCRIPT_DIR}/aws_alarm_status.sh
SUMMARY
