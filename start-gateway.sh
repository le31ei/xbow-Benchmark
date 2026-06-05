#!/bin/bash

# Validation Benchmarks Gateway 启动脚本
#
# 设计要点：
# - 每个 benchmark 用它自己的 docker-compose 启动（保留内部服务名，如 db/mongodb），
#   绝不破坏 app 到数据库的连接（app 通过主机名 "db" 连 MySQL）。
# - 通过一个共享外部网络 benchmark-net，给每个 benchmark 的“主服务”挂一个
#   网络别名 xben-NNN，nginx 网关据此把 /xben-NNN/ 反代到对应容器。
# - “主服务”= 在 compose 里对外发布端口(ports)的那个服务；数据库等用 expose，不发布。
# - 用 `make build` 构建，保证 FLAG 构建参数正确注入。

set -euo pipefail

# ---------- 配置 ----------
BENCHMARKS_DIR="benchmarks"
GATEWAY_DIR="gateway"
OVERRIDE_DIR=".gateway/overrides"
NETWORK="benchmark-net"
GATEWAY_IMAGE="benchmark-gateway:latest"
GATEWAY_PROJECT="benchmark-gateway"
GATEWAY_PORT="8080"
START_INDEX=1
END_INDEX=104

# 镜像来源：默认本地 make build；--pull 时改为从 GHCR 拉取预构建镜像
PULL_MODE=0
REGISTRY="ghcr.io"
GHCR_OWNER="${GHCR_OWNER:-le31ei}"   # 可用环境变量 GHCR_OWNER 覆盖

# ---------- 日志 ----------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[ OK ]${NC} $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error()   { echo -e "${RED}[FAIL]${NC} $1"; }

# ---------- 依赖检查 ----------
check_dependencies() {
    command -v docker >/dev/null || { log_error "缺少 docker"; exit 1; }
    docker compose version >/dev/null 2>&1 || { log_error "缺少 docker compose 插件"; exit 1; }
    command -v jq >/dev/null || { log_error "缺少 jq（用于解析 compose 配置）"; exit 1; }
    command -v openssl >/dev/null || { log_error "缺少 openssl（make build 需要）"; exit 1; }
}

benchmark_dir() { echo "$BENCHMARKS_DIR/XBEN-$1-24"; }
compose_file()  { echo "$(benchmark_dir "$1")/docker-compose.yml"; }
project_name()  { echo "xben-$1-24"; }
override_file() { echo "$OVERRIDE_DIR/$1.yml"; }

# 主服务 = 对外发布端口的服务
get_main_service() {
    docker compose -f "$1" config --format json 2>/dev/null \
        | jq -r '.services | to_entries[] | select((.value.ports // []) | length > 0) | .key' | head -n1
}

# 主服务当前挂载的网络（隐式 default 时返回 default）
get_main_nets() {
    docker compose -f "$1" config --format json 2>/dev/null \
        | jq -r --arg m "$2" '.services[$m].networks // {"default":null} | keys[]'
}

# 确保共享网络存在
ensure_network() {
    docker network inspect "$NETWORK" >/dev/null 2>&1 || {
        log_info "创建共享网络 $NETWORK"
        docker network create "$NETWORK" >/dev/null
    }
}

# 生成单个 benchmark 的 override（挂别名到共享网络，并保留其原有网络）
write_override() {
    local num=$1 file=$2 main=$3
    mkdir -p "$OVERRIDE_DIR"
    local ov=$(override_file "$num")

    {
        echo "networks:"
        echo "  $NETWORK:"
        echo "    external: true"
        echo "services:"
        echo "  $main:"
        echo "    networks:"
        # 保留主服务原有网络
        while IFS= read -r net; do
            [ -n "$net" ] && echo "      $net: {}"
        done < <(get_main_nets "$file" "$main")
        # 追加共享网络 + 别名 xben-NNN
        echo "      $NETWORK:"
        echo "        aliases:"
        echo "          - xben-$num"
    } > "$ov"
}

