# Licensed to the .NET Foundation under one or more agreements.
# The .NET Foundation licenses this file to you under the MIT license.

if(CLR_CMAKE_TARGET_WIN32)
    list(APPEND SOURCES
        dotnet.manifest
        dotnet.rc)
endif()

list(APPEND SOURCES
    ../apphost/standalone/hostfxr_resolver.cpp
    ../corehost.cpp
)

# 目标名必须保持上游的 `dotnet`：corehost.proj 的 HostFiles 项、libraries/externals.csproj
# 与 installer 的 dotnet-host.proj 都按 `dotnet` 取宿主，改名会让这三处构建同时失败：
#   - Windows: native.rc 找不到 version_info.h（HostFiles 项里没有 codenet，版本信息不会生成）
#   - macOS/Linux: MSB3030，复制不到 artifacts/bin/<rid>.Release/corehost/dotnet
add_executable(dotnet ${SOURCES})

target_link_libraries(dotnet PRIVATE hostmisc fxr_resolver)

add_sanitizer_runtime_support(dotnet)

if(NOT CLR_CMAKE_TARGET_WIN32)
    disable_pax_mprotect(dotnet)
endif()

install_with_stripped_symbols(dotnet TARGETS corehost)
add_version_info_to_target(dotnet)

if (CLR_CMAKE_HOST_APPLE)
    adhoc_sign_with_entitlements(dotnet "${CLR_ENG_NATIVE_DIR}/entitlements.plist")
endif()

# CodeNet 对外额外提供 `codenet` 命令，内容是同一个 muxer 的副本。
install(PROGRAMS $<TARGET_FILE:dotnet> DESTINATION corehost RENAME codenet)
