# 风险报告：terraform-ecs 复用现有 VPC 部署

- **日期**：2026-08-26
- **环境**：AWS 账号 `<GLOBAL_ACCOUNT_ID>`，区域 `us-east-1`，VPC `<LEGACY_VPC_ID>`（10.42.0.0/16）
- **触发事件**：`terraform apply` 失败 —
  `InvalidParameterValue: Network <LEGACY_VPC_ID> already has an internet gateway attached`

## TL;DR

1. 当前 tfvars 指定复用的"现有 VPC"，实际上是**本 Terraform 栈早前一次部署自建的**（state 已丢失），VPC 里已有完整的 IGW、NAT、路由表、ALB 和两个在跑的 ECS 服务。
2. 旧版 `network.tf` 存在设计缺陷：指定 `vpc_id` 时只跳过 VPC/子网创建，**IGW/NAT/路由表仍会无条件新建**，导致 IGW 挂载冲突（已发生）、NAT 重复计费、以及最危险的——接管在用子网的路由表。
3. **已修复**：`network.tf` 全部网络资源改为条件创建，指定 `vpc_id` 时完全复用子网现有路由表，不再新建任何网络资源；下次 apply 会顺带清理掉本次事故产生的两个孤儿资源。
4. **待处理**：应用层资源（ALB、安全组、Target Group、ECS 服务、ECR、IAM、日志组）与旧部署残留同名，直接 apply 仍会连环失败，需要按第五节的 runbook 逐一 `terraform import` 收编。

---

## 一、背景与根因

时间线还原：

1. 早前一次部署以 `vpc_id = ""`（自建模式）apply，创建了完整环境：VPC `10.42.0.0/16`、4 个子网、IGW、NAT、路由表 `mcp-public`/`mcp-private`、ALB `mcp-alb`、ECS 集群 `mcp` 及两个服务（`mcp-aws-cn`、`mcp-aws-global`，分别服务 `mcp-cn.example.com` 和 `mcp-global.example.com`）。
2. 该次部署的 **state 文件已丢失**（当前目录的 `terraform.tfstate` 是新的，无备份）。
3. 本次重新部署时，tfvars 把 `vpc_id` 指向了那套自建 VPC 及其子网，意图"复用现有网络"。
4. 但旧版 `network.tf` 的 IGW/NAT/路由表**没有** `count = local.create_vpc ? 1 : 0` 条件（只有 `vpc.tf` 里的 VPC/子网有），apply 时：
   - `aws_ecs_cluster.mcp`：ECS CreateCluster 幂等，静默"收编"了现存集群 `mcp` ✅
   - `aws_eip.nat`：新建了一个 EIP（`<ORPHAN_EIP>`）✅ → 成为孤儿
   - `aws_internet_gateway.this`：新建 IGW `<ORPHAN_IGW_ID>`，**挂载到 VPC 时失败**（一个 VPC 只能挂一个 IGW），资源被标记 tainted ❌ → apply 中止

## 二、现状盘点

### 2.1 网络层（本次事故焦点）

| 资源 | 线上实际（旧部署创建，健康在用） | 当前 state | 旧代码 plan 的动作 |
|---|---|---|---|
| VPC | `<LEGACY_VPC_ID>` (10.42.0.0/16) | data source 引用 | 复用 ✅ |
| 子网 ×4 | `mcp-public-0/1`、`mcp-private-0/1` | 变量传入 | 复用 ✅ |
| IGW | `<LEGACY_IGW_ID>`（已挂载） | 记录的是孤儿 `<ORPHAN_IGW_ID>`（tainted，未挂载） | **重建 → 失败** ❌ |
| NAT | `<LEGACY_NAT_ID>`（EIP <LEGACY_NAT_EIP>，位于 mcp-public-0） | 无 | **重复新建** ❌ |
| 公有路由表 | `<LEGACY_RTB_PUBLIC>`（mcp-public，0.0.0.0/0 → IGW） | 无 | 新建并**抢占子网关联** ❌ |
| 私有路由表 | `<LEGACY_RTB_PRIVATE>`（mcp-private，0.0.0.0/0 → NAT） | 无 | 新建并**抢占子网关联** ❌ |
| EIP | NAT 在用 <LEGACY_NAT_EIP> | 孤儿 `<ORPHAN_EIP_ALLOC_ID>`（<ORPHAN_EIP>，闲置计费中） | — |

私有子网已具备 `0.0.0.0/0 → <LEGACY_NAT_ID>` 路由，**完全满足 Fargate 出网需求，无需新建任何网络资源**。

### 2.2 应用层（下一步 apply 的拦路虎）

以下资源线上存在（旧部署残留）但不在当前 state，而新配置要以**相同名字**创建，apply 必然报"已存在"类错误：

