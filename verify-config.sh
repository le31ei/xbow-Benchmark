#!/bin/bash
# Benchmark 配置分析：列出每个 benchmark 的主服务（对外端口）、容器端口、所有服务

set -uo pipefail
BENCHMARKS_DIR="benchmarks"
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

command -v jq >/dev/null || { echo "需要 jq"; exit 1; }

echo -e "${BLUE}=== Benchmark 配置分析 ===${NC}"
printf "%-14s %-3s %-32s %-6s %s\n" "名称" "数" "主服务(对外)" "端口" "全部服务"
echo "--------------------------------------------------------------------------------"

total=0; valid=0; multi=0
for ((i=1; i<=104; i++)); do
    num=$(printf "%03d" "$i")
    f="$BENCHMARKS_DIR/XBEN-$num-24/docker-compose.yml"
    [ -f "$f" ] || continue
    ((total++))

    json=$(docker compose -f "$f" config --format json 2>/dev/null)
    all=$(echo "$json" | jq -r '.services | keys | join(",")')
    count=$(echo "$json" | jq -r '.services | length')
    main=$(echo "$json" | jq -r '.services | to_entries[] | select((.value.ports//[])|length>0) | .key' | head -n1)
    port=$(echo "$json" | jq -r --arg m "$main" '.services[$m].ports[0].target // ""')

    [ "$count" -gt 1 ] && ((multi++))
    if [ -n "$main" ]; then
        ((valid++))
        printf "XBEN-%s-24  %-3s %-32s %-6s %s\n" "$num" "$count" "$main" "$port" "$all"
    else
        printf "XBEN-%s-24  %-3s ${YELLOW}%-32s${NC} %-6s %s\n" "$num" "$count" "未识别" "" "$all"
    fi
done

echo ""
echo -e "${BLUE}=== 统计 ===${NC}"
echo "总数: $total   已识别主服务: $valid   多服务架构(含数据库等): $multi"
echo ""
echo "说明: 主服务 = compose 中用 ports 对外发布的服务（即 web 入口）；"
echo "      数据库/内部服务用 expose，仅内网可见，不会被网关代理。"
echo -e "${GREEN}✓ 分析完成${NC}"
