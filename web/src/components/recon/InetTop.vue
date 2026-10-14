<script setup lang="ts">
import { computed, h, ref, toRef } from 'vue'
import { useI18n } from 'vue-i18n'
import {
  NButton, NAlert, NIcon, NDataTable, NTag, NRadioGroup, NRadioButton, NCard, NTooltip, NProgress,
  type DataTableColumns,
} from 'naive-ui'
import { PlayOutline } from '@vicons/ionicons5'
import { formatBytes, formatNumber } from '../../api/format'
import type { InetAttr, InetItem, InetReport } from '../../api/types'
import { useRecon } from '../../stores/recon'
import BarChart from '../../charts/BarChart.vue'
import { useTool } from './useTool'
import { compact } from './shared'

const props = defineProps<{ node: string }>()
const emit = defineEmits<{ open: [pid: string] }>()
const { t } = useI18n()
const recon = useRecon()
const { running, error, elapsed, last, atText, run } = useTool<InetReport>(toRef(recon, 'inet'), () => props.node)

const ATTRS: InetAttr[] = ['oct', 'recv_oct', 'send_oct', 'cnt', 'recv_cnt', 'send_cnt']
const attribute = ref<InetAttr>('oct')
const n = ref(20)
const mode = ref<'snapshot' | 'window'>('snapshot')
const seconds = ref(10)
const asked = ref(0)

function start() {
  const s = mode.value === 'window' ? seconds.value : 0
  asked.value = s
  void run('recon.inet_count', { attribute: attribute.value, n: n.value, seconds: s }, s * 1000 + 60000)
}

const isBytes = (a: InetAttr) => a.endsWith('oct')
const fmt = (a: InetAttr) => (v: number) => (isBytes(a) ? formatBytes(v) : formatNumber(v))
const axisFmt = (a: InetAttr) => (v: number) => (isBytes(a) ? formatBytes(v) : compact(v))
const attrName = (a: InetAttr) => t(`recon.inet.attrs.${a}`)

const report = computed(() => last.value?.report ?? null)
const attr = computed(() => report.value?.attribute ?? attribute.value)
const items = computed(() => report.value?.items ?? [])
const label = (i: InetItem) => `${i.remote ?? i.local ?? i.port} · ${i.owner_name ?? i.owner ?? '-'}`
const chartTitle = computed(() => {
  const r = report.value!
  const named = { attr: attrName(r.attribute), n: r.items.length, seconds: r.seconds.toFixed(1) }
  return r.seconds > 0 ? t('recon.inet.chart_window', named) : t('recon.inet.chart', named)
})

const mono = (s: string | null, cls = 'mono muted') => h('span', { class: cls }, s ?? '-')
const columns = computed<DataTableColumns<InetItem>>(() => {
  const a = attr.value
  const f = fmt(a)
  const [recv, send] = isBytes(a) ? (['recv_oct', 'send_oct'] as const) : (['recv_cnt', 'send_cnt'] as const)
  return [
    { key: 'rank', title: '#', width: 44, render: (_i, idx) => h('span', { class: 'muted' }, idx + 1) },
    {
      key: 'port', title: t('recon.inet.port'), width: 130,
      render: (i) => h('span', null, [
        h('span', { class: 'mono' }, i.port),
        i.new ? h(NTag, { size: 'tiny', bordered: false, type: 'info', style: 'margin-left: 6px' }, { default: () => t('common.new') }) : null,
      ]),
    },
    {
      key: 'type', title: t('recon.inet.type'), width: 70,
      render: (i) => h(NTag, { size: 'small', bordered: false }, { default: () => i.type }),
    },
    { key: 'local', title: t('recon.inet.local'), minWidth: 150, ellipsis: { tooltip: true }, render: (i) => mono(i.local, 'mono') },
    { key: 'remote', title: t('recon.inet.remote'), minWidth: 150, ellipsis: { tooltip: true }, render: (i) => mono(i.remote, 'mono') },
    {
      key: 'owner', title: t('recon.inet.owner'), minWidth: 200, ellipsis: { tooltip: true },
      render: (i) => i.owner
        ? h('a', {
          class: 'owner',
          onClick: (e: MouseEvent) => { e.stopPropagation(); emit('open', i.owner!) },
        }, [h('span', { class: 'mono pid' }, i.owner), i.owner_name ? [' ', h('b', null, i.owner_name)] : null])
        : mono(null),
    },
    { key: 'value', title: attrName(a), width: 130, align: 'right', render: (i) => mono(f(i.value), 'mono grow') },
    {
      key: 'io', title: t('recon.inet.io'), width: 220, align: 'right',
      render: (i) => mono(`${f(i[recv])} / ${f(i[send])}`),
    },
  ]
})

