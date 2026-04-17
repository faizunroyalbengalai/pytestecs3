terraform {
  backend "s3" {
    encrypt = true
    # bucket and region passed via -backend-config at init time
  }
}

provider "aws" {
  region = var.aws_region
}

variable "aws_region" {
  default = "us-east-1"
}

variable "project_name" {}

variable "container_image" {
  description = "Full image URI (registry/name:tag) — must be set, never falls back to a placeholder"
  # No default: if TF_VAR_container_image is not set, Terraform will error loudly instead of
  # silently deploying nginx:latest and causing a 502
}

variable "app_port" {
  type    = number
  default = 8000
}

variable "health_check_path" {
  default = "/"
}

# ── Optional secrets injected into ECS task environment ───────────────────────
# All default to "" — only non-empty values are passed into the container
variable "database_url" {
  type      = string
  default   = ""
  sensitive = true
}
variable "db_host" {
  type    = string
  default = ""
}
variable "db_port" {
  type    = string
  default = ""
}
variable "db_name" {
  type    = string
  default = ""
}
variable "db_username" {
  type    = string
  default = ""
}
variable "db_password" {
  type      = string
  default   = ""
  sensitive = true
}
variable "mongo_uri" {
  type      = string
  default   = ""
  sensitive = true
}
variable "redis_url" {
  type      = string
  default   = ""
  sensitive = true
}
variable "secret_key" {
  type      = string
  default   = ""
  sensitive = true
}
variable "jwt_secret" {
  type      = string
  default   = ""
  sensitive = true
}
variable "spring_datasource_url" {
  type      = string
  default   = ""
  sensitive = true
}
variable "spring_datasource_user" {
  type    = string
  default = ""
}
variable "spring_datasource_pass" {
  type      = string
  default   = ""
  sensitive = true
}
variable "spring_mongodb_uri" {
  type      = string
  default   = ""
  sensitive = true
}


locals {
  # ECR names must be lowercase alphanumeric and hyphens only
  ecr_name = lower(replace(replace(var.project_name, "_", "-"), " ", "-"))

  # AWS resource names are limited: ALB=32, TG=32 chars (must not end in -)
  # Truncate to 24 chars to leave room for suffixes like "-alb", "-tg", "-sg"
  name_safe = trimsuffix(substr(replace(var.project_name, "_", "-"), 0, 24), "-")

  # Build ECS task environment from non-empty secrets only
  _all_env = [
    { name = "PORT",    value = tostring(var.app_port) },
    { name = "APP_ENV", value = "production" },
    { name = "DATABASE_URL",              value = var.database_url },
    { name = "DB_HOST",                   value = var.db_host },
    { name = "DB_PORT",                   value = var.db_port },
    { name = "DB_NAME",                   value = var.db_name },
    { name = "DB_USER",                   value = var.db_username },
    { name = "DB_PASSWORD",               value = var.db_password },
    { name = "MONGO_URI",                 value = var.mongo_uri },
    { name = "REDIS_URL",                 value = var.redis_url },
    { name = "SECRET_KEY",               value = var.secret_key },
    { name = "JWT_SECRET",               value = var.jwt_secret },
    { name = "SPRING_DATASOURCE_URL",     value = var.spring_datasource_url },
    { name = "SPRING_DATASOURCE_USERNAME",value = var.spring_datasource_user },
    { name = "SPRING_DATASOURCE_PASSWORD",value = var.spring_datasource_pass },
    { name = "SPRING_DATA_MONGODB_URI",   value = var.spring_mongodb_uri },
  ]
  # Only inject env vars that have a value — avoids empty strings in container
  task_environment = [for e in local._all_env : e if e.value != ""]
}

# ── ECR ────────────────────────────────────────────────────────────────────────
# ECR repo is created by the CI workflow before Terraform runs.
# We reference it here as a data source — Terraform never tries to create it,
# so RepositoryAlreadyExistsException can never happen.
data "aws_ecr_repository" "app" {
  name = local.ecr_name
}

