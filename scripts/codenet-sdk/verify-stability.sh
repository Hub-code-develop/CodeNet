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
#   ./verify-stability.sh --concurrent on # 临时打开 SDK CLI 的并发 GC（做 A/B 对照）
#   CODENET=/path/to/dotnet11x64/dotnet ./verify-stability.sh   # 指定被测 SDK
#
set -uo pipefail

RUNS=20
PROJECT=""
CONCURRENT=""
CODENET="${CODENET:-codenet}"

usage() { sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }
die() { printf '::error::%s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
    case "$1" in
        --runs)       RUNS="${2:-20}"; shift 2 ;;
        --project)    PROJECT="${2:-}"; shift 2 ;;
        --concurrent) CONCURRENT="${2:-}"; shift 2 ;;
        -h|--help)    usage 0 ;;
        *) die "未知参数：${1}（--help 查看用法）" ;;
    esac
done

case "$CONCURRENT" in
    ""|on|off) ;;
    *) die "--concurrent 只接受 on / off（收到 $CONCURRENT）" ;;
esac

command -v "$CODENET" >/dev/null 2>&1 || die "找不到 ${CODENET} 命令（用 CODENET 指定路径）"

# 用绝对路径指向一套 CodeNetSDK 时必须自己补 DOTNET_ROOT：宿主 muxer 靠它定位
# shared/ 与 sdk/。不设的话 `new` 还可能成功，但 `build` 会整片失败（不是崩溃，是 rc=1），
# 会让统计里全是 E 而没有 X。
case "$CODENET" in
    */*) CODENET="$(cd "$(dirname "$CODENET")" && pwd)/$(basename "$CODENET")" ;;
esac
if [ -z "${DOTNET_ROOT:-}" ] && [ -f "$(dirname "$CODENET")/dotnet" ]; then
    export DOTNET_ROOT="$(dirname "$CODENET")"
fi

WORK=""
RC_BAK=""
RC_TARGET=""
cleanup() {
    if [ -n "$RC_BAK" ] && [ -n "$RC_TARGET" ] && [ -f "$RC_BAK" ]; then
        mv -f "$RC_BAK" "$RC_TARGET"
    fi
    [ -n "$WORK" ] && rm -rf "$WORK"
    return 0
}
trap cleanup EXIT

if [ -z "$PROJECT" ]; then
    WORK="$(mktemp -d)"
    echo "创建临时工程：$WORK/app"
    # 建工程这一步本身就可能被并发 GC 崩掉（实测 macOS 27 上 ~1/3 概率），重试即可。
    ok=0
    for _ in 1 2 3 4 5; do
        rm -rf "$WORK/app"
        if "$CODENET" new console -o "$WORK/app" -n StabilityProbe >/dev/null 2>&1; then ok=1; break; fi
    done
    [ "$ok" = 1 ] || die "codenet new console 连续失败，无法继续"
    PROJECT="$WORK/app"
fi
csproj="$(find "$PROJECT" -maxdepth 1 -name '*.csproj' -print -quit 2>/dev/null || true)"
[ -n "$csproj" ] || die "目录里没有 csproj：$PROJECT"

SDK_RC=""
if [ -n "${DOTNET_ROOT:-}" ] && [ -d "$DOTNET_ROOT/sdk" ]; then
    SDK_RC="$(find "$DOTNET_ROOT/sdk" -maxdepth 2 -name 'dotnet.runtimeconfig.json' -print -quit 2>/dev/null || true)"
fi

# --concurrent 直接改 SDK 自己的 runtimeconfig 再还原：环境变量 DOTNET_gcConcurrent
# 在 configProperties 已经写了同名键时不一定压得住，做 A/B 对照必须走文件才确定。
if [ -n "$CONCURRENT" ]; then
    [ -n "$SDK_RC" ] && [ -f "$SDK_RC" ] || die "--concurrent 需要定位到 SDK 的 dotnet.runtimeconfig.json（先设 DOTNET_ROOT）"
    want=$([ "$CONCURRENT" = "on" ] && echo true || echo false)
    RC_BAK="$SDK_RC.$$.bak"
    RC_TARGET="$SDK_RC"
    cp -p "$SDK_RC" "$RC_BAK"
    python3 - "$SDK_RC" "$want" <<'PYEOF' || die "改写 runtimeconfig 失败（需要 python3）"
import json, sys
path, value = sys.argv[1], sys.argv[2] == "true"
with open(path) as fh:
    cfg = json.load(fh)
props = cfg.setdefault("runtimeOptions", {}).setdefault("configProperties", {})
props["System.GC.Concurrent"] = value
with open(path, "w") as fh:
    json.dump(cfg, fh, indent=2)
    fh.write("\n")
PYEOF
    echo "已临时把 SDK CLI 的并发 GC 设为 ${want}（脚本退出时还原）"
fi

echo "被测 SDK ：${DOTNET_ROOT:-<未知>}"
if [ -n "$SDK_RC" ]; then
    echo "SDK 配置 ：$SDK_RC"
    echo "并发 GC  ：$(grep -o '"System.GC.Concurrent": *[a-z]*' "$SDK_RC" | tail -1 | sed 's/.*: *//')"
fi
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
