<script setup lang="ts">
import { computed, h, toRef } from 'vue'
import { useI18n } from 'vue-i18n'
import { NButton, NAlert, NIcon, NDataTable, NCard, NGrid, NGi, NText, type DataTableColumns } from 'naive-ui'
import { PlayOutline } from '@vicons/ionicons5'
import { formatBytes, formatNumber } from '../../api/format'
import { term } from '../../api/term'
import KnowledgeLink from '../KnowledgeLink.vue'
import { cardForAllocator } from '../../beambook'
import { termLabel } from '../../api/glossary'
import type { ReconAllocReport, ReconAllocRow } from '../../api/types'
import { useRecon } from '../../stores/recon'
import { useChartTheme } from '../../composables/useChartTheme'
import BarChart from '../../charts/BarChart.vue'
import UsageHeatmap from '../../charts/UsageHeatmap.vue'
import { useTool } from './useTool'
import { pct } from './shared'

const props = defineProps<{ node: string }>()
const { t } = useI18n()
const recon = useRecon()
const chart = useChartTheme()
const { running, error, last, atText, run } = useTool<ReconAllocReport>(toRef(recon, 'alloc'), () => props.node)

const start = () => run('recon.alloc', {}, 30000)

const report = computed(() => last.value?.report ?? null)
const rows = computed(() => report.value?.allocators ?? [])
const short = (type: string) => type.replace(/_alloc$/, '')

// Allocator types by total carrier size, largest first: the heatmap rows
// and the block size groups.
const types = computed(() => {
  const size = new Map<string, number>()
  for (const r of rows.value) size.set(r.type, (size.get(r.type) ?? 0) + r.mbcs_carriers + r.sbcs_carriers)
  return [...size.keys()].sort((a, b) => size.get(b)! - size.get(a)!)
})

const heat = computed(() => {
  const instances = [...new Set(rows.value.map((r) => r.instance))].sort((a, b) => a - b)
  const col = new Map(instances.map((x, i) => [x, i]))
  const row = new Map(types.value.map((x, i) => [x, i]))
  const byCell = new Map<string, ReconAllocRow>()
  const cells: [number, number, number][] = []
  for (const r of rows.value) {
    if (r.mbcs_usage == null) continue
    const x = col.get(r.instance)!
    const y = row.get(r.type)!
    byCell.set(`${x}:${y}`, r)
    cells.push([x, y, r.mbcs_usage])
  }
  const tooltip = (x: number, y: number) => {
    const r = byCell.get(`${x}:${y}`)
    if (!r) return ''
    return `${t('recon.alloc.heatmap_cell', { type: r.type, instance: r.instance })}<br/>`
      + `<b>${pct(r.mbcs_usage, 1)}</b> · ${t('recon.alloc.heatmap_detail', {
        blocks: formatBytes(r.mbcs_blocks), carriers: formatBytes(r.mbcs_carriers) })}`
  }
  return { rows: types.value.map(short), cols: instances.map(String), cells, tooltip }
})

const cache = computed(() => report.value?.cache_hit_rates ?? [])

// Average block size per allocator type over all its instances.
const blocks = computed(() => {
  const avg = (bytes: number, count: number) => (count > 0 ? bytes / count : null)
  const sum = (type: string, f: (r: ReconAllocRow) => number) =>
    rows.value.filter((r) => r.type === type).reduce((s, r) => s + f(r), 0)
  return {
    categories: types.value.map(short),
    series: [
      { name: termLabel('多块载体'), color: chart.value.series[0],
        data: types.value.map((x) => avg(sum(x, (r) => r.mbcs_blocks), sum(x, (r) => r.mbcs_block_count))) },
      { name: termLabel('单块载体'), color: chart.value.series[2],
        data: types.value.map((x) => avg(sum(x, (r) => r.sbcs_blocks), sum(x, (r) => r.sbcs_block_count))) },
    ],
  }
})

const mono = (s: string, cls = 'mono muted') => h('span', { class: `${cls} nowrap` }, s)
const num = (v: number | null) => (v == null ? -1 : v)
const sizeCount = (bytes: number, n: number) => mono(t('recon.alloc.blocks_count', { bytes: formatBytes(bytes), n: formatNumber(n) }))
const carrierCount = (bytes: number, n: number) => mono(t('recon.alloc.carriers_count', { bytes: formatBytes(bytes), n: formatNumber(n) }))