| Terraform 资源地址 | 线上同名资源 | 冲突错误类型 |
|---|---|---|
| `aws_lb.mcp` | ALB `mcp-alb` | DuplicateLoadBalancerName |
| `aws_security_group.alb` | `mcp-alb` / `<SG_ALB_ID>` | InvalidGroup.Duplicate |
| `aws_security_group.tasks` | `mcp-tasks` / `<SG_TASKS_ID>` | InvalidGroup.Duplicate |
| `aws_lb_target_group.mcp["aws-cn"]` | TG `mcp-aws-cn` | DuplicateTargetGroupName |
| `aws_lb_listener.https` | 443 listener（证书与 tfvars 一致） | 挂在被冲突的 ALB 上 |
| `aws_ecs_service.mcp["aws-cn"]` | 服务 `mcp/mcp-aws-cn`（RUNNING 1/1） | 同名服务已存在 |
| `aws_cloudwatch_log_group.mcp["aws-cn"]` | `/ecs/mcp-aws-cn` | ResourceAlreadyExists |
| `aws_ecr_repository.mcp["aws"]` | `mcp-aws` | RepositoryAlreadyExists |
| `aws_ecr_repository.mcp["aliyun"]` | `mcp-aliyun` | RepositoryAlreadyExists |
| `aws_iam_role.task_execution` | `mcp-ecs-exec` | EntityAlreadyExists |
| `aws_iam_role.task` | `mcp-ecs-task` | EntityAlreadyExists |
| `aws_iam_policy.read_secrets` | `mcp-ecs-secrets` | EntityAlreadyExists |
| `aws_iam_policy.eks_describe` | `mcp-eks-describe` | EntityAlreadyExists |

不冲突的：`aws_ecs_task_definition`（新 revision 即可）、`aws_lb_listener_rule.mcp["aws-cn"]`（新 host 新规则，但见 R6）。

### 2.3 不在新配置中的旧部署残留（脱管资源）

- ECS 服务 `mcp/mcp-aws-global`（RUNNING 1/1）+ TG `mcp-aws-global` + 日志组 `/ecs/mcp-aws-global` + listener 规则 priority 1（host `mcp-global.example.com`）
- listener 规则 priority 2（host `mcp-cn.example.com` → TG `mcp-aws-cn`）

## 三、风险清单

| # | 风险 | 等级 | 状态 | 说明 |
|---|---|---|---|---|
| R1 | IGW 重复创建导致 apply 失败 | 高 | **已发生** | 一个 VPC 仅允许挂载一个 IGW；产生孤儿 `<ORPHAN_IGW_ID>` |
| R2 | NAT 重复创建 | 中 | **已规避**（代码修复） | 多花约 $32.9/月 + $0.045/GB 处理费，且毫无用途 |
| R3 | 路由表接管在用子网 | **严重** | **已规避**（代码修复） | 新建路由表 + 关联会与现有显式关联冲突（Resource.AlreadyAssociated 使 apply 失败）；若侥幸成功则改写 4 个子网的路由，**当前在跑的 2 个 ECS 服务瞬间断网** |
| R4 | 应用层 13 项资源撞名 | 高 | **待处理** | 见 2.2；不做 import 则 apply 连环失败 |
| R5 | 孤儿资源持续计费 | 低 | **已清理**（2026-08-26 apply 自动销毁，NotFound 已确认） | 闲置 EIP `<ORPHAN_EIP>` 约 $3.65/月；未挂载 IGW 免费但属垃圾资源 |
| R6 | host 切换造成老域名断流 | 中 | **决策点** | 新配置 host 为 `aws-cn-customer.example.com`；若按 runbook 收编 `mcp-aws-cn` 服务并 apply，`mcp-cn.example.com` 的规则仍在（脱管），但服务容器的 ALLOWED_HOSTS 会切到新域名，老域名请求将被应用拒绝。需同步更新 DNS（新域名 CNAME → `internal-mcp-alb-<ALB_DNS_SUFFIX>.us-east-1.elb.amazonaws.com`，经 Private Connection 访问） |
| R7 | `mcp-aws-global` 服务脱管运行 | 中 | **决策点** | 不在新配置中，无人管理但持续计费（Fargate 1 任务）。若已无业务：手动缩容删除；若仍需要：把 `aws-global` 账号加回 tfvars 的 `accounts` 并一并 import |
| R8 | state 再次丢失 | 中 | 建议 | 本地 state 是单点。建议迁移到 S3 backend（+ DynamoDB 锁）杜绝复发 |

## 四、已实施的修复（2026-08-26）

### 修复 1：网络资源条件创建

**`terraform-ecs/network.tf`**：IGW、EIP、NAT、公私路由表、路由表关联全部加上 `count = local.create_vpc ? 1 : 0`（关联为 `? length(subnet_ids) : 0`），内部引用改为 `[0]` 索引。

