#!/usr/bin/env bash
#
# assemble-codenet-sdk.sh
#
# 把「官方 .NET SDK 骨架」与「CodeNet 修复版运行时」组装成一套可用的 CodeNetSDK。
#
# 组装步骤的依据见 HANDOFF-2026-10-02-CodeNet.md 第 3 节。历史上这套组装是纯手工做的
# （官方 SDK + 手工覆盖 signalfix 的 4 个原生库 + packs 覆盖 + tar 打包），结果是：
#   - SDK 资产不可复现，CodeNet 更新后没人知道怎么重做；
#   - 只能靠 `gh release upload --clobber` 覆盖，和 CI 的运行时包抢同一个资产名。
# 本脚本把第 3 节的步骤固化下来，供 CI 调用（.github/workflows/build-codenet-sdk.yml）。
#
# 输入三样：
#   1. 官方 .NET SDK 骨架   —— --skeleton <目录|.tar.gz>，不给则按 --sdk-version 自动下载
#   2. CodeNet 运行时输出   —— --runtime <目录|.tar.gz>，即 build-codenet.yml 的产物
#                              （平铺目录，含 libcoreclr/libclrjit/libclrgc/libclrgcexp、
#                                libhostfxr、libhostpolicy 与 codenet/dotnet 两个 muxer）
#   3. 目标架构             —— --arch arm64|x64
#
# 产出：<out>/dotnet11x64/.....，顶层目录名必须是 dotnet11x64（下游 tar xzf 后访问
#       $DEST/dotnet11x64/dotnet）。加 --package 时另产 <out>/dotnet-codenet-<rid>.tar.gz。
#
# 用法示例：
#   ./assemble-codenet-sdk.sh --arch arm64 \
#     --runtime ./runtime-osx-arm64 \
#     --out ./artifacts/sdk/osx-arm64 \
#     --package
#
set -euo pipefail

SCRIPT_NAME="$(basename "$0")"

# 官方 SDK 骨架的下载源。dotnetcli.azureedge.net 是同一份内容的 CDN 别名，
# 两者都可直连；默认走 builds.dotnet.microsoft.com（新域名）。
SDK_FEED_BASE="${SDK_FEED_BASE:-https://builds.dotnet.microsoft.com/dotnet/Sdk}"

# CodeNet 修复的核心原生库（signalfix，见 HANDOFF 第 3 节）。
# 其中 coreclr/clrjit/clrgc 三个必须存在；clrgcexp 视构建配置而定，缺失只告警。
REQUIRED_NATIVES="libcoreclr libclrjit libclrgc"
OPTIONAL_NATIVES="libclrgcexp"

ARCH=""
OUT_DIR=""
RUNTIME_PATH=""
SKELETON_PATH=""
SDK_VERSION="10.0.400"
PACKAGE=0
VERIFY_RUN=1
KEEP_SKELETON=0

usage() {
    sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

log()  { printf '[%s] %s\n' "$SCRIPT_NAME" "$*"; }
warn() { printf '[%s] ::warning::%s\n' "$SCRIPT_NAME" "$*" >&2; }
die()  { printf '[%s] ::error::%s\n' "$SCRIPT_NAME" "$*" >&2; exit 1; }

# 注意：变量后面紧跟中文全角标点时，有些 locale 下 bash 会把多字节字符并进变量名，
# 在 `set -u` 下直接报 unbound variable。凡变量后接非 ASCII 字符一律写成 ${var}。
while [ $# -gt 0 ]; do
    case "$1" in
        --arch)         ARCH="${2:-}"; shift 2 ;;
        --out)          OUT_DIR="${2:-}"; shift 2 ;;
        --runtime)      RUNTIME_PATH="${2:-}"; shift 2 ;;
        --skeleton)     SKELETON_PATH="${2:-}"; shift 2 ;;
        --sdk-version)  SDK_VERSION="${2:-}"; shift 2 ;;
        --package)      PACKAGE=1; shift ;;
        --no-verify-run) VERIFY_RUN=0; shift ;;
        -h|--help)      usage 0 ;;
        *) die "未知参数：${1}（--help 查看用法）" ;;
    esac
