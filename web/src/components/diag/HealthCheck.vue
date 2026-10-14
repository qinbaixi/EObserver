<script setup lang="ts">
import { computed, h, ref } from 'vue'
import { useI18n } from 'vue-i18n'
import { useRouter } from 'vue-router'
import { NButton, NAlert, NIcon, NDataTable, NTag, type DataTableColumns } from 'naive-ui'
import {
  AlertCircle, Warning, CheckmarkCircle, RemoveCircleOutline, MedkitOutline,
} from '@vicons/ionicons5'
import { client } from '../../api/ws'
import { errorText } from '../../api/errors'
import { formatBytes, formatNumber } from '../../api/format'
import type { DiagCheck, DiagItem, DiagLevel, DiagReport } from '../../api/types'
import { useDiag } from '../../stores/diag'

const props = defineProps<{ node: string }>()
const emit = defineEmits<{ open: [pid: string] }>()
const { t, te } = useI18n()
const router = useRouter()
const diag = useDiag()

const running = ref(false)
const error = ref<string | null>(null)
const last = computed(() => diag.health[props.node] ?? null)

async function run() {
  if (running.value) return
  running.value = true
  error.value = null
  try {
    const report = await client.request<DiagReport>('diag.check', { node: props.node }, 60000)
    diag.health[props.node] = { report, at: Date.now() }
  } catch (e) {
    error.value = errorText(e)
  } finally {
    running.value = false
  }
}

defineExpose({ run })

const ORDER: Record<DiagLevel, number> = { crit: 0, warn: 1, ok: 2, skip: 3 }
const checks = computed(() =>
  [...(last.value?.report.checks ?? [])].sort((a, b) => ORDER[a.level] - ORDER[b.level]))
const counts = computed(() => {
  const c = { crit: 0, warn: 0, ok: 0 }
  for (const x of checks.value) if (x.level !== 'skip') c[x.level]++
  return c
})

const ICONS = { crit: AlertCircle, warn: Warning, ok: CheckmarkCircle, skip: RemoveCircleOutline }

const BYTES = new Set(['process_memory', 'ets_memory', 'binary_holders', 'dist_queue'])
const pct = (a: number, b: number) => (b > 0 ? Math.round((a * 100) / b) : 0)

function detail(c: DiagCheck): string {
  if (c.level === 'skip') return t('diag.check.skipped')
  const key = `diag.check.${c.id}`
  const warn = c.warn == null ? '' : BYTES.has(c.id) ? formatBytes(c.warn) : formatNumber(c.warn)
  const value = c.value ?? 0
  const okKey = `${key}.detail_ok`
  const useOk = c.level === 'ok' && (value === 0 || ['process_memory', 'ets_memory'].includes(c.id))
  if (useOk && te(okKey)) return t(okKey, { warn })
  return t(`${key}.detail`, {
    value: formatNumber(value),
    limit: formatNumber(Number(c.limit ?? 0)),
    pct: c.limit ? pct(value, Number(c.limit)) : c.total ? pct(value, Number(c.total)) : 0,
    bytes: formatBytes(Number(c.bytes ?? value)),
    max: formatNumber(Number(c.max ?? 0)),
    schedulers: Number(c.schedulers ?? 0),
    seconds: Number(c.seconds ?? 0),
    warn,
  })
}


function itemValue(c: DiagCheck, i: DiagItem) {
  if (i.value == null) return t('common.too_many')
  return BYTES.has(c.id) ? formatBytes(i.value) : formatNumber(i.value)
}

function columns(c: DiagCheck): DataTableColumns<DiagItem> {
  const value = {
    key: 'value', title: t('diag.health.value'), width: 120, align: 'right' as const,
    render: (i: DiagItem) => h('span', { class: 'mono' }, itemValue(c, i)),
  }
  if (c.id === 'ets_memory') {
    return [
      { key: 'name', title: t('diag.health.table'), render: (i) => h('span', { class: 'mono' }, String(i.name ?? i.table)) },
      { key: 'owner', title: t('diag.health.owner'), width: 140, render: (i) => h('span', { class: 'mono muted' }, i.owner ?? '-') },
      value,
    ]
  }
  if (c.id === 'dist_queue') {
    return [
      { key: 'node', title: t('diag.health.node'), render: (i) => h('span', { class: 'mono' }, i.node ?? '') },
      { ...value, title: t('diag.health.queue_bytes') },
    ]
  }
  return [
    {
      key: 'pid', title: t('common.process'), minWidth: 220, ellipsis: { tooltip: true },
      render: (i) => h('span', null, [
        h('span', { class: 'mono pid' }, i.pid ?? ''), ' ',
        i.name ? h('b', null, i.name) : h('span', { class: 'mono muted' }, i.initial_call ?? ''),
      ]),
    },
    {
      key: 'cf', title: t('common.current_function'), minWidth: 200, ellipsis: { tooltip: true },
      render: (i) => h('span', { class: 'mono muted' }, i.current_function ?? '-'),
    },
    value,
  ]
}

