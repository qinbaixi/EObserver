<script setup lang="ts">
// gen call latencies of the traced processes by request kind. Live, the
// table is pulled every 2 s while this tab is open and a row's details on
// click; a saved trace carries every row with its details.
import { computed, h, onBeforeUnmount, ref, watch } from 'vue'
import { useI18n } from 'vue-i18n'
import {
  NDataTable, NAlert, NIcon, NTooltip, NText, NEmpty, NSpin, type DataTableColumns,
} from 'naive-ui'
import { ArrowBackOutline, ArrowForwardOutline } from '@vicons/ionicons5'
import { client } from '../../api/ws'
import { errorText } from '../../api/errors'
import { formatNumber } from '../../api/format'
import { formatLatency, formatTime } from '../../api/trace'
import type { TraceProcess, TraceStats, TraceStatsRow } from '../../api/types'
import LatencyHistogram from '../../charts/LatencyHistogram.vue'

const props = defineProps<{
  // live node; null while a saved trace is shown
  node: string | null
  // the saved trace's statistics (replay only)
  saved?: TraceStats | null
  processes: TraceProcess[]
}>()

const { t } = useI18n()
const live = ref<TraceStats | null>(null)
const error = ref<string | null>(null)
let unsub: (() => void) | null = null

watch(() => props.node, (n) => {
  unsub?.()
  unsub = null
  live.value = null
  if (!n) return
  unsub = client.subscribe('trace.stats', { node: n }, 2000, (d: TraceStats) => {
    error.value = null
    live.value = d
  }, (e) => { error.value = e })
}, { immediate: true })
onBeforeUnmount(() => unsub?.())

const stats = computed<TraceStats | null>(() => (props.node ? live.value : props.saved ?? null))
const rows = computed(() => stats.value?.rows ?? [])
const names = computed(() => new Map(props.processes.map((p) => [p.pid, p.name ?? p.pid])))
const procName = (pid: string) => names.value.get(pid) ?? pid

function kindText(r: TraceStatsRow): string {
  if (r.group === 'other') return t('trace.stats.other_shape')
  if (r.group === 'overflow') return t('trace.stats.overflow', { n: stats.value?.max_kinds ?? 200 })
  return r.kind ?? ''
}

const lat = (v: number | null) => (v === null ? '–' : formatLatency(v))
const byNum = (k: 'calls' | 'avg' | 'p95' | 'max' | 'unanswered') =>
  (a: TraceStatsRow, b: TraceStatsRow) => (a[k] ?? -1) - (b[k] ?? -1)

const columns = computed<DataTableColumns<TraceStatsRow>>(() => [
  {
    key: 'pid', title: t('trace.stats.process'), minWidth: 150, ellipsis: { tooltip: true },
    render: (r) => h('span', { class: 'mono' }, procName(r.pid)),
  },
  {
    key: 'dir', title: '', width: 44, align: 'center',
    render: (r) => h(NTooltip, null, {
      trigger: () => h(NIcon, {
        component: r.dir === 'in' ? ArrowBackOutline : ArrowForwardOutline,
        class: r.dir === 'in' ? 'dir-in' : 'dir-out', size: 16,
      }),
      default: () => t(r.dir === 'in' ? 'trace.stats.dir_in_tip' : 'trace.stats.dir_out_tip'),
    }),
  },
  {
    key: 'kind', title: t('trace.stats.request'), minWidth: 160, ellipsis: { tooltip: true },
    render: (r) => h('span', { class: ['mono', r.group !== 'named' ? 'muted' : ''] }, kindText(r)),
  },
  {
    key: 'calls', title: t('trace.stats.calls'), width: 96, align: 'right',
    sorter: byNum('calls'), defaultSortOrder: 'descend',
    render: (r) => h('span', { class: 'mono' }, formatNumber(r.calls)),
  },
  {
    key: 'avg', title: t('trace.stats.avg'), width: 100, align: 'right', sorter: byNum('avg'),
    render: (r) => h('span', { class: 'mono' }, lat(r.avg)),
  },
  {
    key: 'p95', title: t('trace.stats.p95'), width: 100, align: 'right', sorter: byNum('p95'),
    render: (r) => h('span', { class: 'mono' }, lat(r.p95)),
  },
  {
    key: 'max', title: t('trace.stats.max'), width: 100, align: 'right', sorter: byNum('max'),
    render: (r) => h('span', { class: 'mono' }, lat(r.max)),
  },
  {
    key: 'unanswered', width: 130, align: 'right', sorter: byNum('unanswered'),
    title: () => h(NTooltip, null, {
      trigger: () => h('span', { class: 'help' }, t('trace.stats.unanswered')),
      default: () => t('trace.stats.unanswered_tip'),
    }),
    render: (r) => h('span', { class: 'mono' }, [
      h('span', { class: r.unanswered > 0 ? 'bad' : 'muted' }, formatNumber(r.unanswered)),
      r.pending > 0 ? h('span', { class: 'muted small' }, ` · ${t('trace.stats.pending', { n: r.pending })}`) : null,
    ]),
  },
])

