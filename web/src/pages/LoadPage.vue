<script setup lang="ts">
import { computed, ref } from 'vue'
import { useI18n } from 'vue-i18n'
import { NGrid, NGi, NCard, NRadioGroup, NRadioButton, NSwitch, NSpace, NAlert, NSelect } from 'naive-ui'
import { useLoad } from '../stores/load'
import { useNodes } from '../stores/nodes'
import type { LoadPoint, SchedulerUtil } from '../api/types'
import { formatBytes, formatNumber } from '../api/format'
import PageHeader from '../components/PageHeader.vue'
import NodeGuard from '../components/NodeGuard.vue'
import KpiTile from '../components/KpiTile.vue'
import TimeSeriesChart, { type Series } from '../charts/TimeSeriesChart.vue'
import SchedulerHeatmap from '../charts/SchedulerHeatmap.vue'
import { term } from '../api/term'
import { lineData } from '../charts/gaps'
import { useQueryRef } from '../composables/useQueryRef'

const { t } = useI18n()
const load = useLoad()
const nodes = useNodes()
load.start()

// Compare mode overlays one metric of several nodes; those nodes are
// sampled only while it is shown.
const MAX_COMPARE = 8
const modeRef = useQueryRef('mode')
const compare = computed({
  get: () => modeRef.value === 'compare',
  set: (v: boolean) => { modeRef.value = v ? 'compare' : null },
})

const windowMin = ref(5)
const showDirty = ref(false)
const windowMs = computed(() => windowMin.value * 60 * 1000)

const visible = computed(() => {
  const pts = load.points
  const last = pts.at(-1)?.time ?? 0
  return pts.filter((p) => p.time >= last - windowMs.value)
})
const latest = computed(() => load.points.at(-1) ?? null)

function avg(list: SchedulerUtil[] | null, type: string): number | null {
  const xs = list?.filter((s) => s.type === type) ?? []
  return xs.length ? xs.reduce((a, s) => a + s.util, 0) / xs.length : null
}

const pct = (v: number) => `${(v * 100).toFixed(v > 0 && v < 0.1 ? 1 : 0)}%`
const rate = (v: number) => `${formatBytes(v)}/s`
const count = (v: number) => formatNumber(Math.round(v))
const compact = (v: number) =>
  v >= 1e9 ? `${(v / 1e9).toFixed(1)}G` : v >= 1e6 ? `${(v / 1e6).toFixed(1)}M`
    : v >= 1e3 ? `${(v / 1e3).toFixed(1)}K` : `${Math.round(v)}`

function line(name: string, f: (p: LoadPoint) => number | null): Series {
  return { name, data: lineData(visible.value, f) }
}

const schedSeries = computed(() => {
  const s = [line(t('pages.load.series.normal'), (p) => avg(p.schedulers, 'normal'))]
  if (showDirty.value) s.push(line('Dirty CPU', (p) => avg(p.schedulers, 'dirty_cpu')))
  return s
})

const memSeries = computed(() => {
  const other = (p: LoadPoint) => {
    const m = p.memory
    return Math.max(0, m.system - m.atom - m.binary - m.code - m.ets)
  }
  return [
    line(t('pages.load.series.processes'), (p) => p.memory.processes),
    line(t('pages.load.series.binary'), (p) => p.memory.binary),
    line(t('pages.load.series.code'), (p) => p.memory.code),
    line('ETS', (p) => p.memory.ets),
    line(t('pages.load.series.atom'), (p) => p.memory.atom),
    line(t('pages.load.series.other'), other),
  ]
})

const ioSeries = computed(() => [
  line(t('pages.load.series.input'), (p) => p.io_input),
  line(t('pages.load.series.output'), (p) => p.io_output),
])
const runQueue = computed(() => [line(t('pages.load.series.run_queue'), (p) => p.run_queue)])
const reductions = computed(() => [line('Reductions/s', (p) => p.reductions)])

