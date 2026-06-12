terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

resource "aws_ecr_repository" "api" {
  name                 = var.ecr_name
  image_tag_mutability = "IMMUTABLE" # 同一タグの上書きを禁止（CI は commit SHA タグで push）

  image_scanning_configuration {
    scan_on_push = true
  }

  # ephemeral 構成では destroy 時にイメージごと削除できるようにする。
  force_delete = var.ephemeral

  tags = var.tags
}

resource "aws_ecs_cluster" "main" {
  name = var.cluster_name

  # Container Insights を有効化: RunningTaskCount 等の詳細メトリクスを発行する。
  # 無効だと ecs_no_running_tasks アラームがデータ欠損（≒常時 breaching）になる。
  setting {
    name  = "containerInsights"
    value = "enabled"
  }

  tags = var.tags
}

# ── IAM ────────────────────────────────────────────────────────────────────────

resource "aws_iam_role" "task_execution" {
  name = "${var.service_name}-task-execution"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "task_execution" {
  role       = aws_iam_role.task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# Secrets Manager から DB_DSN と INTERNAL_API_KEY を取得するための権限
resource "aws_iam_role_policy" "secrets_access" {
  name = "secrets-access"
  role = aws_iam_role.task_execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["secretsmanager:GetSecretValue"]
      Resource = [var.db_secret_arn, var.api_key_secret_arn]
    }]
  })
}

# ── ネットワーク ────────────────────────────────────────────────────────────────

resource "aws_security_group" "ecs" {
  name        = "${var.service_name}-ecs"
  description = "Allow inbound from ALB only"
  vpc_id      = var.vpc_id

  ingress {
    from_port       = var.container_port
    to_port         = var.container_port
    protocol        = "tcp"
    security_groups = [var.alb_security_group_id]
  }

  # HTTPS 443: ECR イメージ pull・Secrets Manager・CloudWatch Logs への通信。
  # VPC エンドポイントを追加すれば 443 も不要になるがコスト増のため許容。
  egress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "HTTPS outbound (ECR pull, Secrets Manager, CloudWatch Logs)"
  }

  tags = var.tags
}

# ── ログ ───────────────────────────────────────────────────────────────────────

resource "aws_cloudwatch_log_group" "api" {
  name              = "/ecs/${var.service_name}"
  retention_in_days = 30
  tags              = var.tags
}

# ── ECS ───────────────────────────────────────────────────────────────────────

resource "aws_ecs_task_definition" "api" {
  family                   = var.service_name
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = var.cpu
  memory                   = var.memory
  execution_role_arn       = aws_iam_role.task_execution.arn

  container_definitions = jsonencode([
    # 冪等性キー用 Redis（このタスク専有のサイドカー。awsvpc なので api からは localhost で到達）。
    # ElastiCache を使わずコスト最小化。タスク再起動でキーは消えるが TTL 運用なので問題ない。
    {
      name      = "redis"
      image     = "redis:7-alpine"
      essential = false
      command   = ["redis-server", "--save", "", "--appendonly", "no"]
      healthCheck = {
        command     = ["CMD", "redis-cli", "ping"]
        interval    = 10
        timeout     = 3
        retries     = 5
        startPeriod = 10
      }
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.api.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "redis"
        }
      }
    },
    {
      name      = var.service_name
      image     = "${aws_ecr_repository.api.repository_url}:${var.image_tag}"
      essential = true

      portMappings = [{
        containerPort = var.container_port
        protocol      = "tcp"
      }]

      # redis が HEALTHY になってから api を起動（起動時の Ping を成功させる）。
      dependsOn = [{
        containerName = "redis"
        condition     = "HEALTHY"
      }]

      environment = [
        { name = "PORT", value = tostring(var.container_port) },
        { name = "LOG_LEVEL", value = var.log_level },
        { name = "CORS_ORIGINS", value = var.cors_origins },
        { name = "REDIS_ADDR", value = "localhost:6379" },
      ]

      # DB_DSN と INTERNAL_API_KEY は Secrets Manager から取得（平文を環境変数に書かない）
      secrets = [
        { name = "DB_DSN", valueFrom = "${var.db_secret_arn}:dsn::" },
        { name = "INTERNAL_API_KEY", valueFrom = var.api_key_secret_arn },
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.api.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "ecs"
        }
      }

      healthCheck = {
        command     = ["CMD-SHELL", "wget -qO- http://localhost:${var.container_port}/healthz || exit 1"]
        interval    = 30
        timeout     = 5
        retries     = 3
        startPeriod = 60
      }
    }
  ])
}

resource "aws_ecs_service" "api" {
  name            = var.service_name
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.api.arn
  desired_count   = var.desired_count
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = [aws_security_group.ecs.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = var.target_group_arn
    container_name   = var.service_name
    container_port   = var.container_port
  }

  depends_on = [var.alb_listener_arn]

  tags = var.tags
}

# ── 可観測性（CloudWatch アラーム）─────────────────────────────────────────────
# alarm_actions が空なら通知はされず記録のみ（コスト最小）。SNS 等を渡せば通知される。

resource "aws_cloudwatch_metric_alarm" "ecs_cpu_high" {
  alarm_name          = "${var.service_name}-cpu-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "CPUUtilization"
  namespace           = "AWS/ECS"
  period              = 60
  statistic           = "Average"
  threshold           = 80
  alarm_description   = "ECS service CPU utilization is high"
  dimensions = {
    ClusterName = aws_ecs_cluster.main.name
    ServiceName = aws_ecs_service.api.name
  }
  alarm_actions = var.alarm_actions
  ok_actions    = var.alarm_actions
  tags          = var.tags
}

# ephemeral 環境では意図的に down する（タスク 0 が正常）ため、アラームを作らない。
# non-ephemeral（常設）環境でのみ作成し、タスク停止を検知する。
resource "aws_cloudwatch_metric_alarm" "ecs_no_running_tasks" {
  count = var.ephemeral ? 0 : 1

  alarm_name          = "${var.service_name}-no-running-tasks"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 2
  metric_name         = "RunningTaskCount"
  namespace           = "ECS/ContainerInsights"
  period              = 60
  statistic           = "Average"
  threshold           = 1
  alarm_description   = "No running ECS tasks - service may be down"
  dimensions = {
    ClusterName = aws_ecs_cluster.main.name
    ServiceName = aws_ecs_service.api.name
  }
  alarm_actions      = var.alarm_actions
  treat_missing_data = "breaching"
  tags               = var.tags
}
