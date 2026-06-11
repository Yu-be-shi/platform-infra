variable "aws_region" {
  type    = string
  default = "ap-northeast-1"
}

variable "alert_email" {
  description = "予算超過・アラーム通知の送信先メールアドレス"
  type        = string
}

variable "monthly_budget_usd" {
  description = "月次コスト予算（USD）。これを超えそうになると通知される"
  type        = string
  default     = "10"
}

variable "github_repo" {
  description = "GitHub Actions OIDC が assume するリポジトリ（例: Yu-be-shi/ys-infrastructure）"
  type        = string
}
