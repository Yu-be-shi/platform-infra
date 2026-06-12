# ys-infrastructure

character-system の中央インフラリポジトリ。character-api（Go）の実行基盤と、ローカル開発用
compose スタックを管理する。**アプリ・API はインフラを知らない。インフラはサービスの成果物
（Dockerfile / schema）だけを参照する**（一方向依存）。

## 責務

| 対象 | 管理内容 |
|---|---|
| ローカル compose | PostgreSQL + migrate(atlas/views/seeds) + Go API + Redis（`character-db-net` 作成） |
| AWS Terraform | network(VPC/subnet) / RDS(PostgreSQL) / migrate(ECS task) / ALB / ECS Fargate / ECR / Secrets Manager / cost-guardrails |
| デプロイ CI | `prod-switch.yml`（AWS ephemeral up/down）/ `deploy-stg.yml`（自宅 STG） |

インフラは **単一 state**（`terraform/environments/prod`）で上記 AWS リソース全体を1回の
`terraform apply` で構築する。旧来の「DB インフラ → API インフラ」2段 apply・VPC/subnet の手動
受け渡しは廃止済み（`module.network` が自前 provision）。

---

## リポジトリレイアウト

```
ys-infrastructure/
├── docker-compose.yml            # 基盤スタック（character-db-net を作成）
├── migrate-entrypoint.sh         # migrate: atlas apply → views → seeds
├── terraform/
│   ├── environments/
│   │   ├── prod/                 # 本番（AWS 単一 state）
│   │   │   ├── backend.tf        # S3 backend（CI 注入、プレースホルダなし）
│   │   │   ├── main.tf           # module 呼び出し・SG standalone ルール
│   │   │   ├── variables.tf      # cors_origins / api_key_secret_arn 等
│   │   │   └── outputs.tf
│   │   ├── stg/                  # STG（compose ベース、Terraform 非使用）
│   │   └── cost-guardrails/      # 別 state（Budget / SNS アラート）
│   └── modules/
│       ├── network/              # VPC / public+private subnet / NAT
│       ├── db/                   # RDS PostgreSQL / Secrets Manager（DSN）
│       ├── migrate/              # ECR(migrate) / ECS タスク定義 / SG
│       ├── alb/                  # ALB / target group / HTTP リスナー
│       ├── ecs/                  # ECR(api) / ECS cluster+service / CloudWatch アラーム
│       └── cost-guardrails/      # Budget / SNS topic（単独 module）
└── .github/workflows/
    ├── prod-switch.yml           # 本番 ephemeral up/down（手動+夜間自動）
    ├── deploy-stg.yml            # STG compose デプロイ（staging push）
    ├── deploy.yml                # Infra CI（terraform fmt/validate、PR 時）
    └── security.yml              # gitleaks + trivy(IaC)
```

---

## ローカル起動

```bash
# 基盤スタック（PostgreSQL → migrate(atlas→views→seeds) → API → Redis）
# character-db-net を作成し、アプリ compose が external で参加できるようにする。
docker compose up -d --build

# または メタリポジトリ直下で:
# make up
```

アプリ（Next.js + MySQL）は `character-application-nextjs` の compose で別途起動する。

完全リセット（DB ボリューム含む）:

```bash
docker compose down -v
```

マイグレーションのみ再実行（migrations / views / seeds をイメージに反映して再適用）:

```bash
docker compose run --rm --build character-db-migrate
```

---

## 本番スイッチ（AWS ephemeral）

使う時だけ立てて普段は完全に消す「使い捨て本番」。

- **up**: `workflow_dispatch` → `terraform apply`（単一 state で一括構築）→
  イメージ build/push → `ECS run-task` で migrate 実行 → ECS 再デプロイ → `/healthz` スモーク
- **down**: 手動 or 毎日 03:00 JST（夜間自動）→ `terraform destroy`（一括削除）
  失敗時は `vars.DOWN_ALERT_SNS_ARN` の SNS topic に通知

