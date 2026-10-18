# my_caddy —— xcaddy 自定义 Caddy + GitHub Actions → Docker Hub

用 GitHub Action 跑 `xcaddy build`，把**带插件的 Caddy**打包成多架构 Docker 镜像推到 Docker Hub。
当前内置（`plugins.txt` 可改）：

| 插件 | 模块 ID | 作用 |
| --- | --- | --- |
| `github.com/caddy-dns/cloudflare` | `dns.providers.cloudflare` | Cloudflare DNS-01 签证书（支持通配符，不用暴露 80 端口） |
| `github.com/WeidiDeng/caddy-cloudflare-ip` @`f53b62a` | `http.ip_sources.cloudflare` | 自动拉 CF 官方 IP 段当 `trusted_proxies`，日志/`client_ip` 拿到访客真实 IP |
| `github.com/mholt/caddy-ratelimit` | `http.handlers.rate_limit` | 限流（不需要就从 `plugins.txt` 删掉） |

## 文件结构

```
.
├── .github/workflows/build.yml   # CI：解析参数 → buildx 多架构构建 → 推 Docker Hub → 校验产物
├── Dockerfile                    # 两阶段：caddy:<ver>-builder 里 xcaddy 编译；caddy:<ver> 里运行
├── plugins.txt                   # 插件清单（每行一个，支持 pkg@version / @commit）
├── Caddyfile                     # 默认配置：trusted_proxies cloudflare + :80 健康检查
└── .dockerignore / .gitignore
```

## 凭据清单（需要你生产的）

`WeidiDeng/caddy-cloudflare-ip` 本身**不需要任何凭据**（它只是定时拉 `www.cloudflare.com/ips-v4|v6` 两个公开文本）。真正需要你生产的是下面这些：

| # | 凭据 | 用在哪 | 必需？ | 生产方式 | 权限/范围 |
| --- | --- | --- | --- | --- | --- |
| 1 | Docker Hub **Access Token** | CI 里 `docker/login-action` 推送镜像；存为 GitHub **Secret** `DOCKERHUB_TOKEN` | ✅ 必需 | Docker Hub → 右上头像 → Account settings → **Personal access tokens** → Generate new token，名字如 `gh-actions-my-caddy`，Permissions 选 **Read & write** | 只认账号级；不能限定到单个仓库 → 建议只放在这个仓库的 Secrets 里 |
| 2 | Docker Hub **用户名** | 同上，存为 GitHub **Secret** `DOCKERHUB_USERNAME` | ✅ 必需 | 就是你的 Docker ID（全小写） | — |
| 3 | Docker Hub **仓库名** | CI 决定推 `哪个/仓库:tag`；存为 GitHub **Variable** `DOCKERHUB_REPO`（如 `yourid/caddy`） | ✅ 必需（不配则默认 `<owner>/caddy-custom`） | Docker Hub → Create repository，选 Public/Private | 名字必须全小写 |
| 4 | Cloudflare **API Token** | 只有 Caddyfile 里启用 `tls { dns cloudflare {env.CF_API_TOKEN} }`（DNS-01 通配符证书）才用；推镜像、跑 trusted_proxies 都不需要 | ⬜ 可选 | dash.cloudflare.com → My Profile → **API Tokens** → Create Token → 模板 **Edit zone DNS** | Permissions：`Zone → DNS → Edit` + `Zone → Zone → Read`；Zone Resources：只选你的 zone（如 `5216688.xyz`）；不要用 Global API Key |
| 5 | ACME 邮箱 | `email` 全局项（Let's Encrypt 通知） | ⬜ 可选 | 你自己的邮箱 | — |
| 6 | GHCR（备选镜像仓） | 想同时推 `ghcr.io` | ⬜ 可选 | **不需要生产**，用内置 `secrets.GITHUB_TOKEN`（放开 `permissions.packages: write` 即可） | — |