const rowProps = (i: InetItem) => ({
  style: i.owner ? 'cursor: pointer' : undefined,
  onClick: () => { if (i.owner) emit('open', i.owner) },
})
</script>

<template>
  <div class="bar">
    <NRadioGroup v-model:value="attribute" size="small" :disabled="running">
      <NRadioButton v-for="a in ATTRS" :key="a" :value="a">{{ attrName(a) }}</NRadioButton>
    </NRadioGroup>
    <NRadioGroup v-model:value="n" size="small" :disabled="running">
      <NRadioButton v-for="x in [10, 20, 50]" :key="x" :value="x">{{ t('recon.top', { n: x }) }}</NRadioButton>
    </NRadioGroup>
  </div>
  <div class="bar">
    <NTooltip>
      <template #trigger>
        <NRadioGroup v-model:value="mode" size="small" :disabled="running">
          <NRadioButton value="snapshot">{{ t('recon.inet.mode.snapshot') }}</NRadioButton>
          <NRadioButton value="window">{{ t('recon.inet.mode.window') }}</NRadioButton>
        </NRadioGroup>
      </template>
      {{ t('recon.inet.mode_tip') }}
    </NTooltip>
    <NRadioGroup v-if="mode === 'window'" v-model:value="seconds" size="small" :disabled="running">
      <NRadioButton v-for="s in [5, 10, 30]" :key="s" :value="s">{{ t('recon.seconds', { n: s }) }}</NRadioButton>
    </NRadioGroup>
    <NButton type="primary" :loading="running" @click="start">
      <template #icon><NIcon :component="PlayOutline" /></template>
      {{ running ? t('recon.running') : last ? t('recon.rerun') : t('recon.run') }}
    </NButton>
    <span v-if="running && asked" class="muted">{{ t('recon.left', { n: Math.max(0, Math.ceil(asked - elapsed)) }) }}</span>
    <span v-else-if="last && !running" class="muted">
      {{ last.report.seconds > 0
        ? t('recon.inet.summary_window', { time: atText, seconds: last.report.seconds.toFixed(1), count: formatNumber(last.report.socket_count) })
        : t('recon.inet.summary_snapshot', { time: atText, count: formatNumber(last.report.socket_count) }) }}
    </span>
    <span v-else-if="!last" class="muted">{{ t('recon.inet.intro') }}</span>
  </div>
  <NProgress v-if="running && asked" type="line" :percentage="Math.min(100, Math.round((elapsed * 100) / asked))"
             :show-indicator="false" :height="3" style="margin-bottom: 12px" />
  <NAlert v-if="error" type="error" style="margin-bottom: 12px">{{ error }}</NAlert>
  <template v-if="report">
    <NCard v-if="items.length" size="small" :title="chartTitle" style="margin-bottom: 12px">
      <BarChart horizontal :categories="items.map(label)"
                :series="[{ name: attrName(attr), data: items.map((i) => i.value) }]"
                :format="axisFmt(attr)" :tooltip-title="(i) => `${items[i].port} · ${label(items[i])}`"
                @select="(i) => items[i].owner && emit('open', items[i].owner!)" />
    </NCard>
    <NCard size="small">
      <NDataTable :columns="columns" :data="items" size="small" :bordered="false" :row-props="rowProps"
                  :row-key="(i: InetItem) => i.port" :scroll-x="1100" max-height="480">
        <template #empty><span class="muted">{{ t('recon.inet.empty') }}</span></template>
      </NDataTable>
    </NCard>
    <p class="note">{{ t('recon.inet.note') }}</p>
  </template>
</template>

<style scoped>
.bar {
  display: flex;
  align-items: center;
  gap: 12px 16px;
  flex-wrap: wrap;
  margin-bottom: 12px;
}
.bar + .bar {
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
:deep(.owner) {
  cursor: pointer;
}
:deep(.owner:hover) {
  text-decoration: underline;
}
</style>
