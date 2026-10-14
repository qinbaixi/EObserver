<script setup lang="ts">
import { computed, h, ref, toRef } from 'vue'
import { useI18n } from 'vue-i18n'
import {
  NButton, NAlert, NIcon, NDataTable, NRadioGroup, NRadioButton, NCard, NTooltip, NGrid, NGi,
  NCollapse, NCollapseItem, useDialog, type DataTableColumns,
} from 'naive-ui'
import { TrashBinOutline } from '@vicons/ionicons5'
import { formatBytes, formatNumber } from '../../api/format'
import type { BinLeakItem, BinLeakReport, BinLeakSkipped } from '../../api/types'
import { useRecon } from '../../stores/recon'
import { useSettings } from '../../stores/settings'
import { useChartTheme } from '../../composables/useChartTheme'
import KpiTile from '../KpiTile.vue'
import BarChart from '../../charts/BarChart.vue'
import { useTool } from './useTool'
import { pct, procCell, procLabel } from './shared'

const props = defineProps<{ node: string }>()
const emit = defineEmits<{ open: [pid: string] }>()
const { t } = useI18n()
const dialog = useDialog()
const recon = useRecon()
const settings = useSettings()
const chart = useChartTheme()
const { running, error, elapsed, last, atText, run } = useTool<BinLeakReport>(toRef(recon, 'binLeak'), () => props.node)

const n = ref(20)

// It garbage-collects every process, so it is confirmed first (and the
// backend refuses it in read-only mode). The node stops it after 120 s.
function start() {
  dialog.warning({
    title: t('recon.bin_leak.confirm_title'),
    content: t('recon.bin_leak.confirm_content'),
    positiveText: t('recon.bin_leak.confirm_ok'),
    negativeText: t('recon.bin_leak.cancel'),
    onPositiveClick: () => { void run('recon.bin_leak', { n: n.value }, 150000) },
  })
}

const report = computed(() => last.value?.report ?? null)
const items = computed(() => report.value?.items ?? [])
const freedTotal = computed(() =>
  report.value ? Math.max(0, report.value.binary_before - report.value.binary_after) : 0)

const series = computed(() => [
  { name: t('recon.bin_leak.after'), data: items.value.map((i) => i.after_bytes), stack: 'b', color: chart.value.series[0] },
  { name: t('recon.bin_leak.freed'), data: items.value.map((i) => i.freed), stack: 'b', color: chart.value.series[1] },
])
const tooltipTitle = (i: number) => {
  const x = items.value[i]
  return `${procLabel(x)} · ${t('recon.bin_leak.before')} ${formatBytes(x.before_bytes)}`
}

const bytes = (v: number, cls = 'mono muted') => h('span', { class: cls }, formatBytes(v))
const columns = computed<DataTableColumns<BinLeakItem>>(() => [
  { key: 'rank', title: '#', width: 44, render: (_i, idx) => h('span', { class: 'muted' }, idx + 1) },
  { key: 'pid', title: t('common.process'), minWidth: 240, ellipsis: { tooltip: true }, render: (i) => procCell(i) },
  { key: 'freed', title: t('recon.bin_leak.freed'), width: 120, align: 'right', render: (i) => bytes(i.freed, 'mono grow') },
  { key: 'before', title: t('recon.bin_leak.before'), width: 120, align: 'right', render: (i) => bytes(i.before_bytes) },
  { key: 'after', title: t('recon.bin_leak.after'), width: 120, align: 'right', render: (i) => bytes(i.after_bytes) },
  {
    key: 'count', title: t('recon.bin_leak.count'), width: 140, align: 'right',
    render: (i) => h('span', { class: 'mono muted' }, `${formatNumber(i.before_count)} → ${formatNumber(i.after_count)}`),
  },
  {
    key: 'cf', title: t('common.current_function'), minWidth: 200, ellipsis: { tooltip: true },
    render: (i) => h('span', { class: 'mono muted' }, i.current_function ?? '-'),
  },
])

const skippedColumns = computed<DataTableColumns<BinLeakSkipped>>(() => [
  { key: 'pid', title: t('common.process'), minWidth: 240, ellipsis: { tooltip: true }, render: (i) => procCell(i) },
  { key: 'reason', title: t('recon.bin_leak.reason'), width: 200, render: (i) => t(`recon.bin_leak.reasons.${i.reason}`) },
  {
    key: 'value', title: t('recon.bin_leak.value'), width: 120, align: 'right',
    render: (i) => h('span', { class: 'mono muted' }, i.value == null ? '-'
      : i.reason === 'big_heap' ? formatBytes(i.value) : formatNumber(i.value)),
  },
  {
    key: 'cf', title: t('common.current_function'), minWidth: 200, ellipsis: { tooltip: true },
    render: (i) => h('span', { class: 'mono muted' }, i.current_function ?? '-'),
  },
])

