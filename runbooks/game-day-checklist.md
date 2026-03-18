# Reliability Game Day Checklist

## Pre-Game (1-2 days before)

1. Confirm scope and target scenarios (`error`, `latency`, `dependency`, `memory`, `cpu`).
2. Confirm participants and role assignments.
3. Share rollback plan and safety guardrails.
4. Verify AWS stack is healthy (ECS service running, ALB healthy targets).
5. Verify CloudWatch alarms and SNS subscriptions are configured.
6. If using local fallback mode, verify Prometheus + Alertmanager + mock webhook.

## Start-of-Game (T+0)

1. Announce start in team channel.
2. Start baseline traffic load.
3. Capture baseline values:
   - p95 latency
   - error rate
   - health endpoint status
   - active alerts count
   - current CloudWatch alarm states

## Scenario Execution

For each scenario:

1. Inject fault with `scripts/chaos_scenarios.sh`.
2. Confirm expected alerts fire.
3. Have on-call team follow runbook and mitigation workflow.
4. Record timeline and decisions.
5. Reset state and verify full recovery.

## Success Criteria

- Alerts fired for each intended fault mode.
- Team acknowledged incident within target SLA.
- Team communicated status updates on cadence.
- Service recovered within target recovery window.
- Postmortem draft produced with action items.

## Abort Conditions

Stop the exercise immediately if:

- Unintended impact appears outside the demo scope.
- Data loss risk is detected.
- Recovery path is not understood by IC.

## Post-Game

1. Conduct 30-minute debrief.
2. Fill postmortem template.
3. Create engineering action items and owners.
4. Schedule re-test date for unresolved gaps.
