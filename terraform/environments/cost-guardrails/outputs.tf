output "sns_topic_arn" {
  description = "アラート通知用 SNS トピック ARN。本番 up 時の TF_VAR_alarm_actions に渡す"
  value       = aws_sns_topic.alerts.arn
}

output "github_actions_role_arn" {
  description = "GitHub Actions OIDC ロール ARN。リポジトリ変数 AWS_ROLE_ARN に設定する"
  value       = aws_iam_role.github_actions.arn
}