// --- details of the clicked row --------------------------------------------

const selected = ref<number | null>(null)
const fetched = ref<TraceStatsRow | null>(null)
const loading = ref(false)
const detailError = ref<string | null>(null)

const selectedRow = computed(() => rows.value.find((r) => r.row === selected.value) ?? null)
const detail = computed<TraceStatsRow | null>(() =>
  (props.node ? (fetched.value?.row === selected.value ? fetched.value : null) : selectedRow.value))

async function loadDetail() {
  const n = props.node
  if (!n || selected.value === null) return
  loading.value = true
  try {
    const r = await client.request<TraceStats>('trace.stats',
      { node: n, id: stats.value?.id ?? null, row: selected.value })
    fetched.value = r.rows[0] ?? null
    detailError.value = null
  } catch (e) {
    detailError.value = errorText(e)
  } finally {
    loading.value = false
  }
}

// Refetch while the selected row keeps changing.
watch(() => [selected.value, selectedRow.value?.calls, selectedRow.value?.answered] as const,
  ([s], [prev]) => {
    if (s === null) return
    if (s !== prev) fetched.value = null
    void loadDetail()
  })
watch(() => props.node, () => { selected.value = null; fetched.value = null })

const rowProps = (r: TraceStatsRow) => ({
  style: 'cursor: pointer',
  class: r.row === selected.value ? 'row-selected' : '',
  onClick: () => { selected.value = selected.value === r.row ? null : r.row },
})

const detailTitle = computed(() => {
  const r = selectedRow.value ?? detail.value
  if (!r) return ''
  return t(r.dir === 'in' ? 'trace.stats.detail_in' : 'trace.stats.detail_out',
    { proc: procName(r.pid), kind: kindText(r) })
})
const capped = computed(() => (stats.value?.kinds ?? 0) >= (stats.value?.max_kinds ?? Infinity))
</script>

