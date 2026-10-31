# powercontext-image

给 [PowerContext](https://powercontext.oceanbase.io/en/docs/operate/deploy-server/) 服务端做自动化镜像仓库：上游发版后自动构建多架构镜像并推送到 GHCR，宝塔面板直接 `image: ghcr.io/otaku-say/powercontext-image:latest` 拉取即可。

- 镜像地址：`ghcr.io/otaku-say/powercontext-image:latest`
- 同时发布版本 tag：`ghcr.io/otaku-say/powercontext-image:1.4.1`
- 支持 `linux/amd64` 与 `linux/arm64`

## 为什么不是直接从上游仓库构建

上游 `oceanbase/powercontext` 的 release 工作流只产出构建产物，**没有公开发布镜像**。但官方镜像本质就是 `pip install powercontext[cli,server]`，而每次发版都会同步到 PyPI，所以本仓库用 PyPI 版本号构建，内容与官方 `docker/Dockerfile` 一致，且构建更快（不需要 clone 仓库、不需要 uv）。

## 自动更新机制

`.github/workflows/build-image.yml`：

| 触发 | 行为 |
| --- | --- |
| 每 6 小时定时 | 查 PyPI 上 `powercontext` 的最新版本；GHCR 里没有该版本才构建 |
| Actions 页面手动运行 | 可指定版本号，留空则用最新版 |
| 推送到 `main`（改了 `Dockerfile` 或工作流） | 强制重建 |

所以上游一发新版，最长 6 小时后 `latest` 就会指向新版本；你也可以在 Actions 页面点 `Run workflow` 立即触发。

## 在宝塔面板部署

### 1. 准备目录与文件

```bash
mkdir -p /www/wwwroot/powercontext && cd /www/wwwroot/powercontext
# 把本仓库的 docker-compose.yml 和 .env.example 放进来
cp .env.example .env
openssl rand -hex 32          # 把输出填到 .env 的 POWERCONTEXT_SERVER_AUTH_TOKEN
chmod 600 .env
```

### 2. 首次拉镜像

```bash
docker pull ghcr.io/otaku-say/powercontext-image:latest
```

GHCR 包默认是**私有**的，第一次拉取会 401。到 GitHub → 你的头像 → Your packages → `powercontext-image` → Package settings → Change visibility 设为 **Public**；或者保持私有，在服务器上登录一次：

```bash
docker login ghcr.io -u otaku-say -p <带 read:packages 权限的 PAT>
```

### 3. 在面板启动

宝塔 → Docker → 编排模板 / Compose 项目 → 添加，目录选 `/www/wwwroot/powercontext`，启动。等价命令：

```bash
docker compose up -d
```

### 4. 反向代理 + HTTPS

宝塔 → 网站 → 添加站点（如 `pc.example.com`）→ 设置 → 反向代理，目标 `http://127.0.0.1:8000`，再申请 SSL 并开启强制 HTTPS。

`/etc/nginx/...` 或面板「配置文件」里建议加：

```nginx
client_max_body_size 50m;    # 捕获的对话可能较大
proxy_read_timeout 300s;
```

面板默认模板已带 `Host` / `X-Forwarded-Proto`，Dashboard 登录的同源校验依赖它们，不要删。

### 5. 验证

```bash
TOKEN='.env 里的 POWERCONTEXT_SERVER_AUTH_TOKEN'
curl -fsS http://127.0.0.1:8000/health/live
curl -fsS http://127.0.0.1:8000/health/ready | head -c 300   # 期望 "status":"ready"
curl -fsS -H "Authorization: Bearer $TOKEN" http://127.0.0.1:8000/v1/capabilities | head -c 300
```

`degraded` 表示数据库正常但模型连通性有问题（Magpie 地址 / key / 协议前缀），先查这三项。

## 更新

```bash
cd /www/wwwroot/powercontext
docker compose pull
docker compose up -d
```

`latest` 跟随上游最新版本。想锁定版本就把 compose 里的 `:latest` 换成 `:1.4.1`。

## 完整 `docker-compose.yml`

```yaml
# PowerContext 服务端 —— 宝塔面板 Docker「编排」直接可用
#
#   docker compose pull && docker compose up -d    # 更新到 latest
#   docker compose logs -f powercontext            # 看日志
#
# 所有配置项写在同目录的 .env 里（从 .env.example 复制而来）。
name: powercontext

services:
  powercontext:
    # 镜像由本仓库 GitHub Actions 自动构建，latest 始终跟随上游最新版本
    image: ghcr.io/otaku-say/powercontext-image:latest
    container_name: powercontext-server
    restart: unless-stopped

    # 只发布到本机环回地址：外网一律走宝塔 nginx 反向代理 + HTTPS
    # 端口冲突时改 .env 里的 PC_HOST_PORT
    ports:
      - "127.0.0.1:${PC_HOST_PORT:-8000}:8000"

    # SQLite 数据库与调度状态持久化在固定名字的卷里，便于备份/迁移
    volumes:
      - powercontext-data:/data

    # 全部运行参数（鉴权、模型、调度）都来自 .env
    env_file:
      - .env

    # 镜像自带 HEALTHCHECK（探测 /health/ready），这里不重复定义

volumes:
  powercontext-data:
    name: powercontext-data
```

## 完整 `.env` 配置（含说明）

```dotenv
# =============================================================================
# PowerContext 服务端配置
#   cp .env.example .env      # 复制后按需修改；.env 已被 .gitignore 忽略
#   openssl rand -hex 32      # 生成 POWERCONTEXT_SERVER_AUTH_TOKEN
# =============================================================================

# ---------------------------- 宿主机端口 -------------------------------------
# 容器只绑定在 127.0.0.1 上，宿主机端口冲突时改这里
PC_HOST_PORT=8000

# ------------------- 监听地址与数据目录（镜像已内置，勿改） -------------------
POWERCONTEXT_HOME=/data
POWERCONTEXT_SERVER_HTTP_HOST=0.0.0.0
POWERCONTEXT_SERVER_HTTP_PORT=8000

# ------------------------------- 访问控制 ------------------------------------
# disabled = 不鉴权（仅限纯本机试用）；公网部署必须 enforced
POWERCONTEXT_SERVER_ACCESS_MODE=enforced
# 服务端静态 Bearer token：客户端请求头为 Authorization: Bearer <此值>
# 该 token 同时是 Dashboard 的登录凭据，所有持有者共享同一个管理员身份
POWERCONTEXT_SERVER_AUTH_TOKEN=替换为openssl_rand_hex_32的输出
# Web 控制台：https://你的域名/dashboard/home（用上面的 token 登录）
POWERCONTEXT_SERVER_DASHBOARD_ENABLED=true
# 对外可访问的 HTTPS 地址，仅远程 Skill 分发会用到，可留空
#POWERCONTEXT_SERVER_PUBLIC_URL=https://pc.example.com

# ------------------------- 生成模型（走 Magpie 网关） ------------------------
# 前缀必须是 openai-chat:（Chat Completions）。
# 写成 openai: 会走 OpenAI Responses API，Magpie 未实现该接口，会直接 400/404。
POWERCONTEXT_SERVER_INFERENCE_GENERATION_MODEL=openai-chat:gpt-4.1-mini
POWERCONTEXT_SERVER_INFERENCE_GENERATION_BASE_URL=https://magpie.example.com/v1
# 单次结构化生成超时（秒）与最大请求次数（含重试）
#POWERCONTEXT_SERVER_INFERENCE_GENERATION_TIMEOUT_SECONDS=30
#POWERCONTEXT_SERVER_INFERENCE_GENERATION_MAX_REQUESTS=2

# ------------------------- 向量模型（语义召回必需） -------------------------
POWERCONTEXT_SERVER_INFERENCE_EMBEDDING_MODEL=openai:text-embedding-3-small
POWERCONTEXT_SERVER_INFERENCE_EMBEDDING_BASE_URL=https://magpie.example.com/v1
# 维度必须与模型真实输出一致：text-embedding-3-small=1536，bge-m3=1024
POWERCONTEXT_SERVER_INFERENCE_EMBEDDING_DIMENSION=1536
# 向量空间标识：建库后不可更改，改了必须清空数据卷重新建库
POWERCONTEXT_SERVER_INFERENCE_EMBEDDING_PROFILE_ID=openai-text-embedding-3-small-1536-unit
# 固定维度模型（如 SiliconFlow 的 bge-m3）填 false；OpenAI 系列保持 true
#POWERCONTEXT_SERVER_INFERENCE_EMBEDDING_SEND_DIMENSIONS=true

# ------------------------- 模型凭据（Magpie 的 key） ------------------------
# 同一个变量同时供生成与向量两个能力使用
OPENAI_API_KEY=替换为Magpie的key

# ----------------------------- 后台自动提炼 ----------------------------------
# 每隔多少秒消化一次新捕获的对话（不设置 = 只存不提炼）
POWERCONTEXT_SERVER_RUNTIME_SCHEDULE_SECONDS=120
# 提炼风格：coding = 面向工程协作（默认）；conversation = 面向对话事实
#POWERCONTEXT_SERVER_RUNTIME_MEMORY_EXTRACTION_PROFILE=coding

# ------------------------------ 日志与观测 -----------------------------------
# 不需要 Prometheus 抓取时关掉 /metrics
#POWERCONTEXT_SERVER_METRICS_ENABLED=false
#POWERCONTEXT_SERVER_LOGGING_LEVEL=INFO
```

## 接 Magpie 网关插件

服务端起来后，先建一个 Scope（记忆域）：

```bash
TOKEN='.env 里的 POWERCONTEXT_SERVER_AUTH_TOKEN'

curl -sS -X POST http://127.0.0.1:8000/v1/scopes \
  -H 'Content-Type: application/json' \
  -H "Authorization: Bearer $TOKEN" \
  --data '{"title":"magpie","summary":"Magpie 网关共享记忆域","idempotency_key":"magpie"}'
# 记下返回里的 scope_id
```

再装插件（Magpie ≥ 0.1.1273；从插件页面保存配置需要 ≥ 0.1.1531）：

```bash
magpie plugin add @magpie-community/gateway-powercontext
magpie plugin options @magpie-community/gateway-powercontext \
'{"serverUrl":"http://127.0.0.1:8000","authorization":"Bearer <TOKEN>","scopeId":"<scope_id>","capture":true,"recallRemote":true,"captureRemote":true}'
```

注意事项：

- `scopeId` **必须显式填**。留空时插件会走 `POST /v1/scope-bindings/resolve`，没有绑定关系就 404，于是完全不召回。
- `serverUrl` 用 `http://` 时只有 `127.0.0.1` / `localhost` / `[::1]` 被允许；跨机访问必须用 `https://pc.example.com`。
- Magpie 若跑在容器里，`127.0.0.1` 指向容器自身，要改成宿主机地址（如 `http://172.17.0.1:8000`）或把两个容器放进同一 docker 网络。
- `capture` 默认关闭，要自动沉淀对话必须显式 `true`；客户端不在网关本机时还需要 `recallRemote` / `captureRemote`。

## 备份与恢复

SQLite 需要停写后再拷：

```bash
cd /www/wwwroot/powercontext
docker compose stop
docker cp powercontext-server:/data "./backup-data-$(date +%F)"
docker compose start
```

恢复：把备份目录内容写回卷 `powercontext-data` 的 `/data`，再 `docker compose up -d`。

## 常见问题

| 现象 | 原因与处理 |
| --- | --- |
| `/health/ready` 返回 `degraded` | 模型连通性问题：`BASE_URL` 少了 `/v1`、key 错、或生成模型前缀写成 `openai:`（应用 `openai-chat:`） |
| 检索只有 `fts` 没有 `vector`/`hybrid` | embedding 未配置或维度/Profile 不匹配；检查 `EMBEDDING_*` 三项 |
| 启动报向量 Profile 不兼容 | 改过 `EMBEDDING_PROFILE_ID`/维度。清空数据卷重建库，或改回原配置 |
| 插件不召回 | `scopeId` 没填、请求头 token 不对、或 `serverUrl` 用了非 loopback 的 http |
| 镜像拉取 401 | GHCR 包是私有：设为 Public，或 `docker login ghcr.io -u <user> -p <PAT>` |
| 对话没被自动提炼 | `capture` 没开，或 `RUNTIME_SCHEDULE_SECONDS` 未设置 |

## 目录结构

```
.
├── .github/workflows/build-image.yml   # 定时/手动构建并推送 GHCR
├── Dockerfile                          # 基于 PyPI 发行包构建
├── docker-compose.yml                  # 宝塔可直接使用
├── .env.example                        # 配置模板（含中文注释）
└── .gitignore
```