const rowProps = (i: { pid: string }) => ({ style: 'cursor: pointer', onClick: () => emit('open', i.pid) })
</script>

<template>
  <div class="bar">
    <NRadioGroup v-model:value="n" size="small" :disabled="running">
      <NRadioButton v-for="x in [10, 20, 50]" :key="x" :value="x">{{ t('recon.top', { n: x }) }}</NRadioButton>
    </NRadioGroup>
    <NTooltip :disabled="!settings.readOnly">
      <template #trigger>
        <NButton type="primary" :loading="running" :disabled="settings.readOnly" @click="start">
          <template #icon><NIcon :component="TrashBinOutline" /></template>
          {{ running ? t('recon.running') : last ? t('recon.rerun') : t('recon.bin_leak.run') }}
        </NButton>
      </template>
      {{ t('recon.bin_leak.read_only_tip') }}
    </NTooltip>
    <span v-if="running" class="muted">{{ t('recon.elapsed', { n: Math.floor(elapsed) }) }}</span>
    <span v-else-if="last" class="muted">
      {{ t('recon.bin_leak.summary', { time: atText, gc: formatNumber(last.report.gc_count), sec: (last.report.took_ms / 1000).toFixed(1) }) }}
    </span>
    <span v-else class="muted">{{ t('recon.bin_leak.intro') }}</span>
  </div>
  <NAlert v-if="error" type="error" style="margin-bottom: 12px">{{ error }}</NAlert>
  <template v-if="report">
    <NAlert v-if="report.complete === false" type="warning" style="margin-bottom: 12px">{{ t('recon.bin_leak.partial') }}</NAlert>
    <NGrid cols="1 s:2 l:4" responsive="screen" :x-gap="12" :y-gap="12" style="margin-bottom: 12px">
      <NGi>
        <KpiTile :label="t('recon.bin_leak.kpi.binary')" :hint="t('recon.bin_leak.kpi.binary_hint')"
                 :value="`${formatBytes(report.binary_before)} → ${formatBytes(report.binary_after)}`" />
      </NGi>
      <NGi>
        <KpiTile :label="t('recon.bin_leak.kpi.freed')" :value="formatBytes(freedTotal)"
                 :hint="t('recon.bin_leak.kpi.freed_hint', { pct: pct(report.binary_before ? freedTotal / report.binary_before : 0, 1) })" />
      </NGi>
      <NGi>
        <KpiTile :label="t('recon.bin_leak.kpi.gc')" :value="formatNumber(report.gc_count)"
                 :hint="t('recon.bin_leak.kpi.gc_hint', { n: formatNumber(report.process_count) })" />
      </NGi>
      <NGi>
        <KpiTile :label="t('recon.bin_leak.kpi.skipped')" :value="formatNumber(report.skipped)"
                 :hint="t('recon.bin_leak.kpi.skipped_hint')" />
      </NGi>
    </NGrid>
    <NCard v-if="items.length" size="small" :title="t('recon.bin_leak.chart')" style="margin-bottom: 12px">
      <BarChart horizontal :categories="items.map(procLabel)" :series="series" :format="formatBytes"
                :tooltip-title="tooltipTitle" @select="(i) => emit('open', items[i].pid)" />
    </NCard>
    <NCard size="small">
      <NDataTable :columns="columns" :data="items" size="small" :bordered="false" :row-props="rowProps"
                  :row-key="(i: BinLeakItem) => i.pid" :scroll-x="1000" max-height="480">
        <template #empty><span class="muted">{{ t('recon.bin_leak.empty') }}</span></template>
      </NDataTable>
    </NCard>
    <NCollapse v-if="report.skipped_items.length" style="margin-top: 12px">
      <NCollapseItem :title="t('recon.bin_leak.skipped_title', { n: formatNumber(report.skipped) })" name="skipped">
        <NDataTable :columns="skippedColumns" :data="report.skipped_items" size="small" :bordered="false"
                    :row-props="rowProps" :row-key="(i: BinLeakSkipped) => i.pid" :scroll-x="820" />
        <p v-if="report.skipped > report.skipped_items.length" class="note">
          {{ t('recon.bin_leak.skipped_more', { n: formatNumber(report.skipped - report.skipped_items.length) }) }}
        </p>
      </NCollapseItem>
    </NCollapse>
    <p class="note">{{ t('recon.bin_leak.note') }}</p>
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
:deep(.muted) {
  opacity: 0.6;
}
:deep(.grow) {
  font-weight: 600;
}
</style>
