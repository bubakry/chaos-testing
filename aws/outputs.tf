output "account_id" {
  description = "Authenticated AWS account ID used by provider"
  value       = data.aws_caller_identity.current.account_id
}

output "ecr_repository_url" {
  description = "ECR repository URL for chaos API image"
  value       = aws_ecr_repository.chaos_api.repository_url
}

output "ecs_cluster_name" {
  description = "ECS cluster name"
  value       = aws_ecs_cluster.chaos.name
}

output "ecs_service_name" {
  description = "ECS service name"
  value       = aws_ecs_service.chaos_api.name
}

output "alb_dns_name" {
  description = "Public ALB DNS name"
  value       = aws_lb.chaos.dns_name
}

output "chaos_base_url" {
  description = "Base URL for running remote chaos scenarios"
  value       = "http://${aws_lb.chaos.dns_name}"
}

output "critical_alert_topic_arn" {
  description = "SNS topic ARN for critical alerts"
  value       = aws_sns_topic.critical.arn
}

output "warning_alert_topic_arn" {
  description = "SNS topic ARN for warning alerts"
  value       = aws_sns_topic.warning.arn
}

output "alarm_names" {
  description = "CloudWatch alarm names created for game-day alerting"
  value = [
    aws_cloudwatch_metric_alarm.alb_unhealthy_hosts.alarm_name,
    aws_cloudwatch_metric_alarm.high_5xx_rate.alarm_name,
    aws_cloudwatch_metric_alarm.high_p95_latency.alarm_name,
    aws_cloudwatch_metric_alarm.ecs_high_cpu.alarm_name,
    aws_cloudwatch_metric_alarm.ecs_high_memory.alarm_name
  ]
}
