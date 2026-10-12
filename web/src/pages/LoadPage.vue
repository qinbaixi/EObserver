<script setup lang="ts">
import { computed, ref } from 'vue'
import { NGrid, NGi, NCard, NRadioGroup, NRadioButton, NSwitch, NSpace, NAlert } from 'naive-ui'
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

const load = useLoad()
const nodes = useNodes()
load.start()

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
  return { name, data: visible.value.map((p) => [p.time, f(p)]) }
}

const schedSeries = computed(() => {
  const s = [line('普通调度器', (p) => avg(p.schedulers, 'normal'))]
  if (showDirty.value) s.push(line('Dirty CPU', (p) => avg(p.schedulers, 'dirty_cpu')))
  return s
})

const memSeries = computed(() => {
  const other = (p: LoadPoint) => {
    const m = p.memory
    return Math.max(0, m.system - m.atom - m.binary - m.code - m.ets)
  }
  return [
    line('进程', (p) => p.memory.processes),
    line('二进制', (p) => p.memory.binary),
    line('代码', (p) => p.memory.code),
    line('ETS', (p) => p.memory.ets),
    line('原子', (p) => p.memory.atom),
    line('其他', other),
  ]
})

const ioSeries = computed(() => [
  line('输入', (p) => p.io_input),
  line('输出', (p) => p.io_output),
])
const runQueue = computed(() => [line('运行队列', (p) => p.run_queue)])
const reductions = computed(() => [line('Reductions/s', (p) => p.reductions)])

const heatTypes = computed(() => (showDirty.value ? ['normal', 'dirty_cpu'] : ['normal']))

const kpi = computed(() => {
  const p = latest.value
  if (!p) return null
  const u = avg(p.schedulers, 'normal')
  return {
    util: u == null ? '-' : pct(u),
    mem: formatBytes(p.memory.total),
    io: p.io_input == null ? '-' : `${rate(p.io_input)}`,
    ioOut: p.io_output == null ? '' : `输出 ${rate(p.io_output)}`,
    rq: count(p.run_queue),
    procs: count(p.process_count),
  }
})
</script>

<template>
  <PageHeader title="负载图表" :subtitle="nodes.current ?? undefined">
    <NSpace align="center" :size="16">
      <NSpace align="center" :size="6">
        <span class="ctl">Dirty 调度器</span>
        <NSwitch v-model:value="showDirty" size="small" />
      </NSpace>
      <NRadioGroup v-model:value="load.interval" size="small">
        <NRadioButton :value="1000">1 秒</NRadioButton>
        <NRadioButton :value="2000">2 秒</NRadioButton>
        <NRadioButton :value="5000">5 秒</NRadioButton>
      </NRadioGroup>
      <NRadioGroup v-model:value="windowMin" size="small">
        <NRadioButton :value="1">1 分钟</NRadioButton>
        <NRadioButton :value="5">5 分钟</NRadioButton>
        <NRadioButton :value="10">10 分钟</NRadioButton>
      </NRadioGroup>
    </NSpace>
  </PageHeader>
  <NodeGuard>
    <NAlert v-if="load.error" type="error" style="margin-bottom: 16px">{{ load.error }}</NAlert>
    <NGrid cols="2 s:3 l:5" responsive="screen" :x-gap="16" :y-gap="16" style="margin-bottom: 16px">
      <NGi><KpiTile label="调度器利用率" :value="kpi?.util ?? '-'" hint="普通调度器平均" /></NGi>
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
        <NCard :title="term('内存', '按类别统计的 erlang:memory() 随时间的变化。')" size="small">
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
</style>