# 构建单个 benchmark（用 make 保证 FLAG 正确）
build_one() {
    local num=$1; local dir=$(benchmark_dir "$num")
    [ -f "$dir/docker-compose.yml" ] || return 1
    log_info "构建 XBEN-$num-24 ..."
    # COMPOSE_BAKE=false 绕开 compose bake 构建路径的 "" failed validation bug
    if ( cd "$dir" && COMPOSE_BAKE=false make build ) >"/tmp/xben-$num-build.log" 2>&1; then
        return 0
    else
        log_error "XBEN-$num-24 构建失败，详见 /tmp/xben-$num-build.log"
        return 1
    fi
}

# 从 GHCR 拉取该 benchmark 的镜像，并打回 compose 期望的本地名（<proj>-<service>）
pull_one() {
    local num=$1
    local file=$(compose_file "$num")
    local proj=$(project_name "$num")
    local s="" img="" dst=""
    while IFS= read -r s; do
        [ -n "$s" ] || continue
        img="${proj}-${s}"
        dst="$REGISTRY/$GHCR_OWNER/${img}:latest"
        if ! docker pull "$dst" >"/tmp/xben-$num-pull.log" 2>&1; then
            log_error "拉取 $dst 失败，详见 /tmp/xben-$num-pull.log（私有包需先 docker login ghcr.io）"
            return 1
        fi
        docker tag "$dst" "$img"
    done < <(docker compose -f "$file" config --services 2>/dev/null)
    return 0
}

# 启动单个 benchmark
start_one() {
    local num=$1
    local file=$(compose_file "$num")
    [ -f "$file" ] || { log_warn "XBEN-$num-24 无 docker-compose.yml，跳过"; return 1; }

    local main=$(get_main_service "$file")
    if [ -z "$main" ]; then
        log_warn "XBEN-$num-24 找不到对外端口的主服务，跳过"
        return 1
    fi

    local up_extra=""
    if [ "$PULL_MODE" -eq 1 ]; then
        log_info "拉取 XBEN-$num-24 镜像（$REGISTRY/$GHCR_OWNER）..."
        pull_one "$num" || return 1
        up_extra="--no-build"   # 只用拉到的镜像，绝不本地构建
    else
        build_one "$num" || return 1
    fi
    write_override "$num" "$file" "$main"

    log_info "启动 XBEN-$num-24（主服务: $main, 别名: xben-$num）"
    if docker compose -p "$(project_name "$num")" -f "$file" -f "$(override_file "$num")" up -d $up_extra \
            >"/tmp/xben-$num-up.log" 2>&1; then
        log_success "XBEN-$num-24 已启动 -> http://localhost:$GATEWAY_PORT/xben-$num/"
        return 0
    else
        log_error "XBEN-$num-24 启动失败，详见 /tmp/xben-$num-up.log"
        return 1
    fi
}

# 停止单个 benchmark
stop_one() {
    local num=$1; local file=$(compose_file "$num")
    [ -f "$file" ] || return 0
    local ov=$(override_file "$num")
    local args=(-p "$(project_name "$num")" -f "$file")
    [ -f "$ov" ] && args+=(-f "$ov")
    docker compose "${args[@]}" "$2" >/dev/null 2>&1 || true
}

# 生成 编号->容器端口 映射表，供 nginx 转发到正确端口
generate_ports_map() {
    local out="$GATEWAY_DIR/ports.map"
    {
        echo "# 自动生成：benchmark 编号 -> 容器监听端口"
        echo "map \$bnum \$bport {"
        echo "    default 80;"
        for ((i=1; i<=104; i++)); do
            local num=$(printf "%03d" "$i")
            local f="$BENCHMARKS_DIR/XBEN-$num-24/docker-compose.yml"
            [ -f "$f" ] || continue
            local port=$(docker compose -f "$f" config --format json 2>/dev/null \
                | jq -r 'first(.services[]|select((.ports//[])|length>0)|.ports[0].target)')
            [ -n "$port" ] && [ "$port" != "null" ] && echo "    $num $port;"
        done
        echo "}"
    } > "$out"
}

# 构建并启动网关容器
start_gateway() {
    ensure_network
    log_info "生成端口映射表 ..."
    generate_ports_map
    log_info "构建网关镜像 ..."
    docker build -q -t "$GATEWAY_IMAGE" "$GATEWAY_DIR" >/dev/null
    log_info "启动网关容器 ..."
    docker rm -f "$GATEWAY_PROJECT" >/dev/null 2>&1 || true
    docker run -d --name "$GATEWAY_PROJECT" \
        --network "$NETWORK" \
        -p "$GATEWAY_PORT:80" \
        --restart unless-stopped \
        "$GATEWAY_IMAGE" >/dev/null
    log_success "网关已启动 -> http://localhost:$GATEWAY_PORT"
}

