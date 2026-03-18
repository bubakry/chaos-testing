#!/usr/bin/env bash

set -euo pipefail

AWS_REGION="${AWS_REGION:-us-east-1}"
PROJECT_NAME="${PROJECT_NAME:-chaos-game-day}"
ENVIRONMENT="${ENVIRONMENT:-demo}"
PREFIX="${PROJECT_NAME}-${ENVIRONMENT}"

aws cloudwatch describe-alarms \
  --region "$AWS_REGION" \
  --alarm-name-prefix "$PREFIX" \
  --query 'MetricAlarms[].{Alarm:AlarmName,State:StateValue,Updated:StateUpdatedTimestamp,Reason:StateReason}' \
  --output table