新行为：

- `vpc_id = ""`（自建模式）：行为与旧版完全一致，创建全套网络。
- `vpc_id` 指定（复用模式）：**不创建任何网络资源**，子网沿用各自现有路由表。前提要求（已写入 `terraform.tfvars.example`）：
  - VPC 已挂载 IGW；
  - `private_subnet_ids` 已有 `0.0.0.0/0 → NAT` 路由（Fargate 拉镜像、访问中国区 API 需要出网）。

**附带收益**：state 里的两个孤儿（tainted IGW、闲置 EIP）因 count 变为 0 会被下次 apply 自动销毁，无需手工清理。已用 `terraform plan` 验证：

```
Plan: 18 to add, 0 to change, 2 to destroy.
  - aws_internet_gateway.this[0] will be destroyed   # 孤儿 <ORPHAN_IGW_ID>（未挂载）
  - aws_eip.nat[0] will be destroyed                  # 孤儿 <ORPHAN_EIP>
  # 新增的 18 项全部为应用层资源，无任何网络资源
```

### 修复 2：移除无效的 `public_subnet_ids` 变量

审察发现：修复 1 之后，`var.public_subnet_ids` 在**所有模式下都是死输入**——

- 复用 VPC 模式：仅有的 3 处消费者（NAT 放置 `network.tf:30`、公有路由表关联 `network.tf:49-50`）count 全为 0，变量传什么都不生效；
- 自建 VPC 模式：`local.public_subnet_ids` 直接取自建子网（`vpc.tf`），变量同样被忽略。

真正承载负载的资源全部只用私有子网：ALB 为 `internal = true` 放在私有子网（`alb.tf:29-32`），Fargate 任务也在私有子网（`ecs.tf:207`）。入口流量走 VPC Lattice Private Connection、出网走 NAT，整条链路不需要 public 子网。

已删除该变量及所有引用：

| 文件 | 变更 |
|---|---|
| `variables.tf` | 删除 `variable "public_subnet_ids"`；`private_subnet_ids` 描述补充 NAT 路由前提 |
| `vpc.tf` | local 的 fallback 由 `var.public_subnet_ids` 改为 `[]`，并加注释说明 |
| `terraform.tfvars` | 删除 `public_subnet_ids = [...]` 行 |
| `terraform.tfvars.example`、`README.md`、`README.en.md` | 示例同步删除，注明复用模式只需私有子网 |

结论：**复用现有 VPC 时只需提供 `vpc_id` + `private_subnet_ids`（私有子网须已有 `0.0.0.0/0 → NAT` 路由）**。

## 五、解决方案与实施步骤

### 方案 A（推荐）：import 收编存量应用层资源，原地升级

零停机：现有 ALB / DNS / 安全组 / 在跑服务全部保留，apply 只做增量更新（新 task definition、新 host 规则）。

**步骤 1 — 代码修复**：已完成（见第四节，含修复 1/修复 2）。tfvars 现仅需 `vpc_id` 与 `private_subnet_ids`。

**步骤 2 — import 存量资源**（在 `terraform-ecs/` 下依次执行）：

```bash
# 安全组
terraform import aws_security_group.alb   <SG_ALB_ID>
terraform import aws_security_group.tasks <SG_TASKS_ID>

# ALB + Listener + Target Group
terraform import aws_lb.mcp \
  arn:aws:elasticloadbalancing:us-east-1:<GLOBAL_ACCOUNT_ID>:loadbalancer/app/mcp-alb/<ALB_ID>
terraform import aws_lb_listener.https \
  arn:aws:elasticloadbalancing:us-east-1:<GLOBAL_ACCOUNT_ID>:listener/app/mcp-alb/<ALB_ID>/<LISTENER_ID>
terraform import 'aws_lb_target_group.mcp["aws-cn"]' \
  arn:aws:elasticloadbalancing:us-east-1:<GLOBAL_ACCOUNT_ID>:targetgroup/mcp-aws-cn/<TG_ID>

# ECS 服务 + 日志组
terraform import 'aws_ecs_service.mcp["aws-cn"]' mcp/mcp-aws-cn
terraform import 'aws_cloudwatch_log_group.mcp["aws-cn"]' /ecs/mcp-aws-cn

# ECR
terraform import 'aws_ecr_repository.mcp["aws"]'    mcp-aws
terraform import 'aws_ecr_repository.mcp["aliyun"]' mcp-aliyun

# IAM 角色 / 策略 / 挂载
terraform import aws_iam_role.task_execution mcp-ecs-exec
terraform import aws_iam_role.task           mcp-ecs-task
terraform import aws_iam_policy.read_secrets arn:aws:iam::<GLOBAL_ACCOUNT_ID>:policy/mcp-ecs-secrets
terraform import aws_iam_policy.eks_describe arn:aws:iam::<GLOBAL_ACCOUNT_ID>:policy/mcp-eks-describe
terraform import aws_iam_role_policy_attachment.task_execution_base \
  mcp-ecs-exec/arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy
terraform import aws_iam_role_policy_attachment.task_execution_secrets \
  mcp-ecs-exec/arn:aws:iam::<GLOBAL_ACCOUNT_ID>:policy/mcp-ecs-secrets
terraform import aws_iam_role_policy_attachment.task_eks \
  mcp-ecs-task/arn:aws:iam::<GLOBAL_ACCOUNT_ID>:policy/mcp-eks-describe
```

