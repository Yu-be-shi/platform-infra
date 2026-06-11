output "api_endpoint" {
  description = "API の公開エンドポイント"
  value       = "http://${module.alb.dns_name}"
}

output "ecr_repository_url" {
  description = "API イメージの push 先（CI の AWS_ECR_REPOSITORY に設定する）"
  value       = module.ecs.ecr_repository_url
}

output "ecs_cluster_name" {
  description = "CI の ECS_CLUSTER に設定する"
  value       = module.ecs.ecs_cluster_name
}

output "ecs_service_name" {
  description = "CI の ECS_SERVICE に設定する"
  value       = module.ecs.ecs_service_name
}

output "migrate_ecr_repository_url" {
  description = "マイグレーションイメージの push 先（CI）"
  value       = module.migrate.ecr_repository_url
}

output "migrate_security_group_id" {
  description = "マイグレーション ECS タスク実行時に使う SG（CI の MIGRATION_SG_ID）"
  value       = module.migrate.security_group_id
}

output "db_secret_arn" {
  description = "DB 認証情報の Secrets Manager ARN（参考・同一 state 内で完結）"
  value       = module.db.secret_arn
}

output "vpc_id" {
  value = module.network.vpc_id
}

output "private_subnet_ids" {
  description = "マイグレーション ECS タスク実行時に使う private subnet（CI の MIGRATION_SUBNETS）"
  value       = module.network.private_subnet_ids
}
