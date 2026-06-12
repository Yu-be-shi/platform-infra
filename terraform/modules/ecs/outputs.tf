output "ecr_repository_url" {
  description = "ECR リポジトリ URL（CI で docker push する際に使用）"
  value       = aws_ecr_repository.api.repository_url
}

output "ecs_cluster_name" {
  description = "ECS クラスター名（CI で ecs update-service する際に使用）"
  value       = aws_ecs_cluster.main.name
}

output "ecs_service_name" {
  description = "ECS サービス名"
  value       = aws_ecs_service.api.name
}

output "ecs_security_group_id" {
  description = "ECS タスクのセキュリティグループ ID（prod/main.tf の standalone SG ルールで RDS へのアクセスを許可）"
  value       = aws_security_group.ecs.id
}
