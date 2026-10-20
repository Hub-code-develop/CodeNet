#!/usr/bin/env bash
# 复现 macOS 27 上的 GC 标记崩溃，并抓 [gcdiag] 现场。
#
# 背景：CodeNet 运行时在 macOS 27 上跑构建负载会随机崩在
#   mark_object_simple1 / GetLoaderAllocatorObjectForGC
# 表现为「堆范围内但不是对象」的内存被当成对象。gc.cpp 里的诊断（CODENET_GC_DIAG）
# 会在候选对象刚通过范围检查时校验它的 MethodTable 字，命中就打印：
#   [gcdiag] bad-obj o=… mtword=… slot=… lowest=… highest=…
# 其中 slot 是引用来源槽的地址：栈地址 ⇒ 栈扫描/GC info；堆地址 ⇒ 卡片扫描/对象字段。
#
# 用法：
#   ./repro-gc-crash.sh                        # 默认 25 轮，SDK 用 ~/dotnet-arm64
#   ./repro-gc-crash.sh --runs 40 --sdk /path/to/sdk
#
# 不需要 `dotnet new`（直接手写 csproj + Program.cs），因为模板引擎本身在低内存下很容易崩。
set -uo pipefail

RUNS=25
SDK="${HOME}/dotnet-arm64"

while [ $# -gt 0 ]; do
    case "$1" in
        --runs) RUNS="${2:-25}"; shift 2 ;;
        --sdk)  SDK="${2:-}";    shift 2 ;;
        -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "未知参数：$1" >&2; exit 2 ;;
    esac
done

DOTNET="$SDK/dotnet"
[ -x "$DOTNET" ] || { echo "找不到可执行的 $DOTNET" >&2; exit 1; }

# 先做个启动体检：这台机器内存打满时，CoreCLR 连初始化都过不去
# （Failed to create CoreCLR, HRESULT: 0x8007054F / 0x8007000E），别把那种失败算成崩溃。
startup_ok=0
for _ in 1 2 3; do
    if "$DOTNET" --version 2>/dev/null | grep -q '^10\.'; then startup_ok=1; break; fi
done
if [ "$startup_ok" -eq 0 ]; then
    echo "运行时连 --version 都起不来：先看 vm.swapusage / memory_pressure，内存不够就别测了。" >&2
    echo "（当前：$(sysctl -n vm.swapusage 2>/dev/null)）" >&2
    exit 3
fi

WORK="$(mktemp -d)"
LOGS="$WORK/logs"
mkdir -p "$LOGS"

export DOTNET_ROOT="$SDK"
export CODENET_TRACE_GC=1 CODENET_TRACE_ACTCTX=1 MSBUILDDISABLENODEREUSE=1

cat > "$WORK/P.csproj" <<'EOF'
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <OutputType>Exe</OutputType>
    <TargetFramework>net10.0</TargetFramework>
  </PropertyGroup>
</Project>
EOF
printf 'class P { static void Main() { System.Console.WriteLine("ok"); } }\n' > "$WORK/Program.cs"
cd "$WORK" || exit 1

crashes=0; ok=0; other=0
for i in $(seq 1 "$RUNS"); do
    rm -rf obj bin
    rc=0
    "$DOTNET" build -c Release > "$LOGS/run-$i.log" 2>&1 || rc=$?
    if [ "$rc" -ge 128 ]; then
        crashes=$((crashes + 1)); echo "run ${i}: CRASH rc=$rc"
    elif [ "$rc" -ne 0 ]; then
        other=$((other + 1)); echo "run ${i}: fail rc=$rc"
    else
        ok=$((ok + 1))
    fi
done

echo
echo "崩溃 ${crashes} / 成功 ${ok} / 其他失败 ${other}（共 ${RUNS} 轮）"
echo "日志目录：${LOGS}"

hits="$(grep -h "\[gcdiag\]" "$LOGS"/run-*.log 2>/dev/null | head -20)"
if [ -n "$hits" ]; then
    echo "---- [gcdiag] 现场 ----"
    echo "$hits"
    # 顺手分类：slot 落在线程栈里还是堆里，决定往哪修。
    echo "---- slot 分类提示 ----"
    echo "栈地址一般形如 0x16xxxxxxxx（macOS 线程栈），堆地址形如 0x1xxxxxxxx / 0x6xxxxxxxxxx。"
else
    echo "没有 [gcdiag] 行：要么没崩，要么崩在不会走到 mark_object_simple 的路径（把 $LOGS 留给我看）。"
fi
