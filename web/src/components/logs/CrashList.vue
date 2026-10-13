<script setup lang="ts">
import { computed, h } from 'vue'
import { useI18n } from 'vue-i18n'
import { NDataTable, NTag, NTooltip, NEmpty, NText, type DataTableColumns } from 'naive-ui'
import { formatNumber } from '../../api/format'
import { formatTime } from '../../api/trace'
import type { CrashGroup, RestartGroup } from '../../api/types'
import { useLogs } from '../../stores/logs'

const { t } = useI18n()
const logs = useLogs()

// Restarted this often within the last minute counts as restarting often.
const FREQUENT = 3

function recent(r: RestartGroup): number {
  const now = logs.status?.now
  if (!now) return 0
  const since = (now - 60000) * 1000
  return r.times.filter((x) => x >= since).length
}

const restarts = computed(() =>
  [...logs.restarts.values()]
    .map((r) => ({ r, recent: recent(r) }))
    .sort((a, b) => Number(b.recent >= FREQUENT) - Number(a.recent >= FREQUENT)
      || b.r.count - a.r.count || b.r.last - a.r.last))

type RestartRow = { r: RestartGroup; recent: number }

const tag = (text: string, tip: string, type: 'error' | 'default' | 'warning' = 'default') =>
  h(NTooltip, null, {
    trigger: () => h(NTag, { size: 'tiny', bordered: false, type, style: 'margin-left: 6px' },
      { default: () => text }),
    default: () => tip,
  })

const restartColumns = computed<DataTableColumns<RestartRow>>(() => [
  {
    key: 'supervisor', title: t('logs.crashes.supervisor'), minWidth: 160, ellipsis: { tooltip: true },
    render: ({ r }) => h('span', { class: 'mono' }, r.supervisor),
  },
  {
    key: 'child', title: t('logs.crashes.child'), minWidth: 200,
    render: ({ r, recent: n }) => h('span', null, [
      h('span', { class: 'mono' }, r.child),
      n >= FREQUENT ? h(NTag, { size: 'tiny', bordered: false, type: 'error', style: 'margin-left: 6px' },
        { default: () => t('logs.crashes.frequent') }) : null,
      r.gave_up ? tag(t('logs.crashes.gave_up'), t('logs.crashes.gave_up_tip'), 'error') : null,
      r.restart_type === 'temporary' ? tag(t('logs.crashes.temporary'), t('logs.crashes.temporary_tip')) : null,
    ]),
  },
  {
    key: 'count', title: t('logs.crashes.restarts'), width: 150, align: 'right',
    render: ({ r, recent: n }) => h('span', null, [
      h('b', { class: n >= FREQUENT ? 'hot-text mono' : 'mono' }, formatNumber(r.count)),
      // The target keeps the last 10 restart times only.
      n > 0 ? h('div', { class: 'sub muted' },
        t('logs.crashes.recent', { n: n >= 10 && n === r.times.length ? `${n}+` : n })) : null,
      r.failed_starts > 0 ? h('div', { class: 'sub hot-text' }, t('logs.crashes.failed_starts', { n: r.failed_starts })) : null,
    ]),
  },
  {
    key: 'last', title: t('logs.crashes.last'), width: 120,
    render: ({ r }) => h('span', { class: 'mono muted nowrap' }, formatTime(r.last)),
  },
  {
    key: 'reason', title: t('logs.crashes.reason'), minWidth: 260, ellipsis: { tooltip: { width: 600 } },
    render: ({ r }) => h('span', { class: 'mono' }, r.reason),
  },
])

const crashes = computed(() => [...logs.crashes.values()].sort((a, b) => b.last - a.last))

function renderCrash(c: CrashGroup) {
  return h('div', { class: 'detail' }, [
    h('div', { class: 'facts' }, [
      h('span', null, [h(NText, { depth: 3 }, { default: () => t('procs.colon', { label: t('logs.crashes.class') }) }), h('span', { class: 'mono' }, c.class)]),
      h('span', null, [h(NText, { depth: 3 }, { default: () => t('procs.colon', { label: t('logs.crashes.first') }) }), h('span', { class: 'mono' }, formatTime(c.first))]),
      h('span', null, [h(NText, { depth: 3 }, { default: () => t('procs.colon', { label: t('logs.crashes.last') }) }), h('span', { class: 'mono' }, formatTime(c.last))]),
      c.pid ? h('span', null, [h(NText, { depth: 3 }, { default: () => t('procs.colon', { label: t('logs.crashes.latest_pid') }) }), h('span', { class: 'mono' }, c.pid)]) : null,
    ]),
    h('div', { class: 'label' }, t('logs.crashes.full_reason')),
    h('pre', { class: 'term' }, c.text),
    h('div', { class: 'label' }, t('logs.crashes.stack')),
    c.stack.length
      ? h('ol', { class: 'stack mono' }, c.stack.map((f) => h('li', null, [
        h('span', null, f.mfa),
        f.location ? h('span', { class: 'muted' }, `  ${f.location}`) : null,
      ])))
      : h(NText, { depth: 3 }, { default: () => t('logs.crashes.no_stack') }),
  ])
}

