<script setup lang="ts">
import { computed, h, toRef } from 'vue'
import { useI18n } from 'vue-i18n'
import { NButton, NAlert, NIcon, NDataTable, NCard, NGrid, NGi, NProgress, type DataTableColumns } from 'naive-ui'
import { PlayOutline } from '@vicons/ionicons5'
import { formatNumber } from '../../api/format'
import type { PortTypesReport } from '../../api/types'
import { useRecon } from '../../stores/recon'
import DonutChart from '../../charts/DonutChart.vue'
import { useTool } from './useTool'
import { pct } from './shared'

const props = defineProps<{ node: string }>()
const { t } = useI18n()
const recon = useRecon()
const { running, error, last, atText, run } = useTool<PortTypesReport>(toRef(recon, 'ports'), () => props.node)

const start = () => run('recon.port_types', {}, 20000)

type Row = { name: string; count: number }
const report = computed(() => last.value?.report ?? null)
// The node folds the long tail into "other"; show it in the UI language.
const rows = computed<Row[]>(() => (report.value?.types ?? []).map((r) =>
  (r.name === 'other' ? { ...r, name: t('recon.ports.other') } : r)))
const share = (r: Row) => (report.value?.total ? r.count / report.value.total : 0)

const columns = computed<DataTableColumns<Row>>(() => [
  { key: 'name', title: t('recon.ports.name'), minWidth: 160, ellipsis: { tooltip: true },
    render: (r) => h('span', { class: 'mono' }, r.name) },
  { key: 'count', title: t('recon.ports.count'), width: 100, align: 'right',
    sorter: (a, b) => a.count - b.count, render: (r) => h('span', { class: 'mono grow' }, formatNumber(r.count)) },
  {
    key: 'share', title: t('recon.ports.share'), width: 220,
    render: (r) => h('div', { class: 'share' }, [
      h(NProgress, { type: 'line', percentage: Math.round(share(r) * 100), showIndicator: false, height: 8 }),
      h('span', { class: 'mono share-pct' }, pct(share(r), 1)),
    ]),
  },
])
</script>

<template>
  <div class="bar">
    <NButton type="primary" :loading="running" @click="start">
      <template #icon><NIcon :component="PlayOutline" /></template>
      {{ running ? t('recon.running') : last ? t('recon.rerun') : t('recon.run') }}
    </NButton>
    <span v-if="last && !running" class="muted">
      {{ t('recon.ports.summary', { time: atText, total: formatNumber(last.report.total) }) }}
    </span>
    <span v-else-if="!last" class="muted">{{ t('recon.ports.intro') }}</span>
  </div>
  <NAlert v-if="error" type="error" style="margin-bottom: 12px">{{ error }}</NAlert>
  <template v-if="report">
    <NGrid cols="1 l:2" responsive="screen" :x-gap="12" :y-gap="12">
      <NGi>
        <NCard size="small" :title="t('recon.ports.chart')" class="full">
          <DonutChart v-if="rows.length" :items="rows.map((r) => ({ name: r.name, value: r.count }))"
                      :format="formatNumber" :center="formatNumber(report.total)" :center-label="t('recon.ports.total')" />
          <div v-else class="empty">{{ t('recon.ports.empty') }}</div>
        </NCard>
      </NGi>
      <NGi>
        <NCard size="small" class="full">
          <NDataTable :columns="columns" :data="rows" size="small" :bordered="false"
                      :row-key="(r: Row) => r.name" max-height="300">
            <template #empty><span class="muted">{{ t('recon.ports.empty') }}</span></template>
          </NDataTable>
        </NCard>
      </NGi>
    </NGrid>
    <p class="note">{{ t('recon.ports.note') }}</p>
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
.full {
  height: 100%;
}
.empty {
  padding: 48px 0;
  text-align: center;
  opacity: 0.6;
}
.note {
  font-size: 12px;
  opacity: 0.5;
  margin-top: 12px;
}
:deep(.grow) {
  font-weight: 600;
}
:deep(.share) {
  display: flex;
  align-items: center;
  gap: 10px;
}
:deep(.share-pct) {
  width: 52px;
  flex-shrink: 0;
  white-space: nowrap;
  text-align: right;
  font-size: 12px;
}
</style>
