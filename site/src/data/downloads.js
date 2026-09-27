export const REPO = 'https://github.com/Open-code-Studio/CodeNet'
export const RELEASE_TAG = 'sdk-v10.0.400'
export const RELEASES = `${REPO}/releases`
export const RELEASE_BASE = `${REPO}/releases/download/${RELEASE_TAG}`
export const ISSUES = `${REPO}/issues`
export const UPSTREAM = 'https://github.com/dotnet/runtime'
export const WORKFLOW = `${REPO}/actions/workflows/build-codenet.yml`

export const asset = (name) => `${RELEASE_BASE}/${name}`

// 完整 SDK 布局：解压后顶层目录为 dotnet11x64/，可直接作为 SDK 使用。
export const sdkDownloads = [
  {
    id: 'osx-arm64',
    platform: 'macOS',
    arch: 'Apple Silicon',
    asset: 'dotnet-codenet-osx-arm64-fixed.tar.gz',
    note: '含修复运行时的完整 SDK（arm64）。',
    recommended: true
  },
  {
    id: 'osx-x64',
    platform: 'macOS',
    arch: 'Intel',
    asset: 'dotnet-codenet-osx-x64.tar.gz',
    note: '含修复运行时的完整 SDK（x64）。'
  }
]

// 平铺的 CoreCLR + 共享框架运行时包，需并入既有 SDK 使用。
// status: 'released' 表示 Release 上已有资产；'building' 表示尚未发布（CI 构建中），
// 构建成功后把对应条目的 status 改成 'released' 即可显示直链。
export const runtimeDownloads = [
  {
    id: 'linux-x64',
    platform: 'Linux',
    arch: 'x64',
    asset: 'dotnet-codenet-linux-x64.tar.gz',
    note: 'CoreCLR + 共享框架运行时包（平铺布局，需并入既有 SDK 使用）。',
    status: 'released'
  },
  {
    id: 'linux-arm64',
    platform: 'Linux',
    arch: 'arm64',
    asset: 'dotnet-codenet-linux-arm64.tar.gz',
    note: '同 Linux x64，架构为 arm64。',
    status: 'released'
  },
  {
    id: 'win-x64',
    platform: 'Windows',
    arch: 'x64',
    asset: 'dotnet-codenet-win-x64.zip',
    note: '同上（x64，zip 打包）。必须使用当前最新补丁，旧补丁在创建 CoreCLR 时会直接失败。',
    status: 'building'
  },
  {
    id: 'win-arm64',
    platform: 'Windows',
    arch: 'arm64',
    asset: 'dotnet-codenet-win-arm64.zip',
    note: '同上（arm64，zip 打包）。必须使用当前最新补丁，旧补丁在创建 CoreCLR 时会直接失败。',
    status: 'building'
  }
]