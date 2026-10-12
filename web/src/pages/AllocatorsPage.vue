<script setup lang="ts">
import { computed, h, ref, toRef, watch } from 'vue'
import { NGrid, NGi, NCard, NDataTable, NAlert, NProgress, NText, type DataTableColumns } from 'naive-ui'
import { useNodes } from '../stores/nodes'
import { useTopic } from '../composables/useTopic'
import type { AllocInfo, AllocatorRow } from '../api/types'
import { formatBytes } from '../api/format'
import PageHeader from '../components/PageHeader.vue'
import NodeGuard from '../components/NodeGuard.vue'
import KpiTile from '../components/KpiTile.vue'
import TimeSeriesChart, { type Series } from '../charts/TimeSeriesChart.vue'
import { term } from '../api/term'

const nodes = useNodes()
const node = computed(() =>
  nodes.currentInfo?.status === 'connected' ? nodes.currentInfo.node : null)
const { data, error } = useTopic<AllocInfo>('node.allocators', toRef(node), 2000)

// Allocators drawn as their own series, in a fixed order so each keeps
// its color; the rest are folded into "其他".
const NAMED = ['eheap_alloc', 'binary_alloc', 'ets_alloc', 'll_alloc', 'literal_alloc', 'fix_alloc', 'std_alloc']
const WINDOW_MS = 5 * 60 * 1000

interface Point { time: number; carriers: Record<string, number>; util: Record<string, number | null> }
const history = ref<Point[]>([])
watch(node, () => { history.value = [] })
watch(data, (d) => {
  if (!d) return
  const time = Date.now()
  const carriers: Record<string, number> = { other: 0 }
  const util: Record<string, number | null> = {}
  for (const a of d.allocators) {
    if (NAMED.includes(a.type)) {
      carriers[a.type] = a.carriers
      util[a.type] = a.carriers > 0 ? a.blocks / a.carriers : null
    } else {
      carriers.other += a.carriers
    }
  }
  history.value = [...history.value.filter((p) => p.time >= time - WINDOW_MS), { time, carriers, util }]
})

const label = (t: string) => t.replace(/_alloc$/, '')
const carrierSeries = computed<Series[]>(() => [
  ...NAMED.map((t) => ({ name: label(t), data: history.value.map((p): [number, number | null] => [p.time, p.carriers[t] ?? null]) })),
  { name: '其他', data: history.value.map((p): [number, number | null] => [p.time, p.carriers.other]) },
])
const utilSeries = computed<Series[]>(() =>
  NAMED.map((t) => ({ name: label(t), data: history.value.map((p): [number, number | null] => [p.time, p.util[t] ?? null]) })))

const totals = computed(() => {
  const list = data.value?.allocators ?? []
  const blocks = list.reduce((s, a) => s + a.blocks, 0)
  const carriers = list.reduce((s, a) => s + a.carriers, 0)
  return { blocks, carriers, util: carriers > 0 ? blocks / carriers : 0 }
})

const pct = (v: number) => `${(v * 100).toFixed(0)}%`
const mono = (t: string) => h('span', { class: 'mono' }, t)

const columns: DataTableColumns<AllocatorRow> = [
  { key: 'type', title: term('分配器'), width: 150, sorter: (a, b) => a.type.localeCompare(b.type),
    render: (r) => h('b', { class: 'mono' }, r.type) },
  { key: 'instances', title: term('实例'), width: 70, align: 'right', render: (r) => mono(String(r.instances)) },
  { key: 'blocks', title: term('已用块'), width: 120, align: 'right', sorter: (a, b) => a.blocks - b.blocks,
    render: (r) => mono(formatBytes(r.blocks)) },
  { key: 'carriers', title: term('已分配载体'), width: 130, align: 'right', defaultSortOrder: 'descend',
    sorter: (a, b) => a.carriers - b.carriers, render: (r) => mono(formatBytes(r.carriers)) },
  { key: 'util', title: term('利用率'), minWidth: 180,
    sorter: (a, b) => ratio(a) - ratio(b),
    render: (r) => h('div', { class: 'util' }, [
      h(NProgress, { type: 'line', percentage: Math.round(ratio(r) * 100), showIndicator: false, height: 8,
        status: r.carriers > 4 * 1024 * 1024 && ratio(r) < 0.5 ? 'warning' : 'default' }),
      h('span', { class: 'mono util-pct' }, r.carriers ? pct(ratio(r)) : '-'),
    ]) },
  { key: 'mbcs', title: term('多块载体'), width: 170, align: 'right',
    render: (r) => h('span', { class: 'mono muted' }, `${formatBytes(r.mbcs_blocks)} / ${formatBytes(r.mbcs_carriers)}`) },
  { key: 'sbcs', title: term('单块载体'), width: 170, align: 'right',
    render: (r) => h('span', { class: 'mono muted' }, `${formatBytes(r.sbcs_blocks)} / ${formatBytes(r.sbcs_carriers)}`) },
  { key: 'carriers_max', title: term('历史峰值'), width: 110, align: 'right',
    sorter: (a, b) => a.carriers_max - b.carriers_max, render: (r) => h('span', { class: 'mono muted' }, formatBytes(r.carriers_max)) },
]

function ratio(r: AllocatorRow) {
  return r.carriers > 0 ? r.blocks / r.carriers : 0
}
</script>

<template>
  <PageHeader title="内存分配器" subtitle="erts_alloc 的载体（向操作系统申请）与块（实际使用）" />
  <NodeGuard>
    <NAlert v-if="error" type="error" style="margin-bottom: 12px">{{ error }}</NAlert>
    <NGrid :cols="4" :x-gap="12" :y-gap="12" responsive="screen" item-responsive>
      <NGi span="4 m:1"><KpiTile label="已分配载体" :value="data ? formatBytes(totals.carriers) : '-'" hint="VM 从操作系统申请的内存" /></NGi>
      <NGi span="4 m:1"><KpiTile label="已用块" :value="data ? formatBytes(totals.blocks) : '-'" hint="载体中实际存放数据的部分" /></NGi>
      <NGi span="4 m:1"><KpiTile label="整体利用率" :value="data ? pct(totals.util) : '-'" hint="利用率低说明存在碎片" /></NGi>
      <NGi span="4 m:1"><KpiTile label="erlang:memory(total)" :value="data ? formatBytes(data.memory_total) : '-'" /></NGi>
      <NGi span="4 l:2">
        <NCard :title="term('载体大小')" size="small">
          <TimeSeriesChart :series="carrierSeries" :format="formatBytes" stacked :window-ms="WINDOW_MS" :height="260" />
        </NCard>
      </NGi>
      <NGi span="4 l:2">
        <NCard :title="term('载体利用率')" size="small">
          <TimeSeriesChart :series="utilSeries" :format="pct" :y-max="1" :y-interval="0.25" :window-ms="WINDOW_MS" :height="260" />
        </NCard>
      </NGi>
      <NGi span="4">
        <NCard size="small" title="各分配器">
          <template #header-extra><NText depth="3" style="font-size: 12px">所有实例之和</NText></template>
          <NDataTable :columns="columns" :data="data?.allocators ?? []" :loading="!data && !error" size="small"
                      :row-key="(r: AllocatorRow) => r.type" :scroll-x="1100" />
        </NCard>
      </NGi>
    </NGrid>
  </NodeGuard>
</template>

<style scoped>
:deep(.muted) { opacity: 0.65; }
:deep(.util) { display: flex; align-items: center; gap: 10px; }
:deep(.util-pct) { width: 40px; text-align: right; font-size: 12px; }
</style>