GitHub 侧唯一要的额外凭据是「能 push 到本仓库」的 SSH key / PAT（你本地 git 已经在用），和上面这些无关。

不需要凭据但必须满足的运行时条件：

- 容器**能出网访问 `https://www.cloudflare.com/ips-v4|v6`**（否则列表为空，且插件**静默失败不报错**，真实 IP 会退回 peer IP）；
- Caddyfile 里用了 `{env.CF_API_TOKEN}` 时，容器必须注入该环境变量（Swarm 里建议用 secret + `{file./run/secrets/cf_api_token}` 占位符，别把 token 写进镜像/Caddyfile）。

### 凭据放哪（填值即可，已生成占位）

**推荐放 skill 目录**——`D:\Sync` 是 Syncthing 同步目录，填一次就跟着同步到别的电脑：

| 文件（按优先级合并，先命中胜出） | 放什么 | 跨机同步 |
| --- | --- | --- |
| `~/.pi/agent/skills/dockerhub/secrets.env`（真实文件 `D:\Sync\.agents\skills\dockerhub\secrets.env`） | `DOCKERHUB_USERNAME` / `DOCKERHUB_TOKEN` / `DOCKERHUB_REPO` | ✅ Syncthing 自动 |
| `~/.pi/agent/skills/github/secrets.env` | `GH_TOKEN` / `GITHUB_USER` / `GITHUB_REPO`（可选） | ✅ Syncthing 自动 |
| `<repo>/secrets/gh-secrets.env` | 同内容（项目内副本，兼容保留） | ✅（IdeaProjects 也在 D:\Sync 下） |
| `~/.pi/secrets/dockerhub.env` | 旧位置，服务器 `docker login` / licsrv 部署脚本读它 | ❌ 手动 |
| `~/.pi/secrets/my_caddy_runtime.env` | 运行时 `CF_API_TOKEN` / `ACME_EMAIL`（**只有启用 DNS-01 才需要**） | ❌ 手动 |

填完值后一条命令写进 GitHub（`gh` CLI 没装就走脚本打印的手动清单，Secrets 写进去后读不出来，UI 粘贴最稳）：

```powershell
pwsh -File secrets/apply-secrets.ps1                          # 体检各来源 + 尝试写入 Secrets/Variables
pwsh -File secrets/apply-secrets.ps1 -Copy DOCKERHUB_TOKEN     # 只把某个值复制到剪贴板，方便手动贴
pwsh -File secrets/apply-secrets.ps1 -Open                     # 打开仓库 Settings → Secrets 页面
# 想自动写：scoop install gh ; gh auth login（需 repo/workflow 权限）
```

脚本只打印脱敏预览（`dckr…2345 (40 字符)`）并标注每个值来自哪个文件，不会把明文写进日志/终端历史。仓库里的 `secrets/` 已在 `.gitignore` 和 `.dockerignore` 里。

> 网络提醒：本机 **docker.io 域名被 DNS 污染**（实测解析到 `2a03:2880::face:b00c` / `108.160.x.x` 假地址），相关 API 调用要走本机代理 `127.0.0.1:7890`——skill 里的 `dh.py` / `ghapi.py` 已内置自动探测。

### 想完全零凭据（只做 trusted proxies）

把 `plugins.txt` 里 `github.com/caddy-dns/cloudflare` 和 `github.com/mholt/caddy-ratelimit` 两行删掉 → 运行时不需要任何 token；同时把仓库 Variable `EXPECT_MODULES` 改成 `http.ip_sources.cloudflare`（CI 用它断言模块存在，不配默认断言三个）。

## 一次性配置

1. 按上表生产 **① Docker Hub Access Token**、**② 用户名**、**③ 仓库名**。
2. 仓库 **Settings → Secrets and variables → Actions**：
   - Secrets：`DOCKERHUB_USERNAME`、`DOCKERHUB_TOKEN`
   - Variables：`DOCKERHUB_REPO`（如 `youruser/caddy`；不配则默认 `<owner>/caddy-custom`，**必须全小写**）
   - Variables（可选）：`VERIFY_MODULES`（编译后 `grep -E` 校验关键字，默认 `cloudflare`）、`EXPECT_MODULES`（verify job 断言的模块 ID，默认三个插件对应的三个）
