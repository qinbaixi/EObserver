<script setup lang="ts">
import { computed, ref, toRef } from 'vue'
import { useI18n } from 'vue-i18n'
import { NButton, NAlert, NIcon, NCard, NRadioGroup, NRadioButton, NProgress } from 'naive-ui'
import { PlayOutline } from '@vicons/ionicons5'
import type { SchedUsageReport, SchedulerType } from '../../api/types'
import { useRecon } from '../../stores/recon'
import { useChartTheme } from '../../composables/useChartTheme'
import BarChart from '../../charts/BarChart.vue'
import { useTool } from './useTool'
import { pct } from './shared'

const props = defineProps<{ node: string }>()
const { t } = useI18n()
const recon = useRecon()
const chart = useChartTheme()
const { running, error, elapsed, last, atText, run } = useTool<SchedUsageReport>(toRef(recon, 'sched'), () => props.node)

const seconds = ref(5)
const asked = ref(5)

function start() {
  asked.value = seconds.value
  void run('recon.scheduler_usage', { seconds: seconds.value }, seconds.value * 1000 + 30000)
}

const TYPES: SchedulerType[] = ['normal', 'dirty_cpu', 'dirty_io']
// Same short names as the scheduler heatmap on the Load page.
const LABEL: Record<SchedulerType, string> = { normal: 'S', dirty_cpu: 'DC', dirty_io: 'DIO' }

const report = computed(() => last.value?.report ?? null)
const scheds = computed(() => report.value?.schedulers ?? [])
const average = computed(() => {
  const normal = scheds.value.filter((s) => s.type === 'normal')
  return normal.length ? normal.reduce((a, s) => a + s.usage, 0) / normal.length : null
})

// One series per type, so each type gets its color and a legend entry;
// they share a stack, so every scheduler is one bar.
const series = computed(() => TYPES
  .filter((ty) => scheds.value.some((s) => s.type === ty))
  .map((ty) => ({
    name: t(`recon.sched.types.${ty}`),
    stack: 'usage',
    color: chart.value.series[TYPES.indexOf(ty)],
    data: scheds.value.map((s) => (s.type === ty ? s.usage : null)),
  })))
</script>

<template>
  <div class="bar">
    <NRadioGroup v-model:value="seconds" size="small" :disabled="running">
      <NRadioButton v-for="s in [1, 5, 10, 30]" :key="s" :value="s">{{ t('recon.seconds', { n: s }) }}</NRadioButton>
    </NRadioGroup>
    <NButton type="primary" :loading="running" @click="start">
      <template #icon><NIcon :component="PlayOutline" /></template>
      {{ running ? t('recon.running') : last ? t('recon.rerun') : t('recon.run') }}
    </NButton>
    <span v-if="running" class="muted">{{ t('recon.left', { n: Math.max(0, Math.ceil(asked - elapsed)) }) }}</span>
    <span v-else-if="last" class="muted">
      {{ t('recon.sched.summary', { time: atText, seconds: last.report.seconds.toFixed(1), avg: pct(average, 1) }) }}
    </span>
    <span v-else class="muted">{{ t('recon.sched.intro') }}</span>
  </div>
  <NProgress v-if="running" type="line" :percentage="Math.min(100, Math.round((elapsed * 100) / asked))"
             :show-indicator="false" :height="3" style="margin-bottom: 12px" />
  <NAlert v-if="error" type="error" style="margin-bottom: 12px">{{ error }}</NAlert>
  <template v-if="report">
    <NCard size="small" :title="t('recon.sched.chart', { seconds: report.seconds.toFixed(1) })">
      <BarChart :categories="scheds.map((s) => `${LABEL[s.type]}${s.id}`)" :series="series"
                :format="(v) => pct(v)" :y-max="1" :y-interval="0.25" :height="300"
                :average="average" :average-label="t('recon.sched.average')"
                :tooltip-title="(i) => `${t(`recon.sched.types.${scheds[i].type}`)} #${scheds[i].id}`" />
    </NCard>
    <p class="note">{{ t('recon.sched.note') }}</p>
  </template>
</template>

<style scoped>
.bar {
  display: flex;
  align-items: center;
  gap: 12px 16px;
  flex-wrap: wrap;
  margin-bottom: 16px;
}
.muted {
  opacity: 0.6;
  font-size: 13px;
}
.note {
  font-size: 12px;
  opacity: 0.5;
  margin-top: 12px;
  line-height: 1.6;
}
</style>
