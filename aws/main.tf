data "aws_caller_identity" "current" {}

data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

locals {
  name_prefix = "${var.project_name}-${var.environment}"
}

resource "terraform_data" "account_guardrail" {
  input = data.aws_caller_identity.current.account_id

  lifecycle {
    precondition {
      condition     = length(trimspace(var.expected_account_id)) == 0 || data.aws_caller_identity.current.account_id == var.expected_account_id
      error_message = "Authenticated account is ${data.aws_caller_identity.current.account_id}; expected ${var.expected_account_id}. Switch credentials before applying."
    }
  }
}

resource "aws_ecr_repository" "chaos_api" {
  name                 = "${local.name_prefix}-chaos-api"
  image_tag_mutability = "MUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }
}

data "aws_iam_policy_document" "ecs_task_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ecs_execution" {
  name               = "${local.name_prefix}-ecs-execution-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_task_assume_role.json
}

resource "aws_iam_role_policy_attachment" "ecs_execution_policy" {
  role       = aws_iam_role.ecs_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_cloudwatch_log_group" "ecs_app" {
  name              = "/ecs/${local.name_prefix}/chaos-api"
  retention_in_days = 14
}

resource "aws_ecs_cluster" "chaos" {
  name = "${local.name_prefix}-cluster"
}

resource "aws_security_group" "alb" {
  name        = "${local.name_prefix}-alb-sg"
  description = "ALB security group for chaos API"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "Allow HTTP from internet"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "ecs_service" {
  name        = "${local.name_prefix}-ecs-sg"
  description = "ECS service security group for chaos API"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description     = "Allow traffic only from ALB"
    from_port       = var.container_port
    to_port         = var.container_port
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_lb" "chaos" {
  name               = substr("${local.name_prefix}-alb", 0, 32)
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = data.aws_subnets.default.ids
}

resource "aws_lb_target_group" "chaos_api" {
  name        = substr("${local.name_prefix}-tg", 0, 32)
  port        = var.container_port
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = data.aws_vpc.default.id
  # Smaller drain time speeds up ECS replacement and environment tear-down.
  deregistration_delay = tostring(var.target_deregistration_delay_seconds)

  health_check {
    enabled             = true
    interval            = 15
    path                = "/healthz"
    protocol            = "HTTP"
    matcher             = "200-399"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 5
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.chaos.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.chaos_api.arn
  }
}

resource "aws_ecs_task_definition" "chaos_api" {
  family                   = "${local.name_prefix}-chaos-api"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.task_cpu
  memory                   = var.task_memory
  execution_role_arn       = aws_iam_role.ecs_execution.arn

  container_definitions = jsonencode([
    {
      name      = "chaos-api"
      image     = var.image_uri
      essential = true

      portMappings = [
        {
          containerPort = var.container_port
          hostPort      = var.container_port
          protocol      = "tcp"
        }
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.ecs_app.name
          awslogs-region        = var.aws_region
          awslogs-stream-prefix = "ecs"
        }
      }
    }
  ])

  depends_on = [aws_iam_role_policy_attachment.ecs_execution_policy]

  lifecycle {
    precondition {
      condition     = length(trimspace(var.image_uri)) > 0
      error_message = "image_uri must be set. Use scripts/deploy_to_aws.sh to build, push, and apply with a real ECR image URI."
    }
  }
}

resource "aws_ecs_service" "chaos_api" {
  name            = "${local.name_prefix}-chaos-api"
  cluster         = aws_ecs_cluster.chaos.id
  task_definition = aws_ecs_task_definition.chaos_api.arn
  desired_count   = var.desired_count
  launch_type     = "FARGATE"
  force_delete    = var.ecs_force_delete

  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200

  network_configuration {
    subnets          = data.aws_subnets.default.ids
    security_groups  = [aws_security_group.ecs_service.id]
    assign_public_ip = true
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.chaos_api.arn
    container_name   = "chaos-api"
    container_port   = var.container_port
  }

  depends_on = [
    aws_lb_listener.http,
    terraform_data.account_guardrail
  ]
}

resource "aws_sns_topic" "critical" {
  name = "${local.name_prefix}-critical-alerts"
}

resource "aws_sns_topic" "warning" {
  name = "${local.name_prefix}-warning-alerts"
}

