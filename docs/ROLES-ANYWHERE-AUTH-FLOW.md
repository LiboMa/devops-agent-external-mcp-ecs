# Roles Anywhere 认证链与 AssumeRole 过程详解

本文提取自上游方案的部署指南与实战记录，说明 MCP Server 容器如何在**没有任何长期
AK/SK** 的情况下，持续获得中国区账号的临时凭证。

## 总览

```
一张客户端证书 → 一个 Hub 账号 → N 个 Spoke 账号
```

```
MCP Server (ECS Fargate, us-west-2)
    │  ① X.509 客户端证书签名请求 (aws_signing_helper)
    ▼
IAM Roles Anywhere CreateSession (cn-northwest-1, Hub 账号 <CN_ACCOUNT_ID>)
    │  ② Hub Role 临时凭证（≤1h）
    ▼
sts:AssumeRole (中国区 STS, ExternalId=mcp-bridge)
    │  ③ Spoke Role 临时凭证（1h，botocore 按 Expiration 自动续）
    ▼
aws-cn 分区 API（cn-northwest-1 / cn-north-1 均可访问）
```

加一个新账号只需在新 Spoke 部署一个 Role 并加进 Hub 的白名单——证书、镜像、ECS 全都不用动。

## 一、信任链设计（部署期建立，共四层）

### 1. CA 证书 → Trust Anchor

`cfn/generate-certs.sh` 生成自签 CA 和客户端证书；Hub 栈把 **CA 证书**（不是客户端证书）
注册为 Trust Anchor：

| 文件 | 用途 | 保管 |
|---|---|---|
| `ca.crt` | 注册到 Trust Anchor | 可公开 |
| `ca.key` | 签发新客户端证书 | **离线保管（HSM/Vault），泄露=任何人可签出可信证书** |
| `client.crt` / `client.key` | 容器运行时身份 | Secrets Manager（与 ECS 任务同区域） |

Trust Anchor 信任的是 CA——所以**轮换客户端证书不需要改 Roles Anywhere 任何配置**。

### 2. Hub Role 信任策略（谁能变成 Hub）

只允许 Roles Anywhere 服务代表**本 Trust Anchor 验证过的证书持有者** assume（
`cfn/roles-anywhere-hub.yaml`）：

```yaml
Principal: { Service: rolesanywhere.amazonaws.com }
Action: [sts:AssumeRole, sts:TagSession, sts:SetSourceIdentity]
Condition:
  ArnEquals:
    aws:SourceArn: <TrustAnchor ARN>   # 防混淆代理：别的 Trust Anchor 换不到这个角色
```

### 3. Hub Role 权限策略（Hub 能去哪）

Hub 本身**没有任何业务权限**，唯一的权限是 assume 白名单里的 Spoke Role：

```yaml
Action: [sts:AssumeRole, sts:SetSourceIdentity, sts:TagSession]
Resource: !Ref SpokeRoleArns    # 逗号分隔的 Spoke Role ARN 白名单
```

Roles Anywhere **Profile** 把 Trust Anchor 验证结果绑定到 Hub Role，并限定
`DurationSeconds`（默认 3600）。

### 4. Spoke Role 信任策略（谁能进目标账号）

每个目标账号部署 `cfn/roles-anywhere-spoke.yaml`，只信任 Hub Role 且要求 ExternalId：

```yaml
Principal: { AWS: <HubRoleArn> }
Action: sts:AssumeRole
Condition:
  StringEquals:
    sts:ExternalId: mcp-bridge   # 防混淆代理的第二道锁
ManagedPolicyArns:
  - arn:aws-cn:iam::aws:policy/ReadOnlyAccess   # 权限边界：只读
```

- Hub 和 Spoke 是同一账号时**也要部署 Spoke 栈**（Hub assume 自己账号里的 Spoke Role）。
- 企业合规可加 `PermissionsBoundary` 参数。

## 二、运行时认证时序（容器内）

### 容器启动（`deploy/entrypoint-ra.sh`）

1. 把 ECS 从 Secrets Manager 注入的 `RA_CERT_PEM`/`RA_KEY_PEM` 环境变量写成文件
   （`/app/certs/client.crt|key`，600 权限），随后 unset。
2. **注册 credential_process**（关键设计，见第三节的历史教训）：

```bash
export AWS_CONFIG_FILE=/app/certs/aws-config
export AWS_PROFILE=ra
cat > "$AWS_CONFIG_FILE" <<EOF
[profile ra]
credential_process = /app/credential-helper.sh
EOF
```

3. **Fail fast**：启动 MCP server 之前先跑一次 helper，失败立即退出并把错误打进日志
   （症状是任务反复重启 + 日志出现 `FATAL: credential-helper.sh failed`）。

### 每次取凭证（`deploy/credential-helper.sh`，botocore 按需调用）

```
botocore 需要凭证
  └─► credential-helper.sh
        ├─ ① unset AWS_PROFILE AWS_CONFIG_FILE      ← 递归守卫（见下）
        ├─ ② aws_signing_helper credential-process
        │      --certificate client.crt --private-key client.key
        │      --trust-anchor-arn ... --profile-arn ... --role-arn <HubRole>
        │      --region cn-northwest-1
        │      → 用私钥对 CreateSession 请求做 X.509 签名 → Hub 临时凭证
        ├─ ③ export Hub 凭证为环境变量
        ├─ ④ aws sts assume-role --role-arn <SpokeRole>
        │      --external-id mcp-bridge --duration-seconds 3600
        │      --region cn-northwest-1              ← 中国区 STS endpoint
        │      → Spoke 临时凭证
        └─ ⑤ 输出 credential_process 标准 JSON（含 Expiration）
```

