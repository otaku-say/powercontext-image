# powercontext-image

[![build-image](https://github.com/otaku-say/powercontext-image/actions/workflows/build-image.yml/badge.svg)](https://github.com/otaku-say/powercontext-image/actions/workflows/build-image.yml)

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

构建状态与历史：<https://github.com/otaku-say/powercontext-image/actions>

## 在宝塔面板部署

### 1. 准备目录与文件

```bash
mkdir -p /www/wwwroot/powercontext && cd /www/wwwroot/powercontext
# 只需要一个文件：本仓库的 docker-compose.yml（配置全部内联，不读 .env）
vim docker-compose.yml

# 要改两个占位符：
#   POWERCONTEXT_SERVER_AUTH_TOKEN  <- openssl rand -hex 32 的输出
#   x-or-headers 锚点里的 REPLACE_WITH_OPENROUTER_KEY  <- 你的 OpenRouter key
#
# 仓库是公开的：填好真值的版本只留在服务器上，别 commit 回去
# 想多一层保险：chmod 600 docker-compose.yml
```

### 2. 首次拉镜像

```bash
# 已验证：公开包，无需登录，可直接匿名拉取
# linux/amd64 + linux/arm64 双架构，latest 与 1.4.1 指向同一 digest
docker pull ghcr.io/otaku-say/powercontext-image:latest
```

镜像包已设为 **Public**。如果拉取报 401（例如以后误改成私有），二选一：

- GitHub → 头像 → Your packages → `powercontext-image` → Package settings → Change visibility 设为 **Public**
- 或保持私有，在服务器上登录一次：`docker login ghcr.io -u otaku-say -p <带 read:packages 权限的 PAT>`

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
TOKEN='compose 里 POWERCONTEXT_SERVER_AUTH_TOKEN 的值'
curl -fsS http://127.0.0.1:8000/health/live
curl -fsS http://127.0.0.1:8000/health/ready | head -c 300   # 期望 "status":"ready"
curl -fsS -H "Authorization: Bearer $TOKEN" http://127.0.0.1:8000/v1/capabilities | head -c 300
```

`degraded` 表示数据库正常但模型连通性有问题（OpenRouter 地址 / key / 协议前缀 `openai:` 与 `openai-chat:` 是否用对），先查这三项。

## 更新

```bash
cd /www/wwwroot/powercontext
docker compose pull
docker compose up -d
```

`latest` 跟随上游最新版本。想锁定版本就把 compose 里的 `:latest` 换成 `:1.4.1`。

## 完整 `docker-compose.yml`

配置全部内联在本仓库根目录的 [`docker-compose.yml`](./docker-compose.yml) 里，不再单独贴一份副本（避免两处不一致）。

## 对接 Magpie 网关的记忆插件（powercontext）

服务端跑起来之后，在 Magpie 侧装网关钩子插件，记忆才会自动召回与沉淀。

### 1. 建一个 Scope（插件不会自动建）

```bash
PC=https://pc.example.com          # 对外地址；同网络时也可用 http://powercontext-server:8000
TOKEN=<compose 里 POWERCONTEXT_SERVER_AUTH_TOKEN 的值>

curl -sS -X POST "$PC/v1/scopes" \
  -H "Authorization: Bearer $TOKEN" -H 'content-type: application/json' \
  -d '{"title":"magpie-agents","summary":"Magpie 后面所有 agent 共用的记忆空间"}' | tee /tmp/scope.json
```

返回里的 `scope_id` 就是插件要填的 `scopeId`。**不填会静默无召回**（插件 fail-open）。

### 2. 安装插件

```bash
magpie plugin add @magpie-community/gateway-powercontext
# 若这个名字在 npm 上取不到，就用本地目录安装（目录内容 = packages/powercontext）
magpie plugin add ./powercontext
```

### 3. 写插件配置

```bash
magpie plugin options @magpie-community/gateway-powercontext '{
  "serverUrl": "http://powercontext-server:8000",
  "authorization": "Bearer <PC_TOKEN>",
  "scopeId": "<scope_id>",
  "allowInsecureHttp": true,
  "recallRemote": true,
  "capture": true,
  "captureRemote": true,
  "gatewayTimeoutMs": 8000,
  "requestTimeoutMs": 3000,
  "recallBackoffMs": 30000,
  "maxBytes": 8000
}'
```

- `serverUrl` 是 http 且主机名不是 loopback 时，`allowInsecureHttp` 必须 true；走 nginx HTTPS 就不用。
- `recallRemote` / `captureRemote` 默认 false：agent 从外网连 Magpie（origin=`gateway-key`），不打开这两项会一直 `skipped`。
- `gatewayTimeoutMs` 必须大于 `requestTimeoutMs`；云端 embedding 一次约 1 秒，`requestTimeoutMs` 给 3000 较稳。

### 4. 验证

```bash
curl -fsS "$PC/health/ready" | head -c 300
curl -fsS "$PC/v1/embeddings" -H "Authorization: Bearer $TOKEN" -H 'content-type: application/json' \
  -d '{"model":"openai:google/gemini-embedding-2","input":"test","dimensions":1024}' | head -c 200
```

然后正常对话一轮：Magpie 的 Plugins 页应显示 `ready`（带字节数），Dashboard → Sources 出现该对话，过一个提炼周期后长出 Memory。

### 6. Dashboard 登录 403（反代 / Cloudflare）

Dashboard 的登录表单做了同源校验：`Origin` 的 scheme+host 必须与请求本身一致
（`powercontext/server/dashboard/session.py: same_origin`）。反代没有透出外部 scheme
时，应用看到的是 `http://...`，与浏览器的 `https://...` 不一致 → **403**。

两处都要对：

**a) 容器里放开代理头信任**（compose 已内置）

```yaml
FORWARDED_ALLOW_IPS: "*"
```

uvicorn 默认只信任 `127.0.0.1,::1` 的 `X-Forwarded-*`，而经 docker 发布端口进来的源地址
是网桥网关，会被忽略，于是 scheme 永远停在 http。

**b) nginx 透出外部 scheme 与 host**

宝塔 → 网站 → 反代站点 → 配置文件，在反代 location 里确认：

```nginx
proxy_set_header Host $host;
proxy_set_header X-Forwarded-Proto https;      # 若同时需要 http 访问，用下方 map 版本
proxy_set_header X-Forwarded-Host $host;
proxy_set_header X-Real-IP $remote_addr;
proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
client_max_body_size 50m;
proxy_read_timeout 300s;
```

已有 Cloudflare 在前面时，`$http_x_forwarded_proto` 就是 `https`，也可以直接用
`proxy_set_header X-Forwarded-Proto $http_x_forwarded_proto;`。

**先判断 403 是谁返回的**

```bash
curl -sI https://pc.example.com/dashboard/home | head -20
```

| 响应特征 | 来源 | 处理 |
| --- | --- | --- |
| 有 `X-Dashboard-HTML: 1` | PowerContext | 上面 a+b 两处 |
| `server: nginx` 且 `403 Forbidden` 页面 | nginx | 站点配置里的 deny/目录规则、反代目标写错 |
| `server: cloudflare` + `cf-ray` | Cloudflare | WAF / Bot Fight / Under Attack；临时把 Security Level 调低或加跳过规则 |