**步骤 3 — 复核 plan**。预期 diff（属正常，不属于风险）：

- `aws_ecs_task_definition.mcp["aws-cn"]`：新 revision（Roles Anywhere 认证、新 host 环境变量）
- `aws_ecs_service.mcp["aws-cn"]`：更新 task definition 引用，滚动部署
- `aws_lb_listener_rule.mcp["aws-cn"]`：新建（host `aws-cn-customer.example.com`）
- `aws_iam_policy.read_secrets`：策略内容更新（加入 RA 证书 secret 的读取权限）
- 销毁 2 个孤儿（tainted IGW、闲置 EIP）
- **不应出现**：任何 `aws_nat_gateway`、`aws_route_table`、`aws_internet_gateway`（除孤儿销毁）、ALB/SG 的 replace。若出现 replace，先停下排查属性漂移。

**步骤 4 — apply**，然后推送新镜像并强制滚动（见 `terraform output push_commands`）。

**步骤 5 — 收尾**：

- DNS：`aws-cn-customer.example.com` 指向 ALB（经 VPC Lattice Private Connection 场景按既有接入方式配置）。
- 决策 R6：确认 `mcp-cn.example.com` 老规则是否手动删除。
- 决策 R7：确认 `mcp-aws-global` 服务去留（删除：`aws ecs update-service --cluster mcp --service mcp-aws-global --desired-count 0` 后 `delete-service`，再删 TG/日志组/listener 规则；保留：加回 tfvars 并 import）。

### 方案 B（不推荐）：删除全部残留后重新 apply

把 2.2/2.3 的资源全部手动删除再 apply。缺点：在跑服务停机；ALB 重建后 DNS 名变化，所有指向记录要改；ECR 仓库删除会连镜像一起删。仅当确认旧部署完全无人使用、且不在乎 ALB DNS 变化时才考虑。

### 后续加固（建议）

1. **Remote state**：迁移到 S3 backend + 状态锁，杜绝 state 丢失复发（R8）。
2. 老的 `mcp-global`/`mcp-cn` 域名下线计划确定后，清理对应 listener 规则、TG、日志组。

## 六、验证清单

- [ ] `terraform plan`：0 个网络资源新建；仅销毁 2 个孤儿
- [ ] 删除 `public_subnet_ids` 后 `terraform validate` 通过、plan 无额外 diff（该变量已从代码中移除）
- [ ] apply 成功，无 AlreadyExists / Duplicate 类错误
- [x] 孤儿清理确认：`aws ec2 describe-internet-gateways --internet-gateway-ids <ORPHAN_IGW_ID>` 返回 NotFound；EIP <ORPHAN_EIP> 已释放（2026-08-26 验证）
- [ ] 现网未受扰动：IGW `<LEGACY_IGW_ID>` 仍挂载、NAT `<LEGACY_NAT_ID>` 仍 available、4 个子网路由表关联未变
- [ ] ECS 服务 `mcp-aws-cn` 滚动完成，RUNNING 任务使用新 task definition
- [ ] 通过新域名走通 MCP 调用链（Roles Anywhere → Hub → Spoke）

## 附录：关键资源速查

| 项 | 值 |
|---|---|
| VPC | `<LEGACY_VPC_ID>`（10.42.0.0/16） |
| 在用 IGW | `<LEGACY_IGW_ID>` |
| 在用 NAT | `<LEGACY_NAT_ID>`（<LEGACY_NAT_EIP>） |
| 孤儿 IGW（已清理） | `<ORPHAN_IGW_ID>` |
| 孤儿 EIP（已清理） | `<ORPHAN_EIP_ALLOC_ID>`（<ORPHAN_EIP>） |
| ALB | `mcp-alb` → `internal-mcp-alb-<ALB_DNS_SUFFIX>.us-east-1.elb.amazonaws.com` |
| ECS 集群/服务 | `mcp` / `mcp-aws-cn`、`mcp-aws-global` |
| 证书 | `arn:aws:acm:us-east-1:<GLOBAL_ACCOUNT_ID>:certificate/<LEGACY_CERT_ID>...`（线上 listener 与 tfvars 一致） |
