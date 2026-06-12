# S3 バックエンドの接続情報は CI から -backend-config で渡す（リポジトリにハードコードしない）。
# prod-switch.yml は TF_STATE_BUCKET / TF_LOCK_TABLE / AWS_REGION を Variables として管理する。
#
# 初回セットアップ（ローカル）:
#   terraform init \
#     -backend-config="bucket=<your-state-bucket>" \
#     -backend-config="key=ys-infrastructure/prod/terraform.tfstate" \
#     -backend-config="region=ap-northeast-1" \
#     -backend-config="encrypt=true" \
#     -backend-config="dynamodb_table=<your-lock-table>"
terraform {
  backend "s3" {
    key     = "ys-infrastructure/prod/terraform.tfstate"
    encrypt = true
  }
}
