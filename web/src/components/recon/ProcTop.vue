<script setup lang="ts">
import { computed, h, ref, toRef } from 'vue'
import { useI18n } from 'vue-i18n'
import {
  NButton, NAlert, NIcon, NDataTable, NTag, NRadioGroup, NRadioButton, NCard, NTooltip, type DataTableColumns,
} from 'naive-ui'
import { PlayOutline } from '@vicons/ionicons5'
import { formatBytes, formatNumber } from '../../api/format'
import { term } from '../../api/term'
import type { ReconProcAttr, ReconProcItem, ReconProcReport } from '../../api/types'
import { useRecon } from '../../stores/recon'
import BarChart from '../../charts/BarChart.vue'
import { useTool } from './useTool'
import { compact, procCell, procLabel } from './shared'

const props = defineProps<{ node: string }>()
const emit = defineEmits<{ open: [pid: string] }>()
const { t } = useI18n()
const recon = useRecon()
const { running, error, last, atText, run } = useTool<ReconProcReport>(toRef(recon, 'proc'), () => props.node)

const ATTRS: ReconProcAttr[] = ['memory', 'reductions', 'message_queue_len', 'total_heap_size', 'binary_memory']
const BYTES = new Set<ReconProcAttr>(['memory', 'total_heap_size', 'binary_memory'])
const attribute = ref<ReconProcAttr>('memory')
const n = ref(20)

const start = () => run('recon.proc_count', { attribute: attribute.value, n: n.value }, 60000)

const fmt = (a: ReconProcAttr, v: number | null) =>
  (v == null ? t('common.too_many') : BYTES.has(a) ? formatBytes(v) : formatNumber(v))
const axisFmt = (a: ReconProcAttr) => (v: number) => (BYTES.has(a) ? formatBytes(v) : compact(v))

const report = computed(() => last.value?.report ?? null)
const attr = computed(() => report.value?.attribute ?? attribute.value)
const items = computed(() => report.value?.items ?? [])
const attrName = (a: ReconProcAttr) => t(`recon.proc.attrs.${a}`)

const columns = computed<DataTableColumns<ReconProcItem>>(() => {
  const a = attr.value
  const other = (['memory', 'reductions', 'message_queue_len', 'total_heap_size'] as const).filter((k) => k !== a)
  return [
    { key: 'rank', title: '#', width: 44, render: (_i, idx) => h('span', { class: 'muted' }, idx + 1) },
    {
      key: 'pid', title: t('common.process'), minWidth: 240, ellipsis: { tooltip: true },
      render: (i) => procCell(i, i.too_many
        ? h(NTag, { size: 'tiny', bordered: false, type: 'warning', style: 'margin-left: 6px' },
          { default: () => t('common.too_many') })
        : null),
    },
    {
      key: 'value', title: term(attrName(a), t(`recon.proc.attr_tips.${a}`)), width: 140, align: 'right',
      render: (i) => h('span', { class: 'mono grow' }, fmt(a, i.value)),
    },
    ...other.map((k) => ({
      key: k, title: attrName(k), width: 120, align: 'right' as const,
      render: (i: ReconProcItem) => h('span', { class: 'mono muted' }, fmt(k, i[k])),
    })),
    {
      key: 'cf', title: t('common.current_function'), minWidth: 200, ellipsis: { tooltip: true },
      render: (i) => h('span', { class: 'mono muted' }, i.current_function ?? '-'),
    },
  ]
})

const rowProps = (i: ReconProcItem) => ({ style: 'cursor: pointer', onClick: () => emit('open', i.pid) })
</script>

<template>
  <div class="bar">
    <NRadioGroup v-model:value="attribute" size="small" :disabled="running">
      <NRadioButton v-for="a in ATTRS" :key="a" :value="a">
        <NTooltip :delay="400">
          <template #trigger><span>{{ attrName(a) }}</span></template>
          {{ t(`recon.proc.attr_tips.${a}`) }}
        </NTooltip>
      </NRadioButton>
    </NRadioGroup>
    <NRadioGroup v-model:value="n" size="small" :disabled="running">
      <NRadioButton v-for="x in [10, 20, 50]" :key="x" :value="x">{{ t('recon.top', { n: x }) }}</NRadioButton>
    </NRadioGroup>
    <NButton type="primary" :loading="running" @click="start">
      <template #icon><NIcon :component="PlayOutline" /></template>
      {{ running ? t('recon.running') : last ? t('recon.rerun') : t('recon.run') }}
    </NButton>
    <span v-if="last && !running" class="muted">
      {{ t('recon.proc.summary', { time: atText, procs: formatNumber(last.report.process_count), ms: last.report.took_ms }) }}
    </span>
    <span v-else-if="!last" class="muted">{{ t('recon.proc.intro') }}</span>
  </div>
  <NAlert v-if="error" type="error" style="margin-bottom: 12px">{{ error }}</NAlert>
  <template v-if="report">
    <NCard v-if="items.length" size="small" :title="t('recon.proc.chart', { attr: attrName(attr), n: items.length })"
           style="margin-bottom: 12px">
      <BarChart horizontal :categories="items.map(procLabel)"
                :series="[{ name: attrName(attr), data: items.map((i) => i.value) }]"
                :format="axisFmt(attr)" @select="(i) => emit('open', items[i].pid)" />
    </NCard>
    <NCard size="small">
      <NDataTable :columns="columns" :data="items" size="small" :bordered="false" :row-props="rowProps"
                  :row-key="(i: ReconProcItem) => i.pid" :scroll-x="1000" max-height="480">
        <template #empty><span class="muted">{{ t('recon.proc.empty') }}</span></template>
      </NDataTable>
    </NCard>
    <p class="note">{{ t('recon.open_hint') }}</p>
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
}
:deep(.muted) {
  opacity: 0.6;
}
:deep(.grow) {
  font-weight: 600;
}
</style>