// Multiblock and singleblock carriers as two column groups with the same
// sub-columns.
type Kind = 'mbcs' | 'sbcs'
function group(k: Kind, label: string) {
  return {
    key: k, title: term(label), align: 'center' as const,
    children: [
      { key: `${k}_usage`, title: t('recon.alloc.usage'), width: 90, align: 'right' as const,
        defaultSortOrder: k === 'mbcs' ? 'ascend' as const : undefined,
        sorter: (a: ReconAllocRow, b: ReconAllocRow) => num(a[`${k}_usage`]) - num(b[`${k}_usage`]),
        render: (r: ReconAllocRow) => mono(pct(r[`${k}_usage`], 1), k === 'mbcs' ? 'mono grow' : 'mono') },
      { key: `${k}_blocks`, title: term('已用块'), width: 190, align: 'right' as const,
        sorter: (a: ReconAllocRow, b: ReconAllocRow) => a[`${k}_blocks`] - b[`${k}_blocks`],
        render: (r: ReconAllocRow) => sizeCount(r[`${k}_blocks`], r[`${k}_block_count`]) },
      { key: `${k}_carriers`, title: term('已分配载体'), width: 150, align: 'right' as const,
        sorter: (a: ReconAllocRow, b: ReconAllocRow) => a[`${k}_carriers`] - b[`${k}_carriers`],
        render: (r: ReconAllocRow) => carrierCount(r[`${k}_carriers`], r[`${k}_carrier_count`]) },
      { key: `${k}_avg_block`, title: t('recon.alloc.avg_block'), width: 100, align: 'right' as const,
        sorter: (a: ReconAllocRow, b: ReconAllocRow) => num(a[`${k}_avg_block`]) - num(b[`${k}_avg_block`]),
        render: (r: ReconAllocRow) => {
          const v = r[`${k}_avg_block`]
          return mono(v == null ? '-' : formatBytes(v))
        } },
    ],
  }
}

const columns = computed<DataTableColumns<ReconAllocRow>>(() => [
  { key: 'type', title: term('分配器'), width: 140, fixed: 'left',
    sorter: (a, b) => a.type.localeCompare(b.type) || a.instance - b.instance,
    render: (r) => h('b', { class: 'mono' }, h(KnowledgeLink, { text: r.type, card: cardForAllocator(r.type) })) },
  { key: 'instance', title: term('实例'), width: 70, align: 'right', sorter: (a, b) => a.instance - b.instance,
    render: (r) => mono(String(r.instance), 'mono') },
  group('mbcs', '多块载体'),
  group('sbcs', '单块载体'),
  { key: 'sbcs_to_mbcs', title: term(t('recon.alloc.sbcs_to_mbcs'), t('recon.alloc.sbcs_to_mbcs_tip')), width: 110, align: 'right',
    sorter: (a, b) => num(a.sbcs_to_mbcs) - num(b.sbcs_to_mbcs),
    render: (r) => mono(r.sbcs_to_mbcs == null ? '-' : r.sbcs_to_mbcs.toFixed(2)) },
])
</script>

<template>
  <div class="bar">
    <NButton type="primary" :loading="running" @click="start">
      <template #icon><NIcon :component="PlayOutline" /></template>
      {{ running ? t('recon.running') : last ? t('recon.rerun') : t('recon.run') }}
    </NButton>
    <span v-if="last && !running" class="muted">
      {{ t('recon.alloc.summary', { time: atText, n: formatNumber(last.report.allocators.length), total: formatBytes(last.report.memory_total) }) }}
    </span>
    <span v-else-if="!last" class="muted">{{ t('recon.alloc.intro') }}</span>
  </div>
  <NAlert v-if="error" type="error" style="margin-bottom: 12px">{{ error }}</NAlert>
  <NGrid v-if="report" cols="1 l:2" responsive="screen" :x-gap="12" :y-gap="12">
    <NGi span="1 l:2">
      <NCard size="small" :title="term(t('recon.alloc.heatmap'), t('recon.alloc.heatmap_tip'))">
        <UsageHeatmap v-if="heat.cells.length" :rows="heat.rows" :cols="heat.cols" :cells="heat.cells" :tooltip="heat.tooltip" />
        <div v-else class="empty">{{ t('recon.alloc.empty') }}</div>
      </NCard>
    </NGi>
    <NGi>
      <NCard size="small" :title="term(t('recon.alloc.cache'), t('recon.alloc.cache_tip'))" class="full">
        <BarChart v-if="cache.length" :categories="cache.map((c) => t('recon.alloc.instance', { n: c.instance }))"
                  :series="[{ name: t('recon.alloc.cache'), data: cache.map((c) => c.ratio) }]"
                  :format="(v) => pct(v)" :y-max="1" :y-interval="0.25"
                  :tooltip-title="(i) => `${t('recon.alloc.instance', { n: cache[i].instance })} · ${t('recon.alloc.cache_detail', { hits: formatNumber(cache[i].hits), calls: formatNumber(cache[i].calls) })}`" />
        <div v-else class="empty">{{ t('recon.alloc.no_cache') }}</div>
      </NCard>
    </NGi>
    <NGi>
      <NCard size="small" :title="term(t('recon.alloc.blocks'), t('recon.alloc.blocks_tip'))" class="full">
        <BarChart :categories="blocks.categories" :series="blocks.series" :format="formatBytes" log />
      </NCard>
    </NGi>
    <NGi span="1 l:2">
      <NCard size="small" :title="t('recon.alloc.table')">
        <template #header-extra><NText depth="3" style="font-size: 12px">{{ t('recon.alloc.table_note') }}</NText></template>
        <NDataTable :columns="columns" :data="rows" size="small" :bordered="false" :single-line="false"
                    :scroll-x="1400" max-height="calc(100vh - 330px)"
                    :row-key="(r: ReconAllocRow) => `${r.type}:${r.instance}`" />
      </NCard>
    </NGi>
  </NGrid>
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
.full {
  height: 100%;
}
.empty {
  padding: 48px 0;
  text-align: center;
  opacity: 0.6;
}
:deep(.muted) {
  opacity: 0.65;
}
:deep(.nowrap) {
  white-space: nowrap;
}
:deep(.grow) {
  font-weight: 600;
}
</style>
