# コスト・監視のガードレール（恒久リソース）。
# ephemeral な本番 up/down とは別 state で一度だけ apply する。環境を down しても
# 「消し忘れ・想定外課金」を検知できるよう、これは destroy しない。
#
# 出力の sns_topic_arn を、本番 up 時の TF_VAR_alarm_actions（CloudWatch アラームの通知先）に渡す。
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# アラート通知用 SNS トピック（CloudWatch アラーム・Budgets 共通の通知先）。
resource "aws_sns_topic" "alerts" {
  name = "character-system-alerts"
}

resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# AWS Budgets が SNS に publish できるようトピックポリシーを許可する。
data "aws_iam_policy_document" "sns_publish" {
  statement {
    sid     = "AllowBudgetsPublish"
    effect  = "Allow"
    actions = ["SNS:Publish"]
    principals {
      type        = "Service"
      identifiers = ["budgets.amazonaws.com"]
    }
    resources = [aws_sns_topic.alerts.arn]
  }
}

resource "aws_sns_topic_policy" "alerts" {
  arn    = aws_sns_topic.alerts.arn
  policy = data.aws_iam_policy_document.sns_publish.json
}

# ── GitHub Actions OIDC ─────────────────────────────────────────────────────
# GitHub Actions が AssumeRoleWithWebIdentity で一時認証情報を取得できるようにする。
# 長期アクセスキー（AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY）を廃止し OIDC に移行する。
# この OIDC プロバイダーとロールは恒久リソースとして cost-guardrails で管理する
# （prod スタックは ephemeral のため、ここに置かないと down のたびに消えてしまう）。

data "aws_iam_policy_document" "github_actions_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_repo}:*"]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
  # GitHub の OIDC サムプリントは複数あり変更される。AWS は IAM の自動サムプリント更新で
  # 管理するため、ダミー値（64 文字の "0"×40）をプレースホルダとして置く。
  # https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles_providers_create_oidc_verify-thumbprint.html
  thumbprint_list = ["0000000000000000000000000000000000000000"]
}

resource "aws_iam_role" "github_actions" {
  name               = "github-actions-prod-deploy"
  assume_role_policy = data.aws_iam_policy_document.github_actions_assume.json
  description        = "GitHub Actions が prod-switch.yml で使用する OIDC ロール"
}

# 本番 ephemeral 構築/削除に必要な権限。個人プロジェクトのため AdministratorAccess を使用。
# スコープを絞る場合は EC2・ECS・RDS・IAM・CloudWatch・S3・Secrets Manager・ECR の
# 必要アクションに限定した Policy を inline で定義する。
resource "aws_iam_role_policy_attachment" "github_actions_admin" {
  role       = aws_iam_role.github_actions.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

# 月次コスト予算。実コストが閾値%を超えたら通知、予測が 100% 超でも通知。
resource "aws_budgets_budget" "monthly" {
  name         = "character-system-monthly"
  budget_type  = "COST"
  limit_amount = var.monthly_budget_usd
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_sns_topic_arns  = [aws_sns_topic.alerts.arn]
    subscriber_email_addresses = [var.alert_email]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [var.alert_email]
  }
}
