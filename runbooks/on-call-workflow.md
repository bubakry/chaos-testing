# On-Call Workflow (Game Day)

## Objective

Respond to reliability incidents quickly, communicate clearly, and recover service safely while preserving evidence for postmortem analysis.

## Roles

- Incident Commander (IC): owns decisions and timeline control.
- Ops Lead: runs mitigation actions and verifies service recovery.
- Communications Lead: posts status updates to stakeholders every 15 minutes.
- Scribe: captures timeline events in real time.

One person can temporarily fill multiple roles for small teams, but assign an explicit IC every time.

## Severity Matrix

- `SEV-1`: Complete outage or severe customer impact.
  Response target: acknowledge in 5 minutes.
- `SEV-2`: Major degradation with partial impact.
  Response target: acknowledge in 10 minutes.
- `SEV-3`: Minor degradation, workaround available.
  Response target: acknowledge in 30 minutes.

## Alert Routing

AWS deployment route:

- CloudWatch alarms -> SNS critical topic -> primary on-call channel.
- CloudWatch alarms -> SNS warning topic -> secondary on-call channel.
- Optional email subscriptions are configured via Terraform variables.

Local fallback route:

- Alertmanager webhooks (`/primary`, `/secondary`, `/triage`) for offline practice.

## Escalation Workflow

1. Alert fires and primary on-call acknowledges.
2. If no acknowledgment within 5 minutes, escalate to backup on-call.
3. If incident is `SEV-1`, page engineering manager immediately.
4. If unresolved after 30 minutes, open leadership bridge and assign an executive update owner.

## Incident Response Checklist

1. Confirm alert legitimacy using CloudWatch alarm state, ALB/ECS metrics, and service health endpoints.
2. Declare severity and assign incident roles.
3. Contain blast radius (disable chaos switch, rollback, traffic shift, or rate-limit).
4. Restore service and verify SLO indicators are back to baseline.
5. Announce recovery and monitor for regression for at least 15 minutes.
6. Open postmortem and capture action items.

## Communication Cadence

- Initial status: within 10 minutes of incident start.
- Ongoing updates: every 15 minutes for `SEV-1`/`SEV-2`.
- Recovery update: immediately after stabilization.
- Final summary: within 24 hours with postmortem link.

## Exit Criteria

Close the incident only when all are true:

- No active critical alerts for the affected service.
- Health endpoints are green.
- Error rate and latency return to expected baseline.
- Follow-up tickets are created and assigned.