type Metric = 'memory' | 'process_count' | 'run_queue' | 'reductions' | 'io_input' | 'io_output' | 'scheduler'
const METRICS: Record<Metric, { f: (p: LoadPoint) => number | null; format: (v: number) => string;
                                 integer?: boolean; yMax?: number }> = {
  memory: { f: (p) => p.memory.total, format: formatBytes },
  process_count: { f: (p) => p.process_count, format: count, integer: true },
  run_queue: { f: (p) => p.run_queue, format: count, integer: true },
  reductions: { f: (p) => p.reductions, format: compact },
  io_input: { f: (p) => p.io_input, format: rate },
  io_output: { f: (p) => p.io_output, format: rate },
  scheduler: { f: (p) => avg(p.schedulers, 'normal'), format: pct, yMax: 1 },
}
const metric = ref<Metric>('memory')
const metricOptions = computed(() => (Object.keys(METRICS) as Metric[])
  .map((m) => ({ value: m, label: t(`load.compare.metrics.${m}`) })))

const connectedNodes = computed(() =>
  nodes.list.filter((n) => n.status === 'connected').map((n) => n.node))
const picked = ref<string[] | null>(null)
// Until the user picks, the current node and the next connected ones.
const compareNodes = computed<string[]>({
  get: () => picked.value ?? [
    ...(load.node ? [load.node] : []),
    ...connectedNodes.value.filter((n) => n !== load.node),
  ].slice(0, MAX_COMPARE),
  set: (v) => { picked.value = v.slice(0, MAX_COMPARE) },
})
const nodeOptions = computed(() => nodes.list.map((n) => ({
  value: n.node, label: n.node,
  disabled: compareNodes.value.length >= MAX_COMPARE && !compareNodes.value.includes(n.node),
})))

load.useSampling('compare', () => (compare.value ? compareNodes.value : []))

const compareSeries = computed<Series[]>(() => {
  const m = METRICS[metric.value]
  const all = compareNodes.value.map((n) => load.history[n]?.value ?? [])
  const last = Math.max(0, ...all.map((pts) => pts.at(-1)?.time ?? 0))
  return compareNodes.value.map((n, i) => ({
    name: n,
    data: lineData(all[i].filter((p) => p.time >= last - windowMs.value), m.f),
  }))
})

const heatTypes = computed(() => (showDirty.value ? ['normal', 'dirty_cpu'] : ['normal']))

const kpi = computed(() => {
  const p = latest.value
  if (!p) return null
  const u = avg(p.schedulers, 'normal')
  return {
    util: u == null ? '-' : pct(u),
    mem: formatBytes(p.memory.total),
    io: p.io_input == null ? '-' : `${rate(p.io_input)}`,
    ioOut: p.io_output == null ? '' : t('pages.load.io_out', { v: rate(p.io_output) }),
    rq: count(p.run_queue),
    procs: count(p.process_count),
  }
})
</script>

