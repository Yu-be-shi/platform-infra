variable "aws_region" {
  type    = string
  default = "ap-northeast-1"
}

variable "image_tag" {
  description = "デプロイする Docker イメージのタグ（CI から渡す）"
  type        = string
  default     = "latest"
}

# VPC / subnet / DB secret / RDS SG は中央が module.network・module.db で provision するため
# 外部変数を廃止（旧 db-infra/api-infra 間の手動受け渡しは不要になった）。

variable "api_key_secret_arn" {
  description = "INTERNAL_API_KEY の Secrets Manager ARN（値は平文管理しないため別途作成して ARN を設定）"
  type        = string
}

variable "cors_origins" {
  description = "CORS 許可オリジン（カンマ区切り）。空文字の場合 API は全オリジンを拒否する。本番では具体的なオリジンを vars.CORS_ORIGINS に設定すること（'*' は非推奨）"
  type        = string
  default     = ""
}

variable "ephemeral" {
  description = "使い捨て(up/down)環境か。true で destroy 容易な設定（削除保護無効・final snapshot 無し・ECR force_delete 等）になる"
  type        = bool
  default     = true
}

variable "alarm_actions" {
  description = "CloudWatch アラーム通知先 ARN（SNS 等）。空なら記録のみ"
  type        = list(string)
  default     = []
}
