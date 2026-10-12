<script setup lang="ts">
import { computed } from 'vue'
import { NProgress } from 'naive-ui'
import { formatNumber } from '../api/format'
import Term from './Term.vue'

const props = defineProps<{ label: string; used: number; limit: number; tip?: string }>()
const pct = computed(() => (props.limit > 0 ? (props.used / props.limit) * 100 : 0))
const status = computed(() => (pct.value >= 85 ? 'error' : pct.value >= 60 ? 'warning' : 'success'))
</script>

<template>
  <div class="usage">
    <div class="usage-head">
      <span class="label"><Term :label="label" :tip="tip" /></span>
      <span class="mono nums">{{ formatNumber(used) }} / {{ formatNumber(limit) }}</span>
    </div>
    <NProgress type="line" :percentage="Number(pct.toFixed(2))" :status="status"
               :show-indicator="false" :height="8" />
  </div>
</template>

<style scoped>
.usage + .usage {
  margin-top: 16px;
}
.usage-head {
  display: flex;
  justify-content: space-between;
  margin-bottom: 6px;
}
.label {
  opacity: 0.65;
}
.nums {
  font-variant-numeric: tabular-nums;
}
</style>