3. 推代码触发：

```bash
git add -A && git commit -m "feat: xcaddy custom caddy with cloudflare plugins"
git remote add origin git@github.com:<you>/my_caddy.git   # 如未配置
git push -u origin main
```

## 工作流行为

- 触发：push `main`、push tag `v*`、PR（**只构建不推送**）、每周一 03:00 定时重建、手动 `workflow_dispatch`。
- 手动触发可临时覆盖：`caddy_version`（如 `2.11.7`）、`plugins`（空格分隔，如 `github.com/mholt/caddy-webdav`）、`push_image`。
- 镜像标签：`latest` + `caddy-<版本>`（默认分支）、分支名、git tag、`sha-xxxxxxx`；多架构 `linux/amd64,linux/arm64`。
- `verify` job：拉镜像跑 `caddy list-modules` 断言三个模块存在、`caddy validate` 断言 Caddyfile 能加载（即 `trusted_proxies cloudflare` 真的生效），并把 `caddy-linux-amd64` 作为 artifact 上传（可手动下载到服务器用）。
- 想同时推 GHCR：放开 `permissions.packages: write` 和 `build` 里注释的 GHCR 段。
- 老版本 Docker 拉镜像报 `unknown manifest type` 时，把 `build-push-action` 的 `provenance` 改 `false`。
- arm64 是 QEMU 模拟编译，比较慢；只要 amd64 就把 `env.PLATFORMS` 改成 `linux/amd64`。

## 本地复现（和 CI 完全一样的命令）

```bash
# 编译（Linux 二进制）
xcaddy build v2.11.7 \
  --with github.com/caddy-dns/cloudflare \
  --with github.com/WeidiDeng/caddy-cloudflare-ip@f53b62a \
  --with github.com/mholt/caddy-ratelimit

# 起 Docker 镜像
docker build --build-arg CADDY_VERSION=2.11.7 \
  --build-arg CADDY_PLUGINS="github.com/caddy-dns/cloudflare github.com/WeidiDeng/caddy-cloudflare-ip@f53b62a github.com/mholt/caddy-ratelimit" \
  -t caddy-custom:local .
docker run --rm -p 80:80 -p 443:443 -e CF_API_TOKEN=xxx caddy-custom:local
```

## 部署示例（docker compose）

```yaml
services:
  caddy:
    image: youruser/caddy-custom:latest      # 或 caddy-2.11.7
    restart: unless-stopped
    ports: ["80:80", "443:443", "443:443/udp"]
    environment:
      CF_API_TOKEN: ${CF_API_TOKEN:?cloudflare api token}
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy_data:/data
      - caddy_config:/config
volumes:
  caddy_data:
  caddy_config:
```

## Cloudflare trusted_proxies 插件选型（实测过的搜索结果）

| 插件 | 模块 ID / 用法 | 状态 |
| --- | --- | --- |
| `WeidiDeng/caddy-cloudflare-ip`（★126）**本项目采用** | `http.ip_sources.cloudflare`，`servers { trusted_proxies cloudflare { interval 6h timeout 10s } }` | 2023-11 后未更新，但 **Caddy 2.11.7 实测可编译可生效**；代码只依赖 `caddyhttp.IPRangeSource` + `CIDRExpressionToPrefix`（2.11 仍在），所以已按 commit 固定 |
| `monobilisim/caddy-ip-list`（维护活跃） | `http.ip_sources.list`：`trusted_proxies list { url https://www.cloudflare.com/ips-v4 url https://www.cloudflare.com/ips-v6 interval 12h retries 2 }`，go.mod 要求 caddy ≥ 2.10 | 通用多 URL IP 源 + **本地磁盘缓存**，断网/重启时用上次结果；想要「CF 挂了也能重启」就换成这个 |
| `tuzzmaniandevil/caddy-dynamic-clientip` | 提供 `dynamic_client_ip` matcher，能做**动态**"只允许 CF 回源" | 喜欢动态拦截（而不是静态 CIDR）时搭配使用 |
| Caddy 内置 `http.ip_sources.static` | `servers { trusted_proxies static 173.245.48.0/20 ... }` | 零插件最稳，但 CF 段变了要手动改 |