<template>
  <PageHeader :title="t('pages.load.title')" :subtitle="compare ? undefined : nodes.current ?? undefined">
    <NSpace align="center" :size="16">
      <NRadioGroup :value="compare ? 'compare' : 'single'" size="small"
                   @update:value="(v: string) => compare = v === 'compare'">
        <NRadioButton value="single">{{ t('load.mode.single') }}</NRadioButton>
        <NRadioButton value="compare">{{ t('load.mode.compare') }}</NRadioButton>
      </NRadioGroup>
      <NSpace v-if="!compare" align="center" :size="6">
        <span class="ctl">{{ t('pages.load.dirty') }}</span>
        <NSwitch v-model:value="showDirty" size="small" />
      </NSpace>
      <NRadioGroup v-if="!compare" v-model:value="load.interval" size="small">
        <NRadioButton v-for="n in [1, 2, 5]" :key="n" :value="n * 1000">{{ t('pages.load.seconds', { n }) }}</NRadioButton>
      </NRadioGroup>
      <NRadioGroup v-model:value="windowMin" size="small">
        <NRadioButton v-for="n in [1, 5, 10]" :key="n" :value="n">{{ t('pages.load.minutes', { n }) }}</NRadioButton>
      </NRadioGroup>
    </NSpace>
  </PageHeader>
  <template v-if="compare">
    <NCard size="small">
      <div class="compare-ctl">
        <label class="field">
          <span class="ctl">{{ t('load.compare.metric') }}</span>
          <NSelect v-model:value="metric" :options="metricOptions" size="small" style="width: 220px" />
        </label>
        <label class="field grow">
          <span class="ctl">{{ t('load.compare.nodes') }}</span>
          <NSelect v-model:value="compareNodes" :options="nodeOptions" multiple size="small"
                   :placeholder="t('load.compare.pick')" max-tag-count="responsive" />
        </label>
      </div>
      <div class="compare-hint">
        {{ t('load.compare.hint') }} {{ t('load.compare.max', { n: MAX_COMPARE }) }}
      </div>
      <TimeSeriesChart v-if="compareNodes.length" :series="compareSeries" :format="METRICS[metric].format"
                       :integer="METRICS[metric].integer" :y-max="METRICS[metric].yMax"
                       :window-ms="windowMs" :height="380" />
      <div v-else class="compare-empty">{{ t('load.compare.empty') }}</div>
    </NCard>
  </template>
  <NodeGuard v-else>
    <NAlert v-if="load.error" type="error" style="margin-bottom: 16px">{{ load.error }}</NAlert>
    <NGrid cols="2 s:3 l:5" responsive="screen" :x-gap="16" :y-gap="16" style="margin-bottom: 16px">
      <NGi><KpiTile label="调度器利用率" :value="kpi?.util ?? '-'" :hint="t('pages.load.util_hint')" /></NGi>
      <NGi><KpiTile label="总内存" :value="kpi?.mem ?? '-'" /></NGi>
      <NGi><KpiTile label="IO 输入" :value="kpi?.io ?? '-'" :hint="kpi?.ioOut" /></NGi>
      <NGi><KpiTile label="运行队列" :value="kpi?.rq ?? '-'" /></NGi>
      <NGi><KpiTile label="进程数" :value="kpi?.procs ?? '-'" /></NGi>
    </NGrid>
    <NGrid cols="1 l:2" responsive="screen" :x-gap="16" :y-gap="16">
      <NGi>
        <NCard :title="term('调度器利用率')" size="small">
          <TimeSeriesChart :series="schedSeries" :format="pct" :y-max="1" :y-interval="0.25" :window-ms="windowMs" />
        </NCard>
      </NGi>
      <NGi>
        <NCard :title="term('各调度器利用率')" size="small">
          <SchedulerHeatmap :points="visible" :types="heatTypes" />
        </NCard>
      </NGi>
      <NGi>
        <NCard :title="term('内存', t('pages.load.memory_tip'))" size="small">
          <TimeSeriesChart :series="memSeries" :format="formatBytes" stacked :window-ms="windowMs" />
        </NCard>
      </NGi>
      <NGi>
        <NCard :title="term('IO 吞吐')" size="small">
          <TimeSeriesChart :series="ioSeries" :format="rate" :window-ms="windowMs" />
        </NCard>
      </NGi>
      <NGi>
        <NCard :title="term('运行队列')" size="small">
          <TimeSeriesChart :series="runQueue" :format="count" integer :window-ms="windowMs" :height="180" />
        </NCard>
      </NGi>
      <NGi>
        <NCard :title="term('Reductions / 秒')" size="small">
          <TimeSeriesChart :series="reductions" :format="compact" :window-ms="windowMs" :height="180" />
        </NCard>
      </NGi>
    </NGrid>
  </NodeGuard>
</template>

<style scoped>
.ctl {
  font-size: 13px;
  opacity: 0.7;
}
.compare-ctl {
  display: flex;
  flex-wrap: wrap;
  gap: 12px 24px;
  margin-bottom: 8px;
}
.field {
  display: flex;
  align-items: center;
  gap: 8px;
  min-width: 0;
}
.field.grow {
  flex: 1;
  min-width: min(320px, 100%);
}
.field.grow > :last-child {
  flex: 1;
  min-width: 0;
}
.compare-hint {
  font-size: 12px;
  opacity: 0.55;
  margin-bottom: 12px;
}
.compare-empty {
  padding: 48px 0;
  text-align: center;
  opacity: 0.6;
}
</style>
