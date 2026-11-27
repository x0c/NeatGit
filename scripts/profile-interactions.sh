#!/bin/bash
set -euo pipefail

# 同时采集 CPU、SwiftUI 更新与应用内的交互 signpost，不激活被测应用。
APP_PATH="${1:-/Applications/NeatGit.app}"
DURATION="${2:-60s}"
if [[ -d "$APP_PATH" ]]; then
    APP_PATH="$(cd "$APP_PATH" && pwd -P)"
fi
EXECUTABLE="$APP_PATH/Contents/MacOS/NeatGit"
OUTPUT_DIR="build/interaction-profiler"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
TRACE_PATH="$OUTPUT_DIR/interactions-$TIMESTAMP.trace"
LOG_PATH="$OUTPUT_DIR/interactions-$TIMESTAMP.log"
TOC_PATH="$OUTPUT_DIR/interactions-$TIMESTAMP-toc.xml"
SIGNPOSTS_PATH="$OUTPUT_DIR/interactions-$TIMESTAMP-signposts.xml"
SUMMARY_PATH="$OUTPUT_DIR/interactions-$TIMESTAMP-summary.txt"
JSON_PATH="$OUTPUT_DIR/interactions-$TIMESTAMP-summary.json"

if [[ ! -x "$EXECUTABLE" ]]; then
    echo "找不到可执行应用：$APP_PATH" >&2
    exit 1
fi

find_pid() {
    ps -axo pid=,comm= | while read -r pid command_path; do
        if [[ "$command_path" == "$EXECUTABLE" ]]; then
            echo "$pid"
            return 0
        fi
    done
}

PID="$(find_pid || true)"
if [[ -z "$PID" ]]; then
    open -g "$APP_PATH"
    for _ in {1..20}; do
        sleep 0.25
        PID="$(find_pid || true)"
        [[ -n "$PID" ]] && break
    done
fi

if [[ -z "$PID" ]]; then
    echo "应用已启动，但未找到匹配该安装路径的进程。" >&2
    exit 1
fi

mkdir -p "$OUTPUT_DIR"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

echo "开始采集 ${DURATION}：请依次点击项目、文件、分组、刷新、差异模式与布局。"
echo "进程：${PID}；产物：${TRACE_PATH}"
xctrace record \
    --template 'Time Profiler' \
    --instrument 'os_signpost' \
    --instrument 'SwiftUI' \
    --attach "$PID" \
    --time-limit "$DURATION" \
    --output "$TRACE_PATH" \
    --no-prompt

xctrace export --input "$TRACE_PATH" --toc --output "$TOC_PATH"
xctrace export --input "$TRACE_PATH" \
    --xpath '/trace-toc/run[@number="1"]/data/table[@schema="os-signpost"]' \
    --output "$SIGNPOSTS_PATH"
python3 scripts/summarize_interactions.py "$SIGNPOSTS_PATH" --json "$JSON_PATH" | tee "$SUMMARY_PATH"
log show --last "$DURATION" --info --debug --style compact \
    --predicate 'subsystem == "io.github.x0c.neatgit" AND category == "Interaction"' \
    > "$LOG_PATH" || true

printf '\n采集完成：\n  Instruments：%s\n  区间日志：%s\n  统计摘要：%s\n  数据目录：%s\n' "$TRACE_PATH" "$LOG_PATH" "$SUMMARY_PATH" "$TOC_PATH"
printf '可用 open %q 在 Instruments 中查看；脚本不会自动抢前台。\n' "$TRACE_PATH"