botocore 缓存结果，**每次 API 调用前检查 `Expiration`，临近过期自动重新 exec
helper**——惰性刷新、无后台线程、进程活着就能永续刷新。

**递归守卫（①）**：helper 作为 credential_process 被调用时继承了 `AWS_PROFILE=ra`；
其内部的 `aws sts assume-role` 若再解析该 profile 会重新调用 helper → 无限递归。
先 unset，让内部 `aws` 只看到 ②③ 显式导出的 Hub 凭证（env 优先级高于 profile）。

### 验证方法

启动日志应看到（缺任何一行都说明凭证链没就绪）：

```
[entrypoint-ra] credential_process configured (profile=ra); SDK will fetch + auto-refresh.
[entrypoint-ra] Initial credential fetch OK.
```

## 三、历史教训：为什么必须用 credential_process（RequestExpired bug）

上游最初版本用「环境变量注入 + 后台刷新循环」，部署次日全部调用报
`RequestExpired`，ECS 却显示 healthy：

```bash
# 旧版（有缺陷）
export AWS_ACCESS_KEY_ID=$(echo "$CREDS" | jq -r '.AccessKeyId')
exec python -m awslabs.aws_api_mcp_server.server
(while true; do sleep 3300; /app/credential-helper.sh > /tmp/ra-credentials.json; done) &
```

**缺陷**：运行中进程的环境变量无法被外部修改。MCP server 在 `exec` 那一刻就把凭证
冻结了；后台循环刷新的凭证写进文件，但没有任何代码去读——1 小时后 token 过期，
所有调用失败。日志里的 "Credentials refreshed" 是自欺欺人。

**修复**即现在的 credential_process 模式：helper 输出本来就是 SDK 标准格式，
让 botocore 自己管理缓存与刷新。此修复对 Agent Space 完全透明（endpoint/注册不变）。

排障对照：

| 症状 | 判断 |
|---|---|
| 启动即失败、任务反复重启 | 证书/Trust Anchor/Spoke 配置错，看 helper 的 FATAL 输出 |
| 跑约 1 小时后全部 `RequestExpired` | 镜像是旧版 env 注入模式——确认用 `Dockerfile.ra` 重新构建 |
| 全部 `UnrecognizedClientException` | 凭证正常但发错分区：`accounts.aws_region` 填成了全球区域 |

## 四、安全属性与应急操作

| 属性 | 说明 |
|---|---|
| 无长期密钥 | 容器/代码/配置中不存在 AK/SK；唯一的长期材料是客户端证书（默认 1 年） |
| 双重防混淆代理 | Hub 信任策略锁 `aws:SourceArn`=Trust Anchor；Spoke 信任策略锁 `sts:ExternalId=mcp-bridge` |
| 最小权限 | Hub 无业务权限只能 assume 白名单；Spoke 默认 ReadOnlyAccess，可加 PermissionsBoundary |
| 凭证寿命 | Hub/Spoke 凭证均 ≤1h，泄露窗口小 |

应急断连（按影响范围从小到大）：

| 操作 | 方式 | 生效 |
|---|---|---|
| 吊销单张客户端证书 | 序列号加入 CRL 上传到 Trust Anchor | 秒级 |
| 断开单个 Spoke | 删除该账号的 Spoke CFN 栈 | 分钟级 |
| 断开所有连接 | `aws rolesanywhere disable-trust-anchor --trust-anchor-id <TRUST_ANCHOR_ID> --region cn-northwest-1` | 秒级 |

证书年度轮换流程见 [README「日常运维」](../README.md#日常运维)——只需用 `ca.key`
签新证书 + 更新 Secrets Manager 主区域 + force redeploy，Roles Anywhere 侧零改动。

## 五、关键 ARN 速查（占位符）

```
Trust Anchor : arn:aws-cn:rolesanywhere:cn-northwest-1:<CN_ACCOUNT_ID>:trust-anchor/<TRUST_ANCHOR_ID>
Profile      : arn:aws-cn:rolesanywhere:cn-northwest-1:<CN_ACCOUNT_ID>:profile/<PROFILE_ID>
Hub Role     : arn:aws-cn:iam::<CN_ACCOUNT_ID>:role/mcp-roles-anywhere-hub
Spoke Role   : arn:aws-cn:iam::<CN_ACCOUNT_ID>:role/mcp-spoke-readonly
Secrets      : arn:aws:secretsmanager:us-west-2:<GLOBAL_ACCOUNT_ID>:secret:/mcp/ra-cert-XXXXXX
               arn:aws:secretsmanager:us-west-2:<GLOBAL_ACCOUNT_ID>:secret:/mcp/ra-key-XXXXXX
```

对应 Terraform 变量：`roles_anywhere.{trust_anchor_arn, profile_arn, hub_role_arn,
cert_secret_arn, key_secret_arn, region}` 与 `accounts.*.spoke_role_arn`。
