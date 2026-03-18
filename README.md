# chaos-testing

Incident response and reliability game day project with controlled fault injection, local observability, and AWS deployment automation.

## What This Project Does

This project provides a small demo API that can intentionally inject failures so you can practice operational response under realistic conditions.

It includes:

- a Node.js API with health, readiness, and chaos control endpoints
- local mode with Prometheus and Alertmanager via Docker Compose
- AWS deployment IaC for ECR, ECS Fargate, ALB, CloudWatch alarms, and SNS routing
- runbooks for on-call response and game day execution
- templates for incident communications, handoff notes, and postmortems

## Why I Built It

I built this to practice the full operational loop, not just application deployment. The goal was to create a compact project where I could deploy a service, inject failures, validate alarms, follow runbooks, and document recovery as if it were a real incident.

## Tech Stack

- Node.js
- Docker and Docker Compose
- Prometheus
- Alertmanager
- Terraform
- AWS ECR
- AWS ECS Fargate
- AWS Application Load Balancer
- AWS CloudWatch and SNS
- Bash

## How to Run It

### Local mode

Prerequisites:

- Docker
- Docker Compose
- `curl`

Start the local stack:

```bash
docker compose up --build
```

Verify the API:

```bash
curl -s http://localhost:8080/healthz
curl -s http://localhost:8080/chaos/state
```

Run a baseline scenario:

```bash
BASE_URL=http://localhost:8080 ./scripts/chaos_scenarios.sh baseline
```

### AWS mode

Prerequisites:

- AWS CLI v2
- Terraform 1.5+
- Docker

Recommended environment:

```bash
export AWS_REGION=us-east-1
export PROJECT_NAME=chaos-game-day
export ENVIRONMENT=demo
```

Optional safety guardrail:

```bash
export EXPECTED_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
```

Deploy to AWS:

```bash
./scripts/deploy_to_aws.sh
```

Run a full game day workflow:

```bash
./scripts/aws_full_automation.sh
```

Optional CloudShell flow:

```bash
export SKIP_IMAGE_BUILD=true
export SOURCE_IMAGE_REPO_NAME=chaos-game-day-demo-chaos-api
./scripts/cloudshell_full_automation.sh
```

## Key Outcomes

- Built a reusable failure-injection API for incident response practice.
- Added both local and AWS deployment paths to support fast demos and realistic cloud exercises.
- Automated alerting and recovery validation with scripts, Terraform, and runbooks.
- Turned chaos engineering concepts into a recruiter-visible project with concrete operational artifacts.

## Core Endpoints

Business endpoints:

- `GET /api/orders`
- `GET /api/payments`
- `GET /api/notifications`

Health and state:

- `GET /healthz`
- `GET /readyz`
- `GET /chaos/state`

Chaos controls:

- `POST /chaos/error-rate`
- `POST /chaos/latency`
- `POST /chaos/dependency`
- `POST /chaos/memory`
- `POST /chaos/cpu`
- `POST /chaos/reset`

## Repository Structure

```text
chaos-testing/
  app/
  aws/
  scripts/
  runbooks/
  templates/
  prometheus/
  alertmanager/
  docker-compose.yml
```
