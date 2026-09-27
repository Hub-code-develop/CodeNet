<script setup>
const walls = [
  {
    index: 'WALL #1',
    title: '保持 GS cookie 页可写',
    body: '新版 macOS 将 Guard Segment（GS）cookie 页设为只读，导致部分运行时初始化路径崩溃。Code.NET 改为保持该页可写、不冻结为只读，从根上消除该崩溃。',
    commit: 'macOS: keep GS cookie page writable; do not freeze it read-only'
  },
  {
    index: 'WALL #2',
    title: '基于信号的 SEH / EXC_GUARD 修复',
    body: '原版 .NET 在新版 macOS 上创建 CoreCLR 时会因 EXC_GUARD 异常直接失败、进程被 SIGKILL。Code.NET 将 macOS 上的异常处理改为基于信号的 SEH，使 CoreCLR 能在新版 macOS 正常创建与运行。',
    commit: 'HRESULT: 0x8007000C'
  },
  {
    index: 'SHIPPED FIXED',
    title: '出厂即修复',
    body: '上述修复被打包进 Code.NET SDK 运行时（packs 中的 Microsoft.NETCore.App.Runtime.osx-arm64）。用 Code.NET 构建出的自包含应用天然携带修复运行时，无需在发布后再对 .app 做 dylib 注入或重签名。',
    commit: 'packs/Microsoft.NETCore.App.Runtime.osx-arm64'
  }
]
</script>

<template>
  <section id="why" class="section">
    <div class="shell">
      <div class="section-head">
        <div>
          <div class="label">Why code.net</div>
          <h2 class="section-title">修复了什么</h2>
        </div>
      </div>
      <p class="lede" style="margin-bottom: 34px">
        Code.NET 的定位是一个跨平台的运行时：在 macOS、Linux、Windows 上都要能用、且任何情况下都能跑起来。
        因此平台相关的崩溃修复做进运行时本身，而不是留在应用层挨个绕开。
      </p>

      <div class="grid-fix">
        <article v-for="wall in walls" :key="wall.index" class="fix-card">
          <div class="fix-index">{{ wall.index }}</div>
          <h3>{{ wall.title }}</h3>
          <p>{{ wall.body }}</p>
          <p style="margin-top: 12px"><code>{{ wall.commit }}</code></p>
        </article>
      </div>
    </div>
  </section>
</template>