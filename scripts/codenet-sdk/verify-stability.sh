#!/usr/bin/env bash
#
# verify-stability.sh
#
# 在本机验证 CodeNetSDK 的构建稳定性 —— 也就是回归检测「macOS 27 上 SDK CLI 并发 GC 崩溃」。
#
# 为什么需要单独一个脚本：这个崩溃只在 macOS 27 + SIP/AMFI 关闭的环境上出现，
# GitHub Actions 的 macos-latest 复现不了，所以 CI 里加断言没有意义，只能在本机验。
# 崩溃形态（详见 assemble-codenet-sdk.sh 第 9 节）：
#     mark_object_simple1 <- GcStackCrawlCallBack <- EnumerateLiveSlots <- mark_phase
# 规避手段是关闭 SDK CLI 的并发 GC（组装脚本会自动打这个补丁）。
#
# 用法：
#   ./verify-stability.sh                 # 临时建个 console 工程，构建 20 次
#   ./verify-stability.sh --runs 50       # 加大样本
#   ./verify-stability.sh --project ./app # 用指定工程
#   CODENET_ROOT=/path/to/dotnet11x64 ./verify-stability.sh   # 指定被测 SDK
#
set -uo pipefail

RUNS=20
PROJECT=""
CODENET="${CODENET:-codenet}"

usage() { sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }
die() { printf '::error::%s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
    case "$1" in
        --runs)    RUNS="${2:-20}"; shift 2 ;;
        --project) PROJECT="${2:-}"; shift 2 ;;
        -h|--help) usage 0 ;;
        *) die "未知参数：${1}（--help 查看用法）" ;;
    esac
done

command -v "$CODENET" >/dev/null 2>&1 || die "找不到 ${CODENET} 命令（用 CODENET 指定路径）"

WORK=""
if [ -z "$PROJECT" ]; then
    WORK="$(mktemp -d)"
    trap 'rm -rf "$WORK"' EXIT
    echo "创建临时工程：$WORK/app"
    "$CODENET" new console -o "$WORK/app" -n StabilityProbe >/dev/null 2>&1 \
        || die "codenet new console 失败，无法继续"
    PROJECT="$WORK/app"
fi
csproj="$(find "$PROJECT" -maxdepth 1 -name '*.csproj' -print -quit 2>/dev/null || true)"
[ -n "$csproj" ] || die "目录里没有 csproj：$PROJECT"

echo "被测 SDK ：$("$CODENET" where 2>/dev/null || echo '<未知>')"
echo "工程     ：$PROJECT"
echo "轮数     ：$RUNS"
echo

crashes=0   # 被信号打死（SIGSEGV=139 / SIGBUS=138 / SIGABRT=134）
errors=0    # 正常非零退出（编译错误等），不算崩溃
printf '进度：'
for _ in $(seq 1 "$RUNS"); do
    rm -rf "$PROJECT/obj" "$PROJECT/bin"
    "$CODENET" build -c Release >/dev/null 2>&1
    rc=$?
    if [ "$rc" -ge 128 ]; then
        crashes=$((crashes + 1)); printf 'X'
    elif [ "$rc" -ne 0 ]; then
        errors=$((errors + 1)); printf 'E'
    else
        printf '.'
    fi
done
echo
echo

rate=$(awk -v c="$crashes" -v n="$RUNS" 'BEGIN{printf "%.0f", 100*c/n}')
echo "崩溃 $crashes/$RUNS (${rate}%)   其他失败 $errors/$RUNS"

if [ "$crashes" -gt 0 ]; then
    echo "::error::检测到信号崩溃 —— SDK CLI 的并发 GC 大概率没关，检查 sdk/<ver>/dotnet.runtimeconfig.json"
    exit 1
fi
if [ "$errors" -gt 0 ]; then
    echo "::warning::有 $errors 次非崩溃失败，请确认工程本身能正常编译"
fi
echo "通过：$RUNS 次构建无崩溃"
exit 0
