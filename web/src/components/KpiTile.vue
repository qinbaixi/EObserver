<script setup lang="ts">
import { NCard } from 'naive-ui'
defineProps<{ label: string; value: string; hint?: string }>()
</script>

<template>
  <NCard size="small" class="kpi">
    <div class="label">{{ label }}</div>
    <div class="value mono">{{ value }}</div>
    <div v-if="hint" class="hint">{{ hint }}</div>
  </NCard>
</template>

<style scoped>
.label {
  opacity: 0.65;
  font-size: 13px;
}
.value {
  font-size: 24px;
  font-weight: 600;
  margin-top: 4px;
  font-variant-numeric: tabular-nums;
}
.hint {
  font-size: 12px;
  opacity: 0.5;
  margin-top: 2px;
}
</style>