stop_gateway() { docker rm -f "$GATEWAY_PROJECT" >/dev/null 2>&1 || true; }

# ---------- 命令 ----------
cmd_build() {
    check_dependencies
    local ok=0 fail=0
    for ((i=START_INDEX; i<=END_INDEX; i++)); do
        local num=$(printf "%03d" "$i")
        if build_one "$num"; then ok=$((ok+1)); else fail=$((fail+1)); fi
    done
    log_info "构建完成：成功 $ok，失败 $fail"
}

cmd_start() {
    check_dependencies
    ensure_network
    local ok=0 fail=0
    for ((i=START_INDEX; i<=END_INDEX; i++)); do
        local num=$(printf "%03d" "$i")
        if start_one "$num"; then ok=$((ok+1)); else fail=$((fail+1)); fi
    done
    start_gateway
    log_info "启动完成：成功 $ok，失败/跳过 $fail"
    echo ""
    log_success "打开导航页：http://localhost:$GATEWAY_PORT"
}

cmd_stop() {
    log_info "停止所有服务 ..."
    for ((i=START_INDEX; i<=END_INDEX; i++)); do
        stop_one "$(printf "%03d" "$i")" stop
    done
    stop_gateway
    log_success "已停止"
}

cmd_down() {
    log_info "停止并移除所有容器 ..."
    for ((i=START_INDEX; i<=END_INDEX; i++)); do
        stop_one "$(printf "%03d" "$i")" down
    done
    stop_gateway
    docker network rm "$NETWORK" >/dev/null 2>&1 || true
    rm -rf "$OVERRIDE_DIR"
    log_success "已清理"
}

cmd_status() {
    echo "网关:"
    docker ps --filter "name=$GATEWAY_PROJECT" --format "  {{.Names}}\t{{.Status}}\t{{.Ports}}"
    echo "Benchmark 容器:"
    docker ps --filter "name=xben-" --format "  {{.Names}}\t{{.Status}}" | sort
}

show_help() {
    cat <<EOF
用法: $0 <命令> [--start N] [--end M]

命令:
  start      构建(按需)并启动 benchmark + 网关
  build      仅构建镜像
  stop       停止容器（保留，可再次 start 快速拉起）
  down       停止并移除容器、网络、override（彻底清理）
  status     查看运行状态
  full       等同 start

选项:
  --start N    起始编号（默认 1）
  --end M      结束编号（默认 104）
  --pull       从 GHCR 拉取预构建镜像，而不是本地 make build（配合 GitHub Actions）
  --owner X    GHCR 所有者（默认 le31ei，也可用环境变量 GHCR_OWNER）

示例:
  $0 start --start 1 --end 5            # 本地构建并启动 1-5 号
  $0 start --pull --start 1 --end 104   # 拉取 GHCR 预构建镜像启动全部（不本地构建）
  $0 status
  $0 down

提示:
  - 私有 GHCR 包需先登录： echo \$PAT | docker login ghcr.io -u <用户名> --password-stdin
  - 同时启动很多 benchmark 会创建很多 Docker 网络，可能耗尽默认地址池；
    可在 /etc/docker/daemon.json 配置更大的 default-address-pools 后重启 docker。
EOF
}

main() {
    local cmd="${1:-help}"; shift || true
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --start) START_INDEX="$2"; shift 2;;
            --end)   END_INDEX="$2";   shift 2;;
            --pull)  PULL_MODE=1; shift;;
            --owner) GHCR_OWNER="$2"; shift 2;;
            *) log_error "未知参数: $1"; show_help; exit 1;;
        esac
    done

    case "$cmd" in
        start|full) cmd_start;;
        build)      cmd_build;;
        stop)       cmd_stop;;
        down|cleanup) cmd_down;;
        status)     cmd_status;;
        help|-h|--help) show_help;;
        *) log_error "未知命令: $cmd"; show_help; exit 1;;
    esac
}

trap 'log_warn "已中断"; exit 130' INT
main "$@"