const crashColumns = computed<DataTableColumns<CrashGroup>>(() => [
  { type: 'expand', renderExpand: renderCrash },
  {
    key: 'last', title: t('logs.crashes.last'), width: 120,
    render: (c) => h('span', { class: 'mono muted nowrap' }, formatTime(c.last)),
  },
  {
    key: 'who', title: t('logs.crashes.process'), minWidth: 200, ellipsis: { tooltip: true },
    render: (c) => c.who
      ? h('span', { class: 'mono' }, c.who)
      : h('span', null, [h(NText, { depth: 3 }, { default: () => t('logs.crashes.plain_process') }), ' ',
        h('span', { class: 'mono' }, c.pid ?? '')]),
  },
  {
    key: 'reason', title: t('logs.crashes.reason'), minWidth: 320, ellipsis: { tooltip: false },
    render: (c) => h('span', { class: 'mono' }, c.reason),
  },
  {
    key: 'count', title: t('logs.crashes.count'), width: 90, align: 'right',
    render: (c) => c.count > 1
      ? h(NTag, { size: 'small', bordered: false, type: 'error', round: true }, { default: () => `×${formatNumber(c.count)}` })
      : h('span', { class: 'mono muted' }, '1'),
  },
])

const restartRowProps = (row: RestartRow) => (row.recent >= FREQUENT ? { class: 'hot' } : {})
</script>

<template>
  <section>
    <div class="head">
      <h3>{{ t('logs.crashes.restarts_title') }}</h3>
      <NText depth="3" class="hint">{{ t('logs.crashes.restarts_intro') }}</NText>
    </div>
    <NDataTable :columns="restartColumns" :data="restarts" :row-key="(row: RestartRow) => row.r.id"
                :row-props="restartRowProps" size="small" :max-height="320" :scroll-x="900">
      <template #empty><NEmpty :description="t('logs.crashes.no_restarts')" /></template>
    </NDataTable>
  </section>
  <section>
    <div class="head">
      <h3>{{ t('logs.crashes.crashes_title') }}</h3>
      <NText depth="3" class="hint">{{ t('logs.crashes.crashes_intro') }}</NText>
    </div>
    <NDataTable :columns="crashColumns" :data="crashes" :row-key="(c: CrashGroup) => c.id"
                size="small" :scroll-x="900">
      <template #empty><NEmpty :description="t('logs.crashes.no_crashes')" /></template>
    </NDataTable>
  </section>
</template>

<style scoped>
section + section {
  margin-top: 24px;
}
.head {
  display: flex;
  align-items: baseline;
  flex-wrap: wrap;
  gap: 4px 12px;
  margin-bottom: 8px;
}
h3 {
  margin: 0;
  font-size: 15px;
}
.hint {
  font-size: 12px;
}
:deep(.hot td) {
  background: rgba(208, 48, 80, 0.08) !important;
}
:deep(.hot-text) {
  color: #d03050;
}
:deep(.sub) {
  font-size: 12px;
}
:deep(.muted) {
  opacity: 0.6;
}
:deep(.nowrap) {
  white-space: nowrap;
}
:deep(.detail) {
  padding: 4px 8px 8px;
}
:deep(.facts) {
  display: flex;
  flex-wrap: wrap;
  gap: 4px 24px;
  font-size: 13px;
  margin-bottom: 8px;
}
:deep(.label) {
  font-size: 12px;
  opacity: 0.7;
  margin: 8px 0 4px;
}
:deep(.term) {
  margin: 0;
  padding: 10px 12px;
  border-radius: 6px;
  background: rgba(128, 128, 128, 0.1);
  font-family: 'JetBrains Mono', 'SFMono-Regular', Menlo, Consolas, monospace;
  font-size: 12.5px;
  max-height: 320px;
  overflow: auto;
  white-space: pre-wrap;
  word-break: break-all;
}
:deep(.stack) {
  margin: 0;
  padding-left: 24px;
  font-size: 12px;
  line-height: 1.7;
}
</style>