```
[up]
 1) terraform apply（単一 state）
    … network(VPC+NAT) / RDS / Secrets / migrate タスク定義 / ALB / ECS を一括構築
    … API↔RDS の SG 相互参照は standalone ルール（prod/main.tf）で循環回避
 2) イメージ build & push
    … api / migrate（ビルド元: ys-character-api, タグ: commit SHA, 全 ECR は IMMUTABLE）
 3) migrate 実行（ECS run-task）
    … atlas migrate apply → views/*.sql → seeds/*.sql（終了コード検証、失敗で abort）
 4) ECS 再デプロイ → ALB /healthz スモークテスト（最大 200 秒ポーリング）

[down]（手動 / 毎日 18:00 UTC = 03:00 JST）
 terraform destroy（単一 state 一括削除）
 API キー Secret は switch 外（恒久）なので残る
 失敗時 SNS 通知（vars.DOWN_ALERT_SNS_ARN 設定時）
```

- データは永続させない（`ephemeral=true`: RDS 削除保護なし / final snapshot 無し / ECR force_delete）。
- DB 認証情報は Secrets Manager から ECS タスクへ `valueFrom` 注入（平文コードなし）。
- up のたびに seeds で初期データ（races 等）を再投入する。
- HTTPS はドメイン未取得のため保留（`modules/alb` は ACM ARN 変数追加で対応可能）。

---

## STG（自宅サーバー）

`staging` ブランチへの push（または手動 `workflow_dispatch`）で、自宅 WSL の
self-hosted runner（ラベル `character-stg`）が `$STG_ROOT` を最新化し
`docker compose up -d --build` を実行。起動後 `/healthz` スモークテスト。

一度きりセットアップ: `$STG_ROOT` 配下に `character-system/` のレイアウトでリポジトリを clone
→ GitHub に `character-stg` ラベルで self-hosted runner を登録 → 各 `.env` を配置。

---

## GitHub Actions に設定する Secrets / Variables

### Secrets（`settings/secrets/actions`）

| 名前 | 説明 |
|---|---|
| `AWS_ACCESS_KEY_ID` | AWS 認証（OIDC 移行後は不要。下記参照） |
| `AWS_SECRET_ACCESS_KEY` | AWS 認証（同上） |
| `GH_PAT` | `ys-character-api` を checkout する PAT（repo 読み取り） |
| `TF_VAR_API_KEY_SECRET_ARN` | `INTERNAL_API_KEY` の Secrets Manager ARN（永続・switch 外で作成） |

### Variables（`settings/variables/actions`）

| 名前 | 説明 |
|---|---|
| `AWS_REGION` | AWS リージョン（省略時 `ap-northeast-1`） |
| `AWS_DEPLOY_ROLE_ARN` | OIDC で assume する IAM ロール ARN（未設定時は長期キーで動作） |
| `CORS_ORIGINS` | CORS 許可オリジン（カンマ区切り。**未設定時は空=API 全拒否**。本番では具体的に設定） |
| `TF_STATE_BUCKET` | Terraform state 用 S3 バケット名 |
| `TF_LOCK_TABLE` | state ロック用 DynamoDB テーブル名（省略可） |
| `DOWN_ALERT_SNS_ARN` | down 失敗時に通知する SNS topic ARN（省略可。cost-guardrails の topic ARN 推奨） |

### OIDC 化（長期キーからの移行手順）

長期キーを廃止して GitHub OIDC に移行する（**長期キーは OIDC 成功確認後に削除**）。

1. `cost-guardrails/main.tf` に IAM OIDC provider と deploy ロールを追加（または手動作成）:
   - OIDC provider: `token.actions.githubusercontent.com`
   - trust の `sub` を `repo:<owner>/ys-infrastructure:environment:production` に限定
   - ポリシー: `AdministratorAccess`（または必要最小限 Terraform 権限）
2. ロール ARN を `vars.AWS_DEPLOY_ROLE_ARN` に設定
3. prod-switch.yml は `AWS_DEPLOY_ROLE_ARN` があれば OIDC で assume、なければ長期キーで動作（後方互換）
4. OIDC で up/down が 1 サイクル成功したら長期キー Secret を削除

---

## セキュリティ境界

- ECS タスクはプライベートサブネット配置、ALB 経由でのみ公開
- SG egress: RDS は egress なし、ECS/migrate は HTTPS 443 のみ（+migrate は PostgreSQL 5432）
- DB 接続情報は Secrets Manager から ECS タスクへ `valueFrom` 注入（タスク定義・変数に平文なし）
- `INTERNAL_API_KEY` も Secrets Manager から注入（`TF_VAR_API_KEY_SECRET_ARN`）
- Container Insights 有効化（ECS `RunningTaskCount` メトリクス発行）
- cost-guardrails（別 state）: Budget アラート + SNS topic は恒久リソース（destroy 後も残る）
