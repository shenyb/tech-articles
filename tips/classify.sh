#!/usr/bin/env bash
# 自动归类 tips 笔记到对应子目录
# 用法: ./classify.sh              # 归类 tips/ 下所有未归类的 .md
#        ./classify.sh 文件名.md   # 归类单个文件

set -euo pipefail

TIP_DIR="$(cd "$(dirname "$0")" && pwd)"

classify() {
    local file="$1"
    local basename
    basename="$(basename "$file")"

    # 跳过已在子目录中的文件
    local relpath
    relpath="$(realpath --relative-to="$TIP_DIR" "$file" 2>/dev/null || echo "$file")"
    if [[ "$relpath" == */*/* ]]; then
        return
    fi

    local content
    content="$(cat "$file")"

    # 关键字 → 目录映射 (按优先级从高到低)
    if echo "$content" | grep -qi "docker\|kubesphere\|k8s\|kubernetes\|helm\|istio\|cgroup\|kernel\|linux\|buffer io\|滚动升级\|蓝绿\|SLB\|OPS\|限速"; then
        dest="devops"
    elif echo "$content" | grep -qi "Redis\|MySQL\|postgres\|sql\|数据源\|分表\|shard\|事务\|索引\|连接池"; then
        dest="db"
    elif echo "$content" | grep -qi "Java\|Spring\|MyBatis\|SCF\|JVM\|线程\|并发\|Maven\|Gradle"; then
        dest="java"
    elif echo "$content" | grep -qi "Go\|golang\|goroutine\|channel\|interface"; then
        dest="go"
    elif echo "$content" | grep -qi "架构\|设计模式\|DDD\|事件驱动\|CQRS\|分层\|微服务\|设计理念"; then
        dest="architecture"
    elif echo "$content" | grep -qi "hermes\|git\|vim\|curl\|jq\|homebrew\|brew\|工具"; then
        dest="tools"
    else
        dest="other"
    fi

    mv "$file" "$TIP_DIR/$dest/$basename"
    echo "→ $basename  → $dest/"
}

if [[ $# -eq 0 ]]; then
    for f in "$TIP_DIR"/*.md; do
        [[ -f "$f" ]] && classify "$f"
    done
else
    for f in "$@"; do
        classify "$f"
    done
fi
echo "done."
