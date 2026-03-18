# Alert -> Playbook Map

This map supports AWS-first response and local fallback.

Assumptions for examples:

- `PROJECT_NAME=chaos-game-day`
- `ENVIRONMENT=demo`
- `AWS_REGION=us-east-1`
- `BASE_URL=http://<alb-dns-name>`

## `*-alb-unhealthy-hosts` (critical)

### Triage

- Check target health:
  - `aws elbv2 describe-target-health --target-group-arn <target-group-arn> --region $AWS_REGION`
- Check ECS service events:
  - `aws ecs describe-services --cluster ${PROJECT_NAME}-${ENVIRONMENT}-cluster --services ${PROJECT_NAME}-${ENVIRONMENT}-chaos-api --region $AWS_REGION`

### Mitigation

- If caused by chaos toggle, reset app state:
  - `curl -s -X POST "$BASE_URL/chaos/reset" -H 'Content-Type: application/json' -d '{}'`
- If tasks are unhealthy, force new deployment:
  - `aws ecs update-service --cluster ${PROJECT_NAME}-${ENVIRONMENT}-cluster --service ${PROJECT_NAME}-${ENVIRONMENT}-chaos-api --force-new-deployment --region $AWS_REGION`

### Recovery checks

- `curl -s "$BASE_URL/healthz"`
- Alarm returns from `ALARM` to `OK`

## `*-high-5xx-rate` (critical)

### Triage

- Confirm fault-injection settings:
  - `curl -s "$BASE_URL/chaos/state"`
- Confirm ALB error trend:
  - `aws cloudwatch get-metric-statistics --namespace AWS/ApplicationELB --metric-name HTTPCode_Target_5XX_Count --start-time <utc-start> --end-time <utc-end> --period 60 --statistics Sum --dimensions Name=LoadBalancer,Value=<alb-arn-suffix> Name=TargetGroup,Value=<tg-arn-suffix> --region $AWS_REGION`

### Mitigation

- Disable injected failure if this is containment:
  - `curl -s -X POST "$BASE_URL/chaos/reset" -H 'Content-Type: application/json' -d '{}'`
- Run controlled verification traffic:
  - `BASE_URL="$BASE_URL" ./scripts/chaos_scenarios.sh baseline`

### Recovery checks

- 5xx ratio drops below threshold
- Alarm returns to `OK`

## `*-high-p95-latency` (warning)

### Triage

- Check injected latency (`latencyMs`):
  - `curl -s "$BASE_URL/chaos/state"`
- Check ECS CPU and memory to rule out saturation:
  - `./scripts/aws_alarm_status.sh`

### Mitigation

- Remove latency injection:
  - `curl -s -X POST "$BASE_URL/chaos/latency" -H 'Content-Type: application/json' -d '{"ms":0}'`
- If CPU bound, scale service:
  - `aws ecs update-service --cluster ${PROJECT_NAME}-${ENVIRONMENT}-cluster --service ${PROJECT_NAME}-${ENVIRONMENT}-chaos-api --desired-count 2 --region $AWS_REGION`

### Recovery checks

- p95 drops below threshold over alarm evaluation windows
- Alarm returns to `OK`

## `*-ecs-high-cpu` (warning)

### Triage

- Check service utilization and task health in ECS console or CLI.
- Confirm whether `cpu-burst` scenario is active.

### Mitigation

- Reset chaos state if burst was injected.
- Temporarily increase task count to absorb load.

### Recovery checks

- CPU utilization normalizes
- Alarm returns to `OK`

## `*-ecs-high-memory` (warning)

### Triage

- Check retained memory in app state:
  - `curl -s "$BASE_URL/chaos/state"`
- Verify task restarts or OOM symptoms from ECS service events.

### Mitigation

- Reset chaos state to release held references.
- If pressure continues, roll tasks or increase task memory in Terraform and redeploy.

### Recovery checks

- Memory utilization trend drops
- Alarm returns to `OK`

## Local Fallback Commands

If using local mode instead of AWS:

- `docker compose ps`
- `docker compose logs chaos-api --tail=200`
- `curl -s http://localhost:8080/chaos/state`
- `curl -s -X POST http://localhost:8080/chaos/reset -H 'Content-Type: application/json' -d '{}'`
