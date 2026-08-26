# Customer — AWS DevOps Agent 外部 MCP 桥接（terraform-ecs + IAM Roles Anywhere）

本仓库是 Customer 项目的 **AWS DevOps Agent → 中国区账号** MCP 桥接方案的完整部署记录与可复现代码，
基于上游方案 [warren830/aws-devops-agent-external-mcp](https://github.com/warren830/aws-devops-agent-external-mcp) 裁剪，
只保留 **ECS Fargate + IAM Roles Anywhere（零 AK/SK）** 路径，并包含实际部署（2026-08-26）中
验证过的全部修复与排障经验。

## 架构

```
AWS DevOps Agent (Agent Space, 全球区)
    │  VPC Lattice Private Connection
    ▼
internal ALB  mcp-alb（us-west-2, <VPC_ID>, HTTPS + host 路由）
    │  host = aws-cn-customer.example.com
    ▼
ECS Fargate  mcp-aws-cn（私有子网, AWS-API-MCP server, streamable-http :8000）
    │  X.509 客户端证书 (credential_process, 自动刷新)
    ▼
IAM Roles Anywhere（cn-northwest-1, Hub 账号 <CN_ACCOUNT_ID>）
    │  Hub 临时凭证 → sts:AssumeRole (ExternalId=mcp-bridge)
    ▼
Spoke Role  mcp-spoke-readonly（aws-cn 分区，两个中国区均可访问）
```

要点：

- **零长期密钥**：容器内没有 AK/SK，凭证由 X.509 证书经 Roles Anywhere 换取，botocore
  `credential_process` 按 `Expiration` 自动刷新（不会出现跑 1 小时后 RequestExpired）。
- **凭证是分区级的**：aws-cn 分区凭证对 `cn-northwest-1` 和 `cn-north-1` 同时有效，
  `accounts.aws_region` 只是默认区域，不是访问范围限制。
- **复用现有 VPC**：`vpc_id` 指定后不创建任何网络资源（IGW/NAT/路由表），只需私有子网
  （须已有 `0.0.0.0/0 → NAT` 路由）。公有子网参数已彻底移除。

## 环境清单（本次部署实际值）

| 项 | 值 |
|---|---|
| 全球区账号 / 区域 | `<GLOBAL_ACCOUNT_ID>` / `us-west-2` |
| 中国区 Hub=Spoke 账号 | `<CN_ACCOUNT_ID>` / `cn-northwest-1` |
| VPC（复用） | `<VPC_ID>`（<VPC_CIDR>） |
| 私有子网 | `<PRIVATE_SUBNET_A>`, `<PRIVATE_SUBNET_B>` |
| 域名 | `aws-cn-customer.example.com` |
| ACM 证书（us-west-2） | `*.example.com` |
| ECS | 集群 `mcp` / 服务 `mcp-aws-cn` |
| Agent Space | `demo-customer`（us-west-2, id `<AGENT_SPACE_ID>`） |

---

## 部署步骤

### Phase 0 — 前置条件

- 全球区账号具备 admin 权限的 CLI profile；中国区账号 profile（如 `cn-nx`）
- 复用 VPC 时确认：私有子网已有 `0.0.0.0/0 → NAT` 路由（Fargate 需出网拉镜像、调中国区 API）

```bash
aws ec2 describe-route-tables \
  --filters "Name=association.subnet-id,Values=<subnet-1>,<subnet-2>" \
  --query 'RouteTables[].Routes' --region us-west-2
```

- ACM 证书**必须与 ALB 同区域**（us-west-2），不能复用其他区域的证书

### Phase 1 — 证书与 Roles Anywhere（中国区，一次性）

```bash
cd cfn
./generate-certs.sh ~/mcp-certs        # 生成 CA + 客户端证书

# Hub 栈（中国区中心账号，cn-northwest-1）
aws cloudformation deploy \
  --template-file roles-anywhere-hub.yaml \
  --stack-name mcp-roles-anywhere-hub \
  --parameter-overrides \
    CACertificateBody="$(cat ~/mcp-certs/ca.crt)" \
    SpokeRoleArns="arn:aws-cn:iam::<CN_ACCOUNT_ID>:role/mcp-spoke-readonly" \
  --capabilities CAPABILITY_NAMED_IAM --region cn-northwest-1 --profile cn-nx

# Spoke 栈（每个目标账号各一次；本项目 Hub 即 Spoke）
aws cloudformation deploy \
  --template-file roles-anywhere-spoke.yaml \
  --stack-name mcp-spoke-role \
  --parameter-overrides HubRoleArn=<Hub 栈输出的 HubRoleArn> \
  --capabilities CAPABILITY_NAMED_IAM --region cn-northwest-1 --profile cn-nx

# 取 trust_anchor_arn / profile_arn / hub_role_arn（填入 tfvars）
aws cloudformation describe-stacks --stack-name mcp-roles-anywhere-hub \
  --region cn-northwest-1 --profile cn-nx \
  --query 'Stacks[0].Outputs' --output table
```

### Phase 2 — Secrets Manager（全球区，**必须与 ECS 任务同区域**）

```bash
aws secretsmanager create-secret --name /mcp/ra-cert \
  --secret-string file://~/mcp-certs/client.crt --region us-west-2
aws secretsmanager create-secret --name /mcp/ra-key \
  --secret-string file://~/mcp-certs/client.key --region us-west-2
```

> 本次部署主密钥先建在了 us-east-1，后用
> `aws secretsmanager replicate-secret-to-regions --secret-id /mcp/ra-cert --add-replica-regions Region=us-west-2 --region us-east-1`
> 复制过来。副本 ARN 与主密钥同名同后缀，仅 region 段不同；副本只读，更新只能在主区域做（自动同步）。

### Phase 3 — Terraform 部署

```bash
cd terraform-ecs
cp terraform.tfvars.customer terraform.tfvars   # 检查每个值
terraform init && terraform apply
```

tfvars 关键项说明见 `terraform.tfvars.customer` 内注释。**最容易填错的是
`accounts.aws-cn.aws_region`：必须是中国区（`cn-northwest-1`），不是部署区域**（见排障 #6）。

### Phase 4 — 构建并推送镜像

```bash
# 必须在仓库根目录执行（构建上下文包含 src/ 与 deploy/）
docker build --platform linux/amd64 \
  -t <GLOBAL_ACCOUNT_ID>.dkr.ecr.us-west-2.amazonaws.com/mcp-aws:latest \
  -f deploy/Dockerfile.ra .

# ECR 登录必须与仓库同区域
aws ecr get-login-password --region us-west-2 | docker login \
  --username AWS --password-stdin <GLOBAL_ACCOUNT_ID>.dkr.ecr.us-west-2.amazonaws.com
docker push <GLOBAL_ACCOUNT_ID>.dkr.ecr.us-west-2.amazonaws.com/mcp-aws:latest

# 让服务拉起新镜像
aws ecs update-service --cluster mcp --service mcp-aws-cn \
  --force-new-deployment --region us-west-2
```

> Roles Anywhere 模式**必须用 `Dockerfile.ra`**（内含 aws_signing_helper 与
> credential-helper.sh）。普通 Dockerfile 构建的镜像拿不到 AWS 凭证。

### Phase 5 — DevOps Agent 注册

1. 控制台创建/复用 Agent Space（本项目：us-west-2 `demo-customer`）。
2. 创建 Private Connection 指向 internal ALB（VPC Lattice Resource Gateway 在 ALB 所在 VPC）。
3. 注册 MCP Server：URL `https://aws-cn-customer.example.com/mcp`；
   Authorization 选 **API Key + 任意 dummy 值**（header `Authorization`）——
   MCP server 是 `AUTH_TYPE=no-auth` 不校验，向导必填而已；安全靠 Private Connection 网络隔离。

### Phase 6 — 验证

```bash
# 任务运行、目标健康
aws ecs describe-services --cluster mcp --services mcp-aws-cn --region us-west-2 \
  --query 'services[0].{running:runningCount,rollout:deployments[0].rolloutState}'

# 凭证链路（应看到两行）
aws logs tail /ecs/mcp-aws-cn --region us-west-2 --since 10m | grep entrypoint-ra
#   [entrypoint-ra] credential_process configured (profile=ra); SDK will fetch + auto-refresh.
#   [entrypoint-ra] Initial credential fetch OK.
```

在 DevOps Agent 里让 agent 调 `cn_list_inventory` 或
`aws ec2 describe-regions --region cn-northwest-1`，返回真实数据即通。

---

## 排障速查（本次部署实际踩过的坑）

| # | 症状 | 根因 | 修复 |
|---|---|---|---|
| 1 | apply 报 `already has an internet gateway attached` | 旧版 network.tf 在复用 VPC 时仍无条件新建 IGW/NAT/路由表 | 已修复：全部网络资源 `count = local.create_vpc ? 1 : 0`；复用模式不动网络（详见 docs/RISK-REPORT-EXISTING-VPC.md） |
| 2 | apply 报 IAM `EntityAlreadyExists`（mcp-ecs-exec 等） | IAM 是全局资源，其他区域/历史部署已建同名角色 | `terraform import` 收编：`terraform import aws_iam_role.task_execution mcp-ecs-exec` 等 7 项（角色×2、策略×2、挂载×3） |
| 3 | 建 listener 报 `Certificate ARN ... is not valid` | ACM 证书是区域资源，填了别的区域的证书 | 在 ALB 同区域申请/找到证书，更新 `certificate_arn` |
| 4 | 任务反复 `CannotPullContainerError` | 镜像没推，或推到了别的区域的 ECR | 构建推送到部署区域 ECR 后 `--force-new-deployment` |
| 5 | 任务 `ResourceInitializationError`（拉 secret 失败） | ECS 引用的 Secrets Manager 密钥必须与任务同区域 | `replicate-secret-to-regions` 到部署区域，tfvars 换副本 ARN |
| 6 | 所有中国区 API 调用报 `UnrecognizedClientException: The security token included in the request is invalid`（MCP 本身可达、工具可调） | `accounts.aws_region` 误填全球区域 → 中国分区凭证被发往全球分区 endpoint | 改为 `cn-northwest-1`，apply 滚动更新。注意：凭证是分区级的，另一中国区用 `--region cn-north-1` 照常访问 |
| 7 | `unable to prepare context ... deploy: no such file or directory` | 在 terraform-ecs/ 目录下执行 docker build | 回仓库根目录构建（`-f deploy/Dockerfile.ra .`） |
| 8 | `pull access denied ... authorization token has expired`（拉 public.ecr.aws 也失败） | Docker 存了过期 token；或 `~/.docker` 被 sudo docker 弄成 root 属主 | `docker logout public.ecr.aws`；`sudo chown -R $USER ~/.docker && chmod 700 ~/.docker`；避免 `sudo docker` |
| 9 | 运行约 1 小时后所有调用 `RequestExpired` | 旧 entrypoint 用环境变量注入凭证，无法刷新 | 已内置修复：`credential_process` 模式（entrypoint-ra.sh），SDK 自动刷新 |

## 日常运维

**证书轮换**（Trust Anchor 信任 CA 而非单证书，无需改 Roles Anywhere）：

```bash
# 用现有 CA 签新客户端证书后，更新“主区域”的 secret（副本自动同步）
aws secretsmanager put-secret-value --secret-id /mcp/ra-cert \
  --secret-string file://~/mcp-certs/client.crt --region us-east-1
aws secretsmanager put-secret-value --secret-id /mcp/ra-key \
  --secret-string file://~/mcp-certs/client.key --region us-east-1
aws ecs update-service --cluster mcp --service mcp-aws-cn \
  --force-new-deployment --region us-west-2
```

不需要重建镜像、不需要 terraform apply（证书是任务启动时从 Secrets Manager 注入的）。

**新增 Spoke 账号**：目标账号部署 `cfn/roles-anywhere-spoke.yaml` → 更新 Hub 栈
`SpokeRoleArns` → tfvars `accounts` 加条目 → `terraform apply` → Agent Space 注册新 host。

**定时任务（SDK 调用 DevOps Agent）**：`devops-agent` 服务有公开 API
（`CreateChat`/`SendMessage`/`CreateBacklogTask` 等）。定时场景推荐
EventBridge Scheduler → Lambda → `create_backlog_task`（带 `clientToken` 幂等）。
服务本身暂无原生调度操作。

**销毁注意**：IAM 角色（mcp-ecs-exec/mcp-ecs-task 等）为全局资源，可能被其他区域的
部署共用；`terraform destroy` 前确认无其他部署依赖，否则先 `terraform state rm` 摘除 IAM 资源。

## 仓库结构

```
cfn/             Roles Anywhere Hub/Spoke CloudFormation 模板 + 证书生成脚本
deploy/          Dockerfile.ra + entrypoint-ra.sh + credential-helper.sh（凭证链核心）
src/             MCP server 入口与 cn_list_inventory 自定义工具
terraform-ecs/   ECS Fargate + internal ALB + ECR + IAM 全套 Terraform
docs/            复用现有 VPC 的风险报告与修复记录
```