> 注意：`remote_ip` / `client_ip` 匹配器**只吃静态 CIDR，不支持模块名，也不支持块语法**（所有 CIDR 写在同一行）；动态 IP 源只作用于 `trusted_proxies`（即 `{http.request.remote.host}` / 日志 / `reverse_proxy` 的上游真实 IP）。

### ⚠ 一个 server 只能配一个 `trusted_proxies` 源（踩坑高发点）

Caddy 里 `trusted_proxies` 是 `inline_key=source` 的单模块字段 —— **不能同时写 "CF 段 + 内网段" 两个源**。如果 Caddy 前面还有一层反代/负载均衡（典型：Docker Swarm 用 ingress 发布端口时，回源源 IP 会变成 `10.0.0.2`），那 peer IP 不在 CF 段里 → Caddy 判定连接不可信 → **真实 IP 又丢成 10.0.0.2**。两个解法：

1. **保住真实源 IP（推荐）**：Swarm 里用 host 模式发布端口，绕过 ingress 网络：

   ```yaml
   ports:
     - { target: 80,  published: 80,  mode: host }
     - { target: 443, published: 443, mode: host }
     - { target: 443, published: 443, mode: host, protocol: udp }
   ```

   这样 peer IP 就是 CF 边缘节点 IP，`trusted_proxies cloudflare` 直接生效。

2. **改用 static 并集**（CF 段 + `10.0.0.0/8`），代价是 CF 换段要手动更新（CF 段极少变）。Caddyfile 里已写好这行注释，取消注释即可（`static` 同样不接受块语法，必须一整行）。

   当前 CF 官方网段（2026-10-18 实拉 <https://www.cloudflare.com/ips-v4> + `/ips-v6>`）：

   ```
   173.245.48.0/20 103.21.244.0/22 103.22.200.0/22 103.31.4.0/22 141.101.64.0/18
   108.162.192.0/18 190.93.240.0/20 188.114.96.0/20 197.234.240.0/22 198.41.128.0/17
   162.158.0.0/15 104.16.0.0/13 104.24.0.0/14 172.64.0.0/13 131.0.72.0/22
   2400:cb00::/32 2606:4700::/32 2803:f800::/32 2405:b500::/32 2405:8100::/32
   2a06:98c0::/29 2c0f:f248::/32
   ```

## 兼容性验证（本地实跑，非推测）

```
$ xcaddy build v2.11.7 --with ...(上表三个插件)
$ caddy version      → v2.11.7 h1:yj0Y4fYZGPkSvibBJ1sTWE33xC0fxztVyXEW5iIdUT4=
$ caddy list-modules → 143 个模块，含：
    dns.providers.cloudflare
    http.handlers.rate_limit
    http.ip_sources.cloudflare
$ caddy adapt  → "trusted_proxies":{"interval":21600000000,"source":"cloudflare","timeout":10000000000}
$ caddy validate → Valid configuration
# 顺带实测：`order rate_limit before basicauth` + rate_limit 块、`@not_cf not client_ip <cidrs...>` 均可 adapt
```

Caddy 版本升级：改 `.github/workflows/build.yml` 里的 `DEFAULT_CADDY_VERSION` 和 `Dockerfile` 的 `ARG CADDY_VERSION` 默认值（CI 会用 workflow 里的值覆盖），然后手动跑一次 workflow。
