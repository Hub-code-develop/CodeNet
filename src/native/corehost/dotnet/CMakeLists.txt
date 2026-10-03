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

# CodeNet 的宿主主程序对外叫 `codenet`（见下方 dotnet 兼容副本）。
add_executable(codenet ${SOURCES})

target_link_libraries(codenet PRIVATE hostmisc fxr_resolver)

add_sanitizer_runtime_support(codenet)

if(NOT CLR_CMAKE_TARGET_WIN32)
    disable_pax_mprotect(codenet)
endif()

install_with_stripped_symbols(codenet TARGETS corehost)

# Windows 版本资源复用上游为 `dotnet` 生成的 version_info.h：
# corehost.proj 只为 HostFiles（dotnet/hostfxr/hostpolicy/comhost/ijwhost/nethost）生成
# hostResourceFiles\<name>\version_info.h，没有 codenet 这一项；不指定资源目录名的话
# native.rc 会因为找不到 version_info.h 报 C1083。第二个参数让它复用 dotnet 那一份。
add_version_info_to_target(codenet dotnet)

if (CLR_CMAKE_HOST_APPLE)
    adhoc_sign_with_entitlements(codenet "${CLR_ENG_NATIVE_DIR}/entitlements.plist")
endif()

# 兼容副本：同一个 muxer 再以 `dotnet` 的名字产出一份。上游多处按 `dotnet` 取宿主，
# 两个位置都必须补齐，缺任何一个都会让构建失败：
#   - externals.csproj 的 DotnetExe / installers/dotnet-host.proj 读的是 install 目录
#     （artifacts/bin/<rid>.<config>/corehost），见下面 install(RENAME)
#   - 构建输出目录同样保留一份，供其它按目标输出路径取宿主的链路使用
#   - 下游（SulfurLauncher / MChub 的 CI）与既有脚本仍以 `dotnet` 调用宿主
add_custom_command(TARGET codenet POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
            "$<TARGET_FILE:codenet>"
            "$<TARGET_FILE_DIR:codenet>/dotnet${CMAKE_EXECUTABLE_SUFFIX}"
    COMMENT "CodeNet: emitting 'dotnet' compatibility copy of the host muxer")

# POST_BUILD 只写构建输出目录，而 externals.csproj / dotnet-host.proj 读的是 install 目录，
# 因此这里必须再装一份 `dotnet`，否则报 MSB3030（复制不到 corehost/dotnet）。
install(PROGRAMS $<TARGET_FILE:codenet> DESTINATION corehost RENAME dotnet${CMAKE_EXECUTABLE_SUFFIX})
