provider "aws" {
  region = var.aws_region
}

locals {
  tags = {
    Environment = "prod"
    Project     = "character-system"
    ManagedBy   = "terraform"
  }
}

# 中央が所有するネットワーク（VPC + NAT + public/private subnet）。
module "network" {
  source = "../../modules/network"
  name   = "character-platform-prod"
  tags   = local.tags
}

# キャラクター DB（PostgreSQL）+ 認証情報 Secrets。
# ingress は循環回避のため下の standalone ルールで付与する（allowed_security_group_ids は空）。
module "db" {
  source = "../../modules/db"

  identifier                 = "character-db-prod"
  db_name                    = "characters"
  db_username                = "app"
  instance_class             = "db.t3.micro"
  allocated_storage          = 20
  vpc_id                     = module.network.vpc_id
  private_subnet_ids         = module.network.private_subnet_ids
  allowed_security_group_ids = []
  ephemeral                  = var.ephemeral

  tags = local.tags
}

# マイグレーション実行タスク（atlas apply → views → seeds）。
# RDS SG への ingress は migrate モジュール自身が standalone ルールで付与する。
module "migrate" {
  source = "../../modules/migrate"

  aws_region            = var.aws_region
  vpc_id                = module.network.vpc_id
  private_subnet_ids    = module.network.private_subnet_ids
  db_secret_arn         = module.db.secret_arn
  rds_security_group_id = module.db.security_group_id

  tags = local.tags
}

# ALB（パブリックサブネット）。
module "alb" {
  source = "../../modules/alb"

  name              = "character-api-prod"
  vpc_id            = module.network.vpc_id
  public_subnet_ids = module.network.public_subnet_ids
  target_port       = 8080

  tags = local.tags
}

# キャラクター API（ECS Fargate, プライベートサブネット）。
module "ecs" {
  source = "../../modules/ecs"

  service_name          = "character-api"
  cluster_name          = "character-api-prod"
  ecr_name              = "character-api"
  image_tag             = var.image_tag
  aws_region            = var.aws_region
  vpc_id                = module.network.vpc_id
  private_subnet_ids    = module.network.private_subnet_ids
  alb_security_group_id = module.alb.security_group_id
  target_group_arn      = module.alb.target_group_arn
  alb_listener_arn      = module.alb.listener_arn

  # 同一 state なのでモジュール output を直接参照（旧来の手動受け渡しを廃止）。
  db_secret_arn         = module.db.secret_arn
  rds_security_group_id = module.db.security_group_id
  api_key_secret_arn    = var.api_key_secret_arn

  cors_origins  = var.cors_origins
  ephemeral     = var.ephemeral
  alarm_actions = var.alarm_actions

  tags = local.tags
}

# API(ECS) → RDS の ingress。単一 state での SG 循環を避けるため standalone ルールで付与する
# （db モジュールは ECS を知らず、ECS は db.secret/sg を参照するだけ＝DAG になる）。
resource "aws_security_group_rule" "rds_allow_api" {
  type                     = "ingress"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  source_security_group_id = module.ecs.ecs_security_group_id
  security_group_id        = module.db.security_group_id
  description              = "Allow character-api ECS task to access RDS"
}
