<script setup lang="ts">
import { NCard } from 'naive-ui'
defineProps<{ title: string; rows: { label: string; value: string | number }[] }>()
</script>

<template>
  <NCard :title="title" size="small" class="stat-card">
    <dl>
      <template v-for="r in rows" :key="r.label">
        <dt>{{ r.label }}</dt>
        <dd class="mono">{{ r.value }}</dd>
      </template>
    </dl>
  </NCard>
</template>

<style scoped>
dl {
  display: grid;
  grid-template-columns: auto 1fr;
  gap: 10px 16px;
  margin: 0;
}
dt {
  opacity: 0.65;
}
dd {
  margin: 0;
  text-align: right;
  font-variant-numeric: tabular-nums;
}
</style>
