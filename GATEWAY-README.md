# Validation Benchmarks Gateway

用一个 Nginx 网关，通过路径 `/xben-NNN/` 统一访问各个 benchmark 环境。

## 工作原理

```
浏览器 → http://localhost:8080/xben-001/...
            │
            ▼
   ┌─────────────────────┐   benchmark-net (共享网络)
   │  Nginx 网关 :8080    │──────────────┬──────────────┐
   │  /xben-NNN/ → 反代   │              │              │
   └─────────────────────┘              ▼              ▼
                                  别名 xben-001     别名 xben-099
                                  ┌──────────┐     ┌──────────┐
                                  │ XBEN-001 │     │ XBEN-099 │
                                  │ app + db │     │ app+mongo│
                                  └──────────┘     └──────────┘
                                  各自独立 compose，内部 db/mongodb 主机名不变
```

关键设计（也是之前“构建完就停”的根因修复）：

- **每个 benchmark 用它自己的 docker-compose 启动**，完全保留内部服务名。比如
  XBEN-001 的 app 通过主机名 `db` 连 MySQL —— 绝不重命名、不破坏。
- 通过一个共享外部网络 `benchmark-net`，给每个 benchmark 的**主服务**挂一个网络
  别名 `xben-NNN`。网关只需反代到这个别名即可，无需暴露任何数据库端口。
- **主服务 = compose 里用 `ports` 对外发布端口的那个服务**（web 入口）；数据库/内部
  服务都用 `expose`，只在各自内网可见，不会被网关代理。这一识别方式对全部 104 个
  benchmark 100% 准确。
- Nginx 用 `resolver 127.0.0.11`（Docker 内置 DNS）**在请求时**解析别名，所以
  只启动一部分 benchmark 也能正常工作，未启动的只返回 502，不会让网关起不来。
- 每个 benchmark 的容器监听端口各不相同（80/3000/5000/8080…），由
  `gateway/ports.map`（自动生成）告诉 nginx 转发到正确端口。

## 快速开始

> 强烈建议先用 1 个 benchmark 验证整条链路，再逐步扩大范围。

```bash
# 先跑通 1 号
./start-gateway.sh start --start 1 --end 1
# 浏览器打开：
#   http://localhost:8080         （导航页）
#   http://localhost:8080/xben-001/   （XBEN-001 环境）

# 没问题后再扩大范围，例如启动 1-10
./start-gateway.sh start --start 1 --end 10
```

## 命令

```bash
./start-gateway.sh start [--start N --end M]   # 构建(按需)并启动 benchmark + 网关
./start-gateway.sh build [--start N --end M]   # 仅构建镜像
./start-gateway.sh stop  [--start N --end M]   # 停止容器（保留，可快速再 start）
./start-gateway.sh down  [--start N --end M]   # 停止并移除容器/网络/override（彻底清理）
./start-gateway.sh status                      # 查看运行状态
./verify-config.sh                             # 分析每个 benchmark 的主服务与端口
```

默认范围是 1–104。

## 用 GitHub Actions 预构建镜像，本地只 pull（推荐）

不想在本地慢慢 `make build`（还要处理 EOL 源等问题）时，可让 CI 在云端构建好所有镜像并推到
GHCR，本地只拉取。

### 1) 在 GitHub 上触发构建

工作流文件：`.github/workflows/build-images.yml`。

- 进入仓库 **Actions** → **Build and push benchmark images** → **Run workflow**（可在
  `filter` 里填 `XBEN-001-24` 或 `XBEN-00*-24` 只构建部分；留空=全部）。
- 它会矩阵并行地对每个 benchmark 跑 `make build`，并把产出的镜像推到
  `ghcr.io/<owner>/xben-NNN-24-<service>:latest`。

镜像默认是**私有**包。要么把对应 package 在 GitHub 上设为 Public，要么本地拉取前先登录：

```bash
echo <你的_PAT_含read:packages> | docker login ghcr.io -u le31ei --password-stdin
```

### 2) 本地用 --pull 启动（不再本地构建）

```bash
docker network create benchmark-net 2>/dev/null
./start-gateway.sh start --pull --start 1 --end 104
```

`--pull` 模式下脚本会从 GHCR 拉取每个服务的镜像并打回 compose 期望的本地名，再
`up --no-build`（绝不本地构建）。owner 非 le31ei 时用 `--owner <你的用户名>` 或环境变量
`GHCR_OWNER` 指定。

## 依赖

`docker`、`docker compose` 插件、`jq`、`openssl`（`make build` 需要）。
macOS 可用 `brew install jq` 安装 jq。

## 注意：Docker 网络地址池

每个 benchmark 是一个独立 compose 项目，会各自创建一个 Docker 网络。**同时启动很多
个**可能耗尽 Docker 默认地址池，报类似 `could not find an available address` 的错。

应对：
- 分批启动（用 `--start/--end`），用完一批 `down` 再下一批；或
- 在 Docker 守护进程配置更大的 `default-address-pools`（`~/.docker/daemon.json` 或
  Docker Desktop → Settings → Docker Engine）：
  ```json
  { "default-address-pools": [ { "base": "10.200.0.0/16", "size": 24 } ] }
  ```
  改完重启 Docker。

## 已知限制：子路径与绝对路径资源

网关按 `/xben-NNN/` 子路径反代。如果某个 benchmark 的页面用**绝对路径**引用静态资源
（如 `/static/app.js`），在子路径下可能加载不到。大部分 benchmark 是简单页面不受影响；
若遇到，可单独用该 benchmark 自己发布的端口直接访问，或为其加 `sub_filter` 重写。

## 文件说明

```
start-gateway.sh        # 主脚本：构建/启动/停止/清理
verify-config.sh        # 分析各 benchmark 主服务与端口
gateway/
  Dockerfile            # Nginx 网关镜像
  nginx.conf            # 反代配置（resolver + 动态 proxy_pass）
  ports.map             # 编号→容器端口（自动生成）
  index.html            # 导航页
.gateway/overrides/     # 运行时自动生成的 per-benchmark 网络 override
```

## 排错

**构建报 `failed to load cache key: "" failed validation`**：这是 Docker Compose 的
bake 构建路径的已知 bug。脚本已默认用 `COMPOSE_BAKE=false` 绕开；若手动构建也请带上：
`COMPOSE_BAKE=false make build`。

```bash
docker logs benchmark-gateway          # 网关日志
docker logs xben-001-24-<service>-1    # 某 benchmark 容器日志
docker ps --filter name=xben-          # 查看运行中的 benchmark 容器
cat /tmp/xben-001-build.log            # 某 benchmark 构建日志
cat /tmp/xben-001-up.log               # 某 benchmark 启动日志
docker network inspect benchmark-net   # 检查共享网络成员与别名
```
