# AWS Chaos Testing Notes

This document captures repeatable validation notes for deploying and exercising the `chaos-testing` stack in AWS.

## Scope

- Region example: `us-east-1`
- Project example: `chaos-game-day`
- Environment example: `demo`

## What to Expect During Early Deployment

### `503 Service Temporarily Unavailable` on `/healthz`

This can happen briefly while ECS tasks register with the ALB target group. If it persists beyond normal startup time, inspect ECS service events and target health.

### Alarm state `INSUFFICIENT_DATA`

New CloudWatch alarms often begin in `INSUFFICIENT_DATA` until enough datapoints arrive. This is normal immediately after stack creation.

## Common Failure Cases and Fixes

### ECS task crash: `exec format error`

Root cause:

- Container image built for the wrong architecture.

Recommended fix:

- Build with `docker buildx build --platform linux/amd64 ... --push`

### CloudWatch p95 alarm configuration issue

Root cause:

- Using `statistic = "p95"` instead of `extended_statistic = "p95"`.

### Slow environment teardown

Root cause:

- Normal ECS and ALB draining behavior.

Mitigations used in this project:

- shorter target deregistration delay
- force-delete enabled for ECS service teardown

## Fast Validation Flow

Run the end-to-end automation:

```bash
export AWS_REGION=us-east-1
export PROJECT_NAME=chaos-game-day
export ENVIRONMENT=dev-$(date +%m%d%H%M)
export EXPECTED_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export DESTROY_AT_END=true

./scripts/aws_full_automation.sh
```

This flow:

- deploys infrastructure
- waits for health
- runs baseline traffic
- injects an error storm
- checks alarm state
- resets the service
- validates recovery
- optionally destroys the environment

## Manual Validation Checklist

### 1. Confirm active account and environment

```bash
aws sts get-caller-identity
terraform version
docker info
```

### 2. Deploy

```bash
./scripts/deploy_to_aws.sh
```

### 3. Health check

```bash
BASE_URL=$(terraform -chdir=aws output -raw chaos_base_url)
curl -s "$BASE_URL/healthz"
```

### 4. Generate baseline traffic

```bash
./scripts/load_generator.sh "$BASE_URL/api/orders" 30 60
```

### 5. Trigger a failure scenario

```bash
BASE_URL="$BASE_URL" ./scripts/chaos_scenarios.sh error-storm
AWS_REGION=$AWS_REGION PROJECT_NAME=$PROJECT_NAME ENVIRONMENT=$ENVIRONMENT ./scripts/aws_alarm_status.sh
```

### 6. Recover

```bash
curl -s -X POST "$BASE_URL/chaos/reset" -H "Content-Type: application/json" -d '{}'
./scripts/load_generator.sh "$BASE_URL/api/orders" 60 60
```

### 7. Destroy test resources

```bash
./scripts/destroy_aws_stack.sh
```

## Useful Troubleshooting Commands

ECS service state:

```bash
aws ecs describe-services \
  --region "$AWS_REGION" \
  --cluster <cluster-name> \
  --services <service-name>
```

ALB target health:

```bash
aws elbv2 describe-target-health \
  --region "$AWS_REGION" \
  --target-group-arn <target-group-arn>
```
