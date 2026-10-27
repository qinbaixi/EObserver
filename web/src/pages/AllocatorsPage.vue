<script setup lang="ts">
import { computed, h } from 'vue'
import { storeToRefs } from 'pinia'
import { useI18n } from 'vue-i18n'
import { NGrid, NGi, NCard, NDataTable, NAlert, NProgress, NText, type DataTableColumns } from 'naive-ui'
import { useAllocators, NAMED, WINDOW_MS } from '../stores/allocators'
import type { AllocatorRow } from '../api/types'
import { formatBytes } from '../api/format'
import PageHeader from '../components/PageHeader.vue'
import RefreshControl from '../components/RefreshControl.vue'
import NodeGuard from '../components/NodeGuard.vue'
import KpiTile from '../components/KpiTile.vue'
import TimeSeriesChart, { type Series } from '../charts/TimeSeriesChart.vue'
import { term } from '../api/term'
import KnowledgeLink from '../components/KnowledgeLink.vue'
import { cardForAllocator } from '../beambook'
import { useResizableTable } from '../api/table'

const { t } = useI18n()
const alloc = useAllocators()
const { data, history, error, paused, interval } = storeToRefs(alloc)

const label = (a: string) => a.replace(/_alloc$/, '')
const carrierSeries = computed<Series[]>(() => [
  ...NAMED.map((a) => ({ name: label(a), data: history.value.map((p): [number, number | null] => [p.time, p.carriers[a] ?? null]) })),
  { name: t('pages.allocators.other'), data: history.value.map((p): [number, number | null] => [p.time, p.carriers.other]) },
])
const utilSeries = computed<Series[]>(() =>
  NAMED.map((a) => ({ name: label(a), data: history.value.map((p): [number, number | null] => [p.time, p.util[a] ?? null]) })))

const totals = computed(() => {
  const list = data.value?.allocators ?? []
  const blocks = list.reduce((s, a) => s + a.blocks, 0)
  const carriers = list.reduce((s, a) => s + a.carriers, 0)
  return { blocks, carriers, util: carriers > 0 ? blocks / carriers : 0 }
})

const pct = (v: number) => `${(v * 100).toFixed(0)}%`
const mono = (s: string) => h('span', { class: 'mono' }, s)

const columns: DataTableColumns<AllocatorRow> = [
  { key: 'type', title: term('分配器'), width: 150, sorter: (a, b) => a.type.localeCompare(b.type),
    render: (r) => h('b', { class: 'mono' }, h(KnowledgeLink, { text: r.type, card: cardForAllocator(r.type) })) },
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
const allocTable = useResizableTable(columns)
</script>

<template>
  <PageHeader :title="t('pages.allocators.title')" :subtitle="t('pages.allocators.subtitle')">
    <RefreshControl v-model:paused="paused" v-model:interval="interval" @refresh="alloc.refresh" />
  </PageHeader>
  <NodeGuard>
    <NAlert v-if="error" type="error" style="margin-bottom: 12px">{{ error }}</NAlert>
    <NGrid :cols="4" :x-gap="12" :y-gap="12" responsive="screen" item-responsive>
      <NGi span="4 m:1"><KpiTile label="已分配载体" :value="data ? formatBytes(totals.carriers) : '-'" :hint="t('pages.allocators.hints.carriers')" /></NGi>
      <NGi span="4 m:1"><KpiTile label="已用块" :value="data ? formatBytes(totals.blocks) : '-'" :hint="t('pages.allocators.hints.blocks')" /></NGi>
      <NGi span="4 m:1"><KpiTile label="整体利用率" :value="data ? pct(totals.util) : '-'" :hint="t('pages.allocators.hints.util')" /></NGi>
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
        <NCard size="small" :title="t('pages.allocators.table')">
          <template #header-extra><NText depth="3" style="font-size: 12px">{{ t('pages.allocators.table_note') }}</NText></template>
          <NDataTable v-bind="allocTable" :data="data?.allocators ?? []" :loading="!data && !error" size="small"
                      :row-key="(r: AllocatorRow) => r.type" />
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