done

[ -n "$ARCH" ]      || die "缺少 --arch（arm64|x64）"
[ -n "$OUT_DIR" ]   || die "缺少 --out"
[ -n "$RUNTIME_PATH" ] || die "缺少 --runtime"

# ---------------------------------------------------------------------------
# 1. 平台相关命名
# ---------------------------------------------------------------------------
case "$ARCH" in
    arm64) ;;
    x64)   ;;
    *) die "不支持的 --arch：${ARCH}（仅 arm64|x64）" ;;
esac

# 目前只有 macOS 需要 SDK 资产（SulfurLauncher / MChub 都是 tar xzf 后走 dotnet11x64/dotnet）。
# 骨架下载源按 RID 拼，扩展名与原生库前缀按平台定。
RID="osx-${ARCH}"
NATIVE_EXT="dylib"
HOSTPOLICY="libhostpolicy.${NATIVE_EXT}"
HOSTFXR="libhostfxr.${NATIVE_EXT}"
FXR_DIRNAME="fxr"

# ---------------------------------------------------------------------------
# 2. 准备运行时修复件
# ---------------------------------------------------------------------------
WORK_DIR="$OUT_DIR/.work"
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"

RUNTIME_DIR="$RUNTIME_PATH"
if [ -f "$RUNTIME_PATH" ]; then
    case "$RUNTIME_PATH" in
        *.tar.gz|*.tgz)
            log "解压 CodeNet 运行时包：$RUNTIME_PATH"
            RUNTIME_DIR="$WORK_DIR/runtime"
            mkdir -p "$RUNTIME_DIR"
            tar xzf "$RUNTIME_PATH" -C "$RUNTIME_DIR"
            ;;
        *) die "--runtime 只接受目录或 .tar.gz：$RUNTIME_PATH" ;;
    esac
fi
[ -d "$RUNTIME_DIR" ] || die "--runtime 不是有效目录：$RUNTIME_PATH"

# 运行时目录可能是平铺的，也可能外面多套一层（history: CI 打包用 `tar -C dir .`，是平铺）。
if [ ! -f "$RUNTIME_DIR/libcoreclr.${NATIVE_EXT}" ]; then
    inner="$(find "$RUNTIME_DIR" -maxdepth 2 -name "libcoreclr.${NATIVE_EXT}" -print -quit 2>/dev/null || true)"
    [ -n "$inner" ] || die "运行时目录里找不到 libcoreclr.${NATIVE_EXT}：$RUNTIME_DIR"
    RUNTIME_DIR="$(dirname "$inner")"
fi

# 逐项校验输入齐全 —— 缺任何一项都会让产物变成「有运行时但起不来」的半成品。
for base in $REQUIRED_NATIVES; do
    [ -f "$RUNTIME_DIR/${base}.${NATIVE_EXT}" ] \
        || die "运行时缺少 ${base}.${NATIVE_EXT}；目录内容：$(ls "$RUNTIME_DIR" | tr '\n' ' ')"
done
for base in $OPTIONAL_NATIVES; do
    [ -f "$RUNTIME_DIR/${base}.${NATIVE_EXT}" ] \
        || warn "运行时没有 ${base}.${NATIVE_EXT}，将跳过（该构建配置可能未产出）"
done
for f in "$HOSTFXR" "$HOSTPOLICY" codenet dotnet; do
    [ -f "$RUNTIME_DIR/$f" ] || die "运行时缺少 ${f}（宿主未被打进运行时包？）"
done

# ---------------------------------------------------------------------------
# 3. 准备官方 SDK 骨架
# ---------------------------------------------------------------------------
TOP_DIR="$OUT_DIR/dotnet11x64"
rm -rf "$TOP_DIR"
mkdir -p "$TOP_DIR"

