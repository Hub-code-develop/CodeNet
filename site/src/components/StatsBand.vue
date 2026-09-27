<script setup>
const stats = [
  { value: '10.0.400', label: '当前发布标签' },
  { value: '3', label: '支持平台' },
  { value: '6', label: '目标架构' },
  { value: 'MIT', label: '继承上游许可' }
]
</script>

<template>
  <section class="shell">
    <div class="stats">
      <div v-for="stat in stats" :key="stat.label" class="stat">
        <div class="stat-value">{{ stat.value }}</div>
        <div class="label">{{ stat.label }}</div>
      </div>
    </div>
  </section>
</template>