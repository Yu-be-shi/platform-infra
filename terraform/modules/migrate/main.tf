terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.54"
    }
  }
}

# ── ECR ───────────────────────────────────────────────────────────────────────

resource "aws_ecr_repository" "migrate" {
  name                 = var.name
  image_tag_mutability = "IMMUTABLE" # CI は commit SHA タグで push するため上書き不要

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = var.tags
}

# ── IAM ───────────────────────────────────────────────────────────────────────

resource "aws_iam_role" "migrate_execution" {
  name = "${var.name}-execution"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "migrate_execution" {
  role       = aws_iam_role.migrate_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role_policy" "migrate_secrets" {
  name = "secrets-access"
  role = aws_iam_role.migrate_execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["secretsmanager:GetSecretValue"]
      Resource = [var.db_secret_arn]
    }]
  })
}

# ── ネットワーク ────────────────────────────────────────────────────────────────

# マイグレーションタスク専用 SG
resource "aws_security_group" "migrate" {
  name        = "${var.name}-task"
  description = "Migration ECS task - egress to RDS and HTTPS only"
  vpc_id      = var.vpc_id

  # HTTPS 443: ECR イメージ pull・Secrets Manager・CloudWatch Logs への通信。
  egress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "HTTPS outbound (ECR pull, Secrets Manager, CloudWatch Logs)"
  }
  # PostgreSQL: RDS への接続（SG ルールは rds_allow_migrate で RDS SG 側にも追加）。
  egress {
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "PostgreSQL outbound to RDS (within VPC)"
  }

  tags = var.tags
}

# RDS SG にマイグレーション SG からの ingress を追加
resource "aws_security_group_rule" "rds_allow_migrate" {
  type                     = "ingress"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.migrate.id
  security_group_id        = var.rds_security_group_id
  description              = "Allow migration ECS task to access RDS"
}

# ── ログ ───────────────────────────────────────────────────────────────────────

resource "aws_cloudwatch_log_group" "migrate" {
  name              = "/ecs/${var.name}"
  retention_in_days = 14
  tags              = var.tags
}

# ── ECS タスク定義 ─────────────────────────────────────────────────────────────

resource "aws_ecs_task_definition" "migrate" {
  family                   = var.name
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = 256
  memory                   = 512
  execution_role_arn       = aws_iam_role.migrate_execution.arn

  container_definitions = jsonencode([{
    name  = "migrate"
    image = "${aws_ecr_repository.migrate.repository_url}:${var.image_tag}"

    # ECS exec 形式の command では $(VAR) のシェル展開が行われない。
    # --url=$(DB_DSN) をリテラルで atlas に渡すと接続失敗する。
    # migrate-entrypoint.sh は引数 --url= が存在しない場合に DB_DSN 環境変数へ
    # フォールバックする（entrypoint.sh:21-24）ため、command を空にして env 注入に委ねる。
    command = []

    secrets = [
      { name = "DB_DSN", valueFrom = "${var.db_secret_arn}:dsn::" }
    ]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.migrate.name
        "awslogs-region"        = var.aws_region
        "awslogs-stream-prefix" = "ecs"
      }
    }
  }])

  tags = var.tags
}