# ── ECS Cluster ────────────────────────────────────────────────────────────────
resource "aws_ecs_cluster" "main" {
  name = "${local.name_safe}-cluster"
}

# ── Networking (default VPC) ───────────────────────────────────────────────────
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# ── Security Groups ────────────────────────────────────────────────────────────
resource "aws_security_group" "alb" {
  name   = "${local.name_safe}-alb-sg"
  vpc_id = data.aws_vpc.default.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  lifecycle { create_before_destroy = true }
}

resource "aws_security_group" "ecs_tasks" {
  name   = "${local.name_safe}-ecs-sg"
  vpc_id = data.aws_vpc.default.id

  # Allow traffic from ALB on the app port
  ingress {
    from_port       = var.app_port
    to_port         = var.app_port
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  # Allow all outbound (needed to pull images, reach DBs, etc.)
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  lifecycle { create_before_destroy = true }
}


# ── ALB ────────────────────────────────────────────────────────────────────────
resource "aws_lb" "main" {
  name               = "${local.name_safe}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = data.aws_subnets.default.ids

  lifecycle { create_before_destroy = true }
}

resource "aws_lb_target_group" "app" {
  name                 = "${local.name_safe}-tg"
  port                 = var.app_port
  protocol             = "HTTP"
  vpc_id               = data.aws_vpc.default.id
  target_type          = "ip"
  deregistration_delay = 30  # Faster rolling deploys

  health_check {
    path                = var.health_check_path
    matcher             = "200-499"   # Accept redirects and even 404 — container is alive
    healthy_threshold   = 2
    unhealthy_threshold = 3
    interval            = 15
    timeout             = 10
  }

  lifecycle { create_before_destroy = true }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}

# ── IAM ────────────────────────────────────────────────────────────────────────
resource "aws_iam_role" "ecs_task_execution" {
  name = "${local.name_safe}-ecs-exec-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ecs_task_execution" {
  role       = aws_iam_role.ecs_task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# ── CloudWatch Logs ────────────────────────────────────────────────────────────
resource "aws_cloudwatch_log_group" "app" {
  name              = "/ecs/${var.project_name}"
  retention_in_days = 7
}

# ── Task Definition ────────────────────────────────────────────────────────────
resource "aws_ecs_task_definition" "app" {
  family                   = var.project_name
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.ecs_task_execution.arn

  container_definitions = jsonencode([{
    name      = var.project_name
    image     = var.container_image
    essential = true

    portMappings = [{
      containerPort = var.app_port
      protocol      = "tcp"
    }]

    environment = local.task_environment

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = "/ecs/${var.project_name}"
        "awslogs-region"        = var.aws_region
        "awslogs-stream-prefix" = "ecs"
      }
    }
  }])
}

# ── ECS Service ────────────────────────────────────────────────────────────────
resource "aws_ecs_service" "app" {
  name            = "${local.name_safe}-service"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.app.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  # Grace period: give the container time to start before health checks count
  health_check_grace_period_seconds = 300

  network_configuration {
    subnets          = data.aws_subnets.default.ids
    security_groups  = [aws_security_group.ecs_tasks.id]
    assign_public_ip = true
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.app.arn
    container_name   = var.project_name
    container_port   = var.app_port
  }

  # Allow updating task definition without destroying the service
  lifecycle {
    ignore_changes = [task_definition]
  }

  depends_on = [aws_lb_listener.http, aws_iam_role_policy_attachment.ecs_task_execution]
}

# ── Outputs ────────────────────────────────────────────────────────────────────
output "alb_dns_name" {
  value = aws_lb.main.dns_name
}

output "alb_url" {
  value = "http://${aws_lb.main.dns_name}"
}

output "ecr_repository_url" {
  value = data.aws_ecr_repository.app.repository_url
}

output "ecs_cluster_name" {
  value = aws_ecs_cluster.main.name
}

output "ecs_service_name" {
  value = aws_ecs_service.app.name
}
