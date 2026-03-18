variable "aws_region" {
  description = "AWS region for deployment"
  type        = string
  default     = "us-east-1"
}

variable "expected_account_id" {
  description = "Optional safety guardrail: if set, deployment only runs in this AWS account"
  type        = string
  default     = ""
}

variable "project_name" {
  description = "Project name used in resource naming"
  type        = string
  default     = "chaos-game-day"
}

variable "environment" {
  description = "Environment label for resource naming and tags"
  type        = string
  default     = "demo"
}

variable "container_port" {
  description = "Application container port"
  type        = number
  default     = 8080
}

variable "desired_count" {
  description = "Desired ECS service task count"
  type        = number
  default     = 1
}

variable "task_cpu" {
  description = "ECS task CPU units"
  type        = number
  default     = 512
}

variable "task_memory" {
  description = "ECS task memory in MiB"
  type        = number
  default     = 1024
}

variable "target_deregistration_delay_seconds" {
  description = "ALB target deregistration delay in seconds. Lower values speed up ECS replacement and destroy cycles."
  type        = number
  default     = 15
}

variable "ecs_force_delete" {
  description = "When true, ECS service deletion uses force mode to speed up tear-down."
  type        = bool
  default     = true
}

variable "image_uri" {
  description = "Full container image URI in ECR (set by deploy script)"
  type        = string
  default     = ""
}

variable "high_5xx_error_rate_threshold" {
  description = "5xx alarm threshold as a ratio (0.20 = 20%)"
  type        = number
  default     = 0.20
}

variable "latency_p95_alarm_seconds" {
  description = "Alarm threshold for p95 latency in seconds"
  type        = number
  default     = 1
}

variable "primary_oncall_email" {
  description = "Optional email endpoint for critical alerts"
  type        = string
  default     = ""
}

variable "secondary_oncall_email" {
  description = "Optional email endpoint for warning alerts"
  type        = string
  default     = ""
}
