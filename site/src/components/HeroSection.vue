<script setup>
import { RELEASE_TAG, REPO, RELEASES } from '../data/downloads.js'

const facts = [
  { k: '上游', v: 'dotnet/runtime' },
  { k: '发布标签', v: RELEASE_TAG },
  { k: '目标平台', v: 'macOS · Linux · Windows' },
  { k: '许可证', v: 'MIT' }
]
</script>

<template>
  <section id="top" class="shell hero">
    <div>
      <div class="label">Open-code-studio · dotnet runtime fork</div>
      <h1 class="hero-title">CODE<span class="tld">.NET</span></h1>
      <p class="hero-claim">跨平台 .NET 运行时，任何情况下都能工作</p>
      <p class="lede">
        Code.NET 是 dotnet/runtime 的定制分支，目标是让 .NET 在 macOS、Linux、Windows 上都可靠可用：
        把平台相关的运行时崩溃修复做进运行时本身，而不是留给每个应用在发布流程里逐个打补丁。
        用 Code.NET 打包出的应用出厂即带修复，无需手工注入 dylib 或重签名。
      </p>
      <div class="hero-actions">
        <a class="btn btn-solid" href="#download">下载 <span aria-hidden="true">↓</span></a>
        <a class="btn" :href="REPO" target="_blank" rel="noreferrer">
          查看仓库 <span aria-hidden="true">↗</span>
        </a>
      </div>
    </div>

    <aside class="hero-panel">
      <div class="hero-panel-head">
        <span class="label">Build info</span>
        <a class="label" :href="RELEASES" target="_blank" rel="noreferrer">releases ↗</a>
      </div>
      <div class="hero-rows">
        <div v-for="fact in facts" :key="fact.k" class="hero-row">
          <span>{{ fact.k }}</span>
          <span>{{ fact.v }}</span>
        </div>
      </div>
    </aside>
  </section>
</template>