resource "aws_sns_topic_subscription" "critical_email" {
  count = length(trimspace(var.primary_oncall_email)) > 0 ? 1 : 0

  topic_arn = aws_sns_topic.critical.arn
  protocol  = "email"
  endpoint  = var.primary_oncall_email
}

resource "aws_sns_topic_subscription" "warning_email" {
  count = length(trimspace(var.secondary_oncall_email)) > 0 ? 1 : 0

  topic_arn = aws_sns_topic.warning.arn
  protocol  = "email"
  endpoint  = var.secondary_oncall_email
}

resource "aws_cloudwatch_metric_alarm" "alb_unhealthy_hosts" {
  alarm_name          = "${local.name_prefix}-alb-unhealthy-hosts"
  alarm_description   = "Critical: ALB target group has unhealthy hosts"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "UnHealthyHostCount"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    LoadBalancer = aws_lb.chaos.arn_suffix
    TargetGroup  = aws_lb_target_group.chaos_api.arn_suffix
  }

  alarm_actions = [aws_sns_topic.critical.arn]
  ok_actions    = [aws_sns_topic.critical.arn]
}

resource "aws_cloudwatch_metric_alarm" "high_5xx_rate" {
  alarm_name          = "${local.name_prefix}-high-5xx-rate"
  alarm_description   = "Critical: target 5xx ratio exceeded threshold"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  threshold           = var.high_5xx_error_rate_threshold
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.critical.arn]
  ok_actions          = [aws_sns_topic.critical.arn]

  metric_query {
    id = "five_xx"

    metric {
      metric_name = "HTTPCode_Target_5XX_Count"
      namespace   = "AWS/ApplicationELB"
      period      = 60
      stat        = "Sum"
      dimensions = {
        LoadBalancer = aws_lb.chaos.arn_suffix
        TargetGroup  = aws_lb_target_group.chaos_api.arn_suffix
      }
    }
  }

  metric_query {
    id = "request_count"

    metric {
      metric_name = "RequestCount"
      namespace   = "AWS/ApplicationELB"
      period      = 60
      stat        = "Sum"
      dimensions = {
        LoadBalancer = aws_lb.chaos.arn_suffix
        TargetGroup  = aws_lb_target_group.chaos_api.arn_suffix
      }
    }
  }

  metric_query {
    id          = "error_rate"
    expression  = "IF(request_count>0, five_xx/request_count, 0)"
    label       = "Target5xxRate"
    return_data = true
  }
}

resource "aws_cloudwatch_metric_alarm" "high_p95_latency" {
  alarm_name          = "${local.name_prefix}-high-p95-latency"
  alarm_description   = "Warning: p95 TargetResponseTime exceeded threshold"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "TargetResponseTime"
  extended_statistic  = "p95"
  period              = 60
  evaluation_periods  = 3
  threshold           = var.latency_p95_alarm_seconds
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    LoadBalancer = aws_lb.chaos.arn_suffix
    TargetGroup  = aws_lb_target_group.chaos_api.arn_suffix
  }

  alarm_actions = [aws_sns_topic.warning.arn]
  ok_actions    = [aws_sns_topic.warning.arn]
}

resource "aws_cloudwatch_metric_alarm" "ecs_high_cpu" {
  alarm_name          = "${local.name_prefix}-ecs-high-cpu"
  alarm_description   = "Warning: ECS service CPU utilization high"
  namespace           = "AWS/ECS"
  metric_name         = "CPUUtilization"
  statistic           = "Average"
  period              = 60
  evaluation_periods  = 3
  threshold           = 80
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    ClusterName = aws_ecs_cluster.chaos.name
    ServiceName = aws_ecs_service.chaos_api.name
  }

  alarm_actions = [aws_sns_topic.warning.arn]
  ok_actions    = [aws_sns_topic.warning.arn]
}

resource "aws_cloudwatch_metric_alarm" "ecs_high_memory" {
  alarm_name          = "${local.name_prefix}-ecs-high-memory"
  alarm_description   = "Warning: ECS service memory utilization high"
  namespace           = "AWS/ECS"
  metric_name         = "MemoryUtilization"
  statistic           = "Average"
  period              = 60
  evaluation_periods  = 3
  threshold           = 80
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    ClusterName = aws_ecs_cluster.chaos.name
    ServiceName = aws_ecs_service.chaos_api.name
  }

  alarm_actions = [aws_sns_topic.warning.arn]
  ok_actions    = [aws_sns_topic.warning.arn]
}