SKELETON_TARBALL=""
if [ -n "$SKELETON_PATH" ]; then
    case "$SKELETON_PATH" in
        *.tar.gz|*.tgz) SKELETON_TARBALL="$SKELETON_PATH" ;;
        *) [ -d "$SKELETON_PATH" ] || die "--skeleton 不是有效目录或压缩包：$SKELETON_PATH"
           log "复制骨架目录：$SKELETON_PATH"
           cp -R "$SKELETON_PATH/." "$TOP_DIR/" ;;
    esac
else
    SKELETON_TARBALL="$WORK_DIR/dotnet-sdk-${SDK_VERSION}-${RID}.tar.gz"
    url="${SDK_FEED_BASE}/${SDK_VERSION}/dotnet-sdk-${SDK_VERSION}-${RID}.tar.gz"
    log "下载官方 .NET SDK 骨架：$url"
    curl -fSL --retry 3 --retry-delay 5 -o "$SKELETON_TARBALL" "$url" \
        || die "骨架下载失败：$url"
fi

if [ -n "$SKELETON_TARBALL" ]; then
    log "解压骨架：$SKELETON_TARBALL"
    tar xzf "$SKELETON_TARBALL" -C "$TOP_DIR"
fi

# 官方 macOS SDK 压缩包是平铺解压，但如果外面多套了一层（例如某些镜像重新打包过），
# 这里把它拉平，保证顶层就是 dotnet / sdk / shared / packs / host。必须放在布局校验之前。
if [ ! -e "$TOP_DIR/dotnet" ]; then
    inner="$(find "$TOP_DIR" -maxdepth 4 -type f -name dotnet -print -quit 2>/dev/null || true)"
    [ -n "$inner" ] || die "骨架里找不到 dotnet 可执行文件：$TOP_DIR"
    nested="$(dirname "$inner")"
    log "骨架多套了一层目录，拉平：$nested"
    for entry in "$nested"/* "$nested"/.[!.]*; do
        [ -e "$entry" ] || continue
        mv "$entry" "$TOP_DIR/"
    done
fi

[ -d "$TOP_DIR/sdk" ] && [ -d "$TOP_DIR/shared" ] && [ -d "$TOP_DIR/packs" ] && [ -e "$TOP_DIR/dotnet" ] \
    || die "骨架布局不对，缺少 dotnet/sdk/shared/packs：$TOP_DIR"

# ---------------------------------------------------------------------------
# 4. 定位骨架里的版本目录（一律从骨架自身探测，不写死版本号）
# ---------------------------------------------------------------------------
pick_version() {
    # $1 = 目录；取版本号最高的一个子目录名（BSD sort 没有 -V，用数值字段排序）
    ls "$1" 2>/dev/null | sort -t. -k1,1n -k2,2n -k3,3n | tail -n 1
}

SDK_DIR_NAME="$(pick_version "$TOP_DIR/sdk")"
[ -n "$SDK_DIR_NAME" ] || die "骨架 sdk/ 下没有版本目录"
if [ "$SDK_DIR_NAME" != "$SDK_VERSION" ]; then
    warn "骨架里的 SDK 版本是 ${SDK_DIR_NAME}，与 --sdk-version ${SDK_VERSION} 不一致（以骨架为准）"
fi

RT_ROOT="$TOP_DIR/shared/Microsoft.NETCore.App"
RT_DIR_NAME="$(pick_version "$RT_ROOT")"
[ -n "$RT_DIR_NAME" ] || die "骨架 shared/Microsoft.NETCore.App 下没有版本目录"
RT_DIR="$RT_ROOT/$RT_DIR_NAME"

FXR_ROOT="$TOP_DIR/host/$FXR_DIRNAME"
FXR_DIR_NAME="$(pick_version "$FXR_ROOT")"
[ -n "$FXR_DIR_NAME" ] || die "骨架 host/fxr 下没有版本目录"
FXR_DIR="$FXR_ROOT/$FXR_DIR_NAME"

log "骨架 SDK 版本     : $SDK_DIR_NAME"
log "共享框架版本       : $RT_DIR_NAME"
log "hostfxr 版本      : $FXR_DIR_NAME"

# ---------------------------------------------------------------------------
# 5. 记录官方原件指纹 —— 用于证明「确实被替换了」，而不是静默 no-op
# ---------------------------------------------------------------------------
hash_of() { [ -f "$1" ] && shasum -a 256 "$1" | awk '{print $1}' || echo "<absent>"; }

declare_orig() { # 变量名 文件
    printf -v "ORIG_$1" '%s' "$(hash_of "$2")"
}
for base in $REQUIRED_NATIVES $OPTIONAL_NATIVES; do
    declare_orig "$base" "$RT_DIR/${base}.${NATIVE_EXT}"
done

# ---------------------------------------------------------------------------
# 6. 覆盖共享框架原生库（signalfix 的核心）
# ---------------------------------------------------------------------------
log "覆盖共享框架原生库 -> $RT_DIR"
for base in $REQUIRED_NATIVES $OPTIONAL_NATIVES; do
    src="$RUNTIME_DIR/${base}.${NATIVE_EXT}"
    [ -f "$src" ] || continue
    cp -fp "$src" "$RT_DIR/${base}.${NATIVE_EXT}"
done

# hostpolicy 与 hostfxr 也换成 CodeNet 的宿主（保持宿主三件套版本一致）。
# 安装布局里 hostpolicy 就在共享框架目录下，hostfxr 在 host/fxr/<ver>/。
cp -fp "$RUNTIME_DIR/$HOSTPOLICY" "$RT_DIR/$HOSTPOLICY"
cp -fp "$RUNTIME_DIR/$HOSTFXR"    "$FXR_DIR/$HOSTFXR"

# ---------------------------------------------------------------------------
# 7. 覆盖 runtime packs —— 这一步决定 `dotnet publish -r <rid> --self-contained`
#    的产物是否自带修复（已验证自包含发布的原生库取自 SDK 的 packs/，不是只从 NuGet 拉）
# ---------------------------------------------------------------------------
PACK_NATIVE="$TOP_DIR/packs/Microsoft.NETCore.App.Runtime.${RID}/${RT_DIR_NAME}/runtimes/${RID}/native"
if [ -d "$PACK_NATIVE" ]; then
    log "覆盖 runtime pack 原生库 -> $PACK_NATIVE"
    for base in $REQUIRED_NATIVES $OPTIONAL_NATIVES; do
        src="$RUNTIME_DIR/${base}.${NATIVE_EXT}"
        [ -f "$src" ] || continue
        cp -fp "$src" "$PACK_NATIVE/${base}.${NATIVE_EXT}"
    done
else
    warn "未找到 runtime pack 原生目录，自包含发布将拿到未修复的原生库：$PACK_NATIVE"
fi

# ---------------------------------------------------------------------------
# 8. 放宿主 muxer
# ---------------------------------------------------------------------------
cp -fp "$RUNTIME_DIR/codenet" "$TOP_DIR/codenet"
cp -fp "$RUNTIME_DIR/dotnet"  "$TOP_DIR/dotnet"
chmod +x "$TOP_DIR/codenet" "$TOP_DIR/dotnet"

# ---------------------------------------------------------------------------
# 9. 校验产物
# ---------------------------------------------------------------------------
fail=0
check_file() { # 描述 路径
    if [ -f "$2" ]; then log "  OK   $1"; else printf '[%s] ::error::  缺失 %s (%s)\n' "$SCRIPT_NAME" "$1" "$2" >&2; fail=1; fi
}
check_file "共享框架 libcoreclr"  "$RT_DIR/libcoreclr.${NATIVE_EXT}"
check_file "共享框架 libclrjit"   "$RT_DIR/libclrjit.${NATIVE_EXT}"
check_file "共享框架 libclrgc"    "$RT_DIR/libclrgc.${NATIVE_EXT}"
check_file "共享框架 hostpolicy"  "$RT_DIR/$HOSTPOLICY"
check_file "hostfxr"              "$FXR_DIR/$HOSTFXR"
check_file "宿主 muxer codenet"   "$TOP_DIR/codenet"
check_file "宿主 muxer dotnet"    "$TOP_DIR/dotnet"
[ "$fail" -eq 0 ] || die "产物校验失败"

# 被替换的原生库哈希必须与官方原件不同，否则说明覆盖没生效（或拿到了未修复的运行时）
for base in $REQUIRED_NATIVES $OPTIONAL_NATIVES; do
    target="$RT_DIR/${base}.${NATIVE_EXT}"
    [ -f "$target" ] || continue
    new_hash="$(hash_of "$target")"
    orig_var="ORIG_$base"
    orig_hash="${!orig_var}"
    if [ "$orig_hash" = "$new_hash" ]; then
        printf '[%s] ::error::%s 与骨架原件哈希相同，替换未生效\n' "$SCRIPT_NAME" "${base}.${NATIVE_EXT}" >&2
        fail=1
    else
        log "  OK   ${base}.${NATIVE_EXT} 已替换（骨架原件 ${orig_hash:0:12}… -> CodeNet ${new_hash:0:12}…）"
    fi
done
[ "$fail" -eq 0 ] || die "原生库替换校验失败"

# 端到端冒烟：宿主能不能在这套布局上跑起来。跨架构时（x64 骨架跑在 arm64 runner 上）
# 只有装了 Rosetta 才跑得动，这种情况失败只告警不判错。
HOST_ARCH="$(uname -m)"
if [ "$VERIFY_RUN" -eq 1 ]; then
    RUNNER=""
    if [ "$HOST_ARCH" = "$ARCH" ]; then
        RUNNER="direct"
    elif [ "$HOST_ARCH" = "arm64" ] && [ "$ARCH" = "x64" ]; then
        RUNNER="rosetta"
    fi

    case "$RUNNER" in
        direct)
            log "冒烟测试（原生 ${ARCH}）：$TOP_DIR/codenet --version"
            "$TOP_DIR/codenet" --version || die "codenet --version 失败"
            log "已安装 SDK：$("$TOP_DIR/codenet" --list-sdks | tr '\n' ' ')"
            "$TOP_DIR/codenet" --list-sdks | grep -q "$SDK_DIR_NAME" \
                || die "codenet --list-sdks 没有列出 ${SDK_DIR_NAME}，SDK 目录未被识别"
            ;;
        rosetta)
            if arch -x86_64 "$TOP_DIR/codenet" --version >/dev/null 2>&1; then
                log "冒烟测试（Rosetta 下跑 x64）：通过"
                arch -x86_64 "$TOP_DIR/codenet" --list-sdks | grep -q "$SDK_DIR_NAME" \
                    || die "codenet --list-sdks 没有列出 $SDK_DIR_NAME"
            else
                warn "本机无 Rosetta 或 x64 宿主无法运行，跳过冒烟测试"
            fi
            ;;
        *)
            warn "目标架构 $ARCH 与宿主 $HOST_ARCH 不同，跳过冒烟测试"
            ;;
    esac
else
    log "已指定 --no-verify-run，跳过冒烟测试"
fi

# ---------------------------------------------------------------------------
# 10. 打平临时目录，按需打包
# ---------------------------------------------------------------------------
rm -rf "$WORK_DIR"

TARBALL=""
if [ "$PACKAGE" -eq 1 ]; then
    TARBALL="$OUT_DIR/dotnet-codenet-${RID}.tar.gz"
    log "打包：$TARBALL"
    tar czf "$TARBALL" -C "$OUT_DIR" dotnet11x64
fi

log "组装完成：$TOP_DIR"
[ -n "$TARBALL" ] && log "产物包  ：$TARBALL ($(du -h "$TARBALL" | awk '{print $1}'))"
exit 0
