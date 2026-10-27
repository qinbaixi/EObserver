<script setup lang="ts">
import { computed } from 'vue'
import { useI18n } from 'vue-i18n'
import { NCard, NProgress, NButton } from 'naive-ui'
import type { DumpInfo } from '../../api/dump'
import { formatBytes, formatDuration } from '../../api/format'

// Scan progress of a dump that is still being indexed.
const props = defineProps<{ info: DumpInfo }>()
defineEmits<{ cancel: [] }>()
const { t } = useI18n()

const pct = computed(() => (props.info.size > 0 ? Math.min(100, (props.info.scanned / props.info.size) * 100) : 0))
const eta = computed(() => {
  const e = props.info.eta
  if (e === null || e === undefined || !Number.isFinite(e)) return t('crashdump.progress.eta_unknown')
  return e < 1 ? t('crashdump.progress.eta_soon') : formatDuration(e * 1000)
})
</script>

<template>
  <NCard size="small" class="progress">
    <div class="row">
      <span class="dump-spin spin" />
      <span class="title">{{ t('crashdump.progress.title') }}</span>
      <span class="pct mono">{{ pct.toFixed(1) }}%</span>
      <span class="spacer" />
      <NButton size="small" secondary @click="$emit('cancel')">{{ t('crashdump.progress.cancel') }}</NButton>
    </div>
    <NProgress type="line" :percentage="Number(pct.toFixed(1))" :show-indicator="false" :height="8" processing />
    <div class="facts">
      <span>{{ t('crashdump.progress.read', { done: formatBytes(info.scanned), size: formatBytes(info.size) }) }}</span>
      <span v-if="info.rate">{{ t('crashdump.progress.rate', { rate: formatBytes(info.rate) }) }}</span>
      <span>{{ t('crashdump.progress.eta', { eta }) }}</span>
      <span class="note">{{ t('crashdump.progress.note') }}</span>
    </div>
  </NCard>
</template>

<style scoped>
.progress {
  margin-bottom: 16px;
}
.row {
  display: flex;
  align-items: center;
  gap: 10px;
  margin-bottom: 10px;
}
.title {
  font-weight: 600;
}
.spin {
  width: 14px;
  height: 14px;
  color: #2080f0;
}
.pct {
  font-variant-numeric: tabular-nums;
  opacity: 0.75;
}
.spacer {
  flex: 1;
}
.facts {
  display: flex;
  flex-wrap: wrap;
  gap: 4px 20px;
  margin-top: 8px;
  font-size: 13px;
  opacity: 0.7;
  font-variant-numeric: tabular-nums;
}
.note {
  opacity: 0.75;
}
</style>