function rowProps(c: DiagCheck) {
  return (i: DiagItem) => ({
    style: 'cursor: pointer',
    onClick: () => {
      if (i.pid) emit('open', i.pid)
      else if (c.id === 'ets_memory' && i.table) void router.push({ path: '/tables', query: { table: i.table } })
    },
  })
}

const atText = computed(() => last.value ? new Date(last.value.at).toLocaleTimeString() : '')
</script>

<template>
  <div class="bar">
    <NButton type="primary" :loading="running" @click="run">
      <template #icon><NIcon :component="MedkitOutline" /></template>
      {{ running ? t('diag.health.running') : last ? t('diag.health.rerun') : t('diag.health.run') }}
    </NButton>
    <span v-if="last" class="summary">
      <span>{{ t('diag.health.summary', counts) }}</span>
      <span class="muted"> · {{ t('diag.health.checked_at', { time: atText, ms: last.report.took_ms, procs: formatNumber(last.report.process_count) }) }}</span>
    </span>
    <span v-else class="muted">{{ t('diag.health.intro') }}</span>
  </div>
  <NAlert v-if="error" type="error" style="margin-bottom: 12px">{{ error }}</NAlert>
  <div class="checks">
    <div v-for="c in checks" :key="c.id" class="check" :class="c.level">
      <div class="head">
        <NIcon :component="ICONS[c.level]" size="20" class="icon" />
        <span class="title">{{ t(`diag.check.${c.id}.title`) }}</span>
        <NTag size="small" :bordered="false"
              :type="c.level === 'crit' ? 'error' : c.level === 'warn' ? 'warning' : c.level === 'ok' ? 'success' : 'default'">
          {{ t(`diag.level.${c.level}`) }}
        </NTag>
        <span class="detail">{{ detail(c) }}</span>
      </div>
      <template v-if="c.level === 'warn' || c.level === 'crit'">
        <div class="advice"><b>{{ t('procs.colon', { label: t('diag.health.advice') }) }}</b>{{ t(`diag.check.${c.id}.advice`) }}</div>
        <NDataTable v-if="c.items.length" :columns="columns(c)" :data="c.items" size="small"
                    :row-props="rowProps(c)" :bordered="false" class="items" />
      </template>
    </div>
  </div>
</template>

<style scoped>
.bar {
  display: flex;
  align-items: center;
  gap: 16px;
  flex-wrap: wrap;
  margin-bottom: 16px;
}
.summary {
  font-size: 13px;
}
.muted {
  opacity: 0.6;
  font-size: 13px;
}
.checks {
  display: flex;
  flex-direction: column;
  gap: 8px;
}
.check {
  background: var(--n-color, rgba(128, 128, 128, 0.06));
  border-radius: 10px;
  padding: 10px 14px;
  border-left: 4px solid transparent;
  background-color: rgba(128, 128, 128, 0.07);
}
.check.crit {
  border-left-color: #d03050;
}
.check.warn {
  border-left-color: #f0a020;
}
.check.ok {
  border-left-color: #18a058;
}
.check.skip {
  opacity: 0.6;
}
.head {
  display: flex;
  align-items: center;
  gap: 10px;
  flex-wrap: wrap;
}
.crit .icon {
  color: #d03050;
}
.warn .icon {
  color: #f0a020;
}
.ok .icon {
  color: #18a058;
}
.title {
  font-weight: 600;
  min-width: 150px;
}
.detail {
  opacity: 0.8;
  font-size: 13px;
}
.advice {
  margin: 8px 0 4px 30px;
  font-size: 13px;
  line-height: 1.6;
  opacity: 0.85;
}
.items {
  margin: 8px 0 4px 30px;
  width: calc(100% - 30px);
}
:deep(.muted) {
  opacity: 0.6;
}
</style>