<template>
  <div>
    <NText depth="3" class="intro">{{ t('trace.stats.intro') }}</NText>
    <NAlert v-if="error" type="error" :bordered="false" class="gap">{{ error }}</NAlert>
    <NAlert v-if="capped" type="warning" :bordered="false" class="gap">
      {{ t('trace.stats.capped', { n: stats?.max_kinds ?? 200 }) }}
    </NAlert>
    <NDataTable :columns="columns" :data="rows" :row-key="(r: TraceStatsRow) => r.row" :row-props="rowProps"
                size="small" :max-height="selected === null ? 'calc(100vh - 380px)' : 320" :min-height="120"
                :scroll-x="880">
      <template #empty>
        <NEmpty :description="!stats || stats.status === 'none' ? t('trace.stats.none') : t('trace.stats.empty')" />
      </template>
    </NDataTable>
    <p v-if="rows.length" class="note">{{ t('trace.stats.hint') }}</p>

    <div v-if="selected !== null" class="detail">
      <div class="detail-head">
        <strong class="mono">{{ detailTitle }}</strong>
        <NText v-if="selectedRow" depth="3">
          {{ t('trace.stats.detail_summary', {
            calls: formatNumber(selectedRow.calls), answered: formatNumber(selectedRow.answered),
            avg: lat(selectedRow.avg), p95: lat(selectedRow.p95), max: lat(selectedRow.max) }) }}
        </NText>
      </div>
      <NAlert v-if="detailError" type="error" :bordered="false">{{ detailError }}</NAlert>
      <NSpin v-else-if="!detail" size="small" :description="t('trace.stats.loading')" class="spin" />
      <template v-else-if="detail.answered === 0">
        <NText depth="3">{{ t('trace.stats.no_answer') }}</NText>
      </template>
      <div v-else class="detail-body">
        <div class="pane">
          <div class="pane-title">{{ t('trace.stats.distribution') }}</div>
          <LatencyHistogram :hist="detail.hist ?? []" :height="300" />
        </div>
        <div class="pane">
          <div class="pane-title">{{ t('trace.stats.slowest') }}</div>
          <table class="slow">
            <thead>
              <tr>
                <th>{{ t('trace.stats.time') }}</th>
                <th class="num">{{ t('trace.stats.latency') }}</th>
                <th>{{ t(detail.dir === 'in' ? 'trace.stats.peer_in' : 'trace.stats.peer_out') }}</th>
                <th>{{ t('trace.stats.content') }}</th>
              </tr>
            </thead>
            <tbody>
              <tr v-for="(s, i) in detail.slowest ?? []" :key="i">
                <td class="mono muted nowrap">{{ formatTime(s.t) }}</td>
                <td class="mono num nowrap">{{ formatLatency(s.latency) }}</td>
                <td class="mono ell" :title="s.peer ?? ''">{{ s.peer ?? '' }}</td>
                <td class="mono ell" :title="s.summary">{{ s.summary }}</td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>
    </div>
  </div>
</template>

<style scoped>
.intro {
  display: block;
  font-size: 13px;
  margin-bottom: 10px;
}
.gap {
  margin-bottom: 10px;
}
.note {
  font-size: 12px;
  opacity: 0.6;
  margin: 8px 0 0;
}
.detail {
  margin-top: 16px;
  padding: 14px 16px;
  border-radius: 8px;
  background: rgba(128, 128, 128, 0.08);
}
.detail-head {
  display: flex;
  flex-wrap: wrap;
  align-items: baseline;
  gap: 4px 16px;
  margin-bottom: 12px;
}
.detail-body {
  display: grid;
  grid-template-columns: minmax(0, 1fr) minmax(0, 1.2fr);
  gap: 16px 24px;
}
@media (max-width: 1100px) {
  .detail-body {
    grid-template-columns: minmax(0, 1fr);
  }
}
.pane-title {
  font-weight: 600;
  margin-bottom: 8px;
  font-size: 13px;
}
.spin {
  margin: 12px 0;
}
.slow {
  width: 100%;
  border-collapse: collapse;
  table-layout: fixed;
  font-size: 12.5px;
}
.slow th {
  text-align: left;
  font-weight: 500;
  opacity: 0.6;
  padding: 4px 8px;
}
.slow th:nth-child(1) { width: 96px; }
.slow th:nth-child(2) { width: 84px; }
.slow th:nth-child(3) { width: 30%; }
.slow td {
  padding: 4px 8px;
  border-top: 1px solid rgba(128, 128, 128, 0.15);
}
.num {
  text-align: right !important;
}
.ell {
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
.small {
  font-size: 12px;
}
.help {
  border-bottom: 1px dashed currentColor;
  cursor: help;
}
:deep(.muted) {
  opacity: 0.6;
}
.nowrap {
  white-space: nowrap;
}
:deep(.dir-in) {
  color: #18a058;
}
:deep(.dir-out) {
  color: #2080f0;
}
:deep(.bad) {
  color: #d03050;
}
:deep(.row-selected td) {
  background: rgba(32, 128, 240, 0.08) !important;
}
</style>
