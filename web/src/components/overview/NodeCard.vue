<script setup lang="ts">
import { computed } from 'vue'
import { useI18n } from 'vue-i18n'
import { NTag, useThemeVars } from 'naive-ui'
import { useLoad, MAX_WINDOW_MS } from '../../stores/load'
import { useNodes } from '../../stores/nodes'
import { quickCheck, worst, type QuickFinding } from '../../api/health'
import { formatBytes, formatNumber } from '../../api/format'
import { lineData } from '../../charts/gaps'
import Sparkline from '../../charts/Sparkline.vue'
import StatusDot from '../StatusDot.vue'

// One node on the overview wall: identity, three small trends and a status
// light from the cheap health checks.
const props = defineProps<{ node: string }>()
const emit = defineEmits<{ open: [node: string] }>()

const { t } = useI18n()
const load = useLoad()
const nodes = useNodes()
const vars = useThemeVars()

const info = computed(() => nodes.nodes[props.node] ?? null)
const connected = computed(() => info.value?.status === 'connected')
const points = computed(() => load.history[props.node]?.value ?? [])
const live = computed(() => load.summaries[props.node] ?? null)
// The summary taken at connect time fills in until the first live one.
const summary = computed(() => live.value ?? info.value?.summary ?? null)
const last = computed(() => points.value.at(-1) ?? null)
const now = computed(() => last.value?.time ?? Date.now())

const findings = computed(() => (connected.value ? quickCheck(live.value, points.value) : []))
const level = computed(() => {
  if (!connected.value) return info.value?.status ?? 'disconnected'
  if (!live.value || !last.value) return 'waiting'
  return worst(findings.value)
})

function duration(ms: number) {
  const m = Math.floor(ms / 60000)
  const d = Math.floor(m / 1440)
  const h = Math.floor((m % 1440) / 60)
  if (d > 0) return t('overview.duration.d', { d, h })
  if (h > 0) return t('overview.duration.h', { h, m: m % 60 })
  if (m > 0) return t('overview.duration.m', { m })
  return t('overview.duration.s')
}

function reason(f: QuickFinding) {
  if (f.id === 'run_queue') return t('overview.run_queue', { value: f.value, limit: f.limit })
  return `${t(`diag.check.${f.id}.title`)} ${t(`diag.check.${f.id}.detail`, {
    value: formatNumber(f.value), limit: formatNumber(f.limit), pct: f.pct })}`
}

const metrics = computed(() => {
  const p = last.value
  return [
    { key: 'memory', value: p ? formatBytes(p.memory.total) : '-',
      data: lineData(points.value, (x) => x.memory.total) },
    { key: 'processes', value: p ? formatNumber(p.process_count) : '-',
      data: lineData(points.value, (x) => x.process_count) },
    { key: 'run_queue', value: p ? formatNumber(p.run_queue) : '-',
      data: lineData(points.value, (x) => x.run_queue) },
  ]
})

const tone = computed(() => {
  switch (level.value) {
    case 'crit': return vars.value.errorColor
    case 'warn': return vars.value.warningColor
    case 'ok': return vars.value.successColor
    case 'disconnected': return vars.value.errorColor
    default: return vars.value.textColor3
  }
})

const tagType = computed(() => ({
  crit: 'error', warn: 'warning', ok: 'success', disconnected: 'error',
} as Record<string, 'error' | 'warning' | 'success'>)[level.value] ?? 'default')

const tagText = computed(() =>
  connected.value ? t(`overview.level.${level.value}`) : t(`overview.status.${level.value}`))
</script>

<template>
  <button type="button" class="card" :class="[level, { current: nodes.current === node }]"
          :style="{ '--tone': tone }" :title="t('overview.open')" @click="emit('open', node)">
    <div class="head">
      <span class="light" />
      <span class="name mono">{{ node }}</span>
      <NTag size="small" :type="tagType" :bordered="false" round>{{ tagText }}</NTag>
    </div>
    <div class="meta">
      <template v-if="summary">
        {{ t('overview.otp', { v: summary.otp_release }) }}
        <template v-if="connected"> · {{ t('overview.uptime', { d: duration(summary.uptime_ms) }) }}</template>
      </template>
      <template v-else>&nbsp;</template>
    </div>
    <template v-if="connected">
      <div v-for="m in metrics" :key="m.key" class="metric">
        <span class="label">{{ t(`overview.metric.${m.key}`) }}</span>
        <span class="value mono">{{ m.value }}</span>
        <Sparkline class="spark" :data="m.data" :window-ms="MAX_WINDOW_MS" :now="now" />
      </div>
      <ul v-if="findings.length" class="reasons">
        <li v-for="f in findings" :key="f.id" :class="f.level">{{ reason(f) }}</li>
      </ul>
    </template>
    <div v-else class="offline">
      <StatusDot :status="info?.status ?? 'disconnected'" />
      <span>{{ info?.error || t(`overview.status.${level}`) }}</span>
    </div>
  </button>
</template>

<style scoped>
.card {
  all: unset;
  box-sizing: border-box;
  display: flex;
  flex-direction: column;
  gap: 10px;
  padding: 14px 16px 16px;
  border-radius: 12px;
  background: v-bind('vars.cardColor');
  border: 1px solid v-bind('vars.borderColor');
  cursor: pointer;
  min-width: 0;
  transition: border-color 0.15s, box-shadow 0.15s;
}
.card:hover,
.card:focus-visible {
  border-color: var(--tone);
  box-shadow: 0 0 0 1px var(--tone);
}
.card.warn,
.card.crit,
.card.disconnected {
  border-color: var(--tone);
  background: linear-gradient(color-mix(in srgb, var(--tone) 9%, transparent), transparent 70%),
    v-bind('vars.cardColor');
}
.card.crit {
  box-shadow: 0 0 0 1px var(--tone);
}
.head {
  display: flex;
  align-items: center;
  gap: 8px;
  min-width: 0;
}
.light {
  width: 10px;
  height: 10px;
  border-radius: 50%;
  flex: none;
  background: var(--tone);
  box-shadow: 0 0 0 3px color-mix(in srgb, var(--tone) 22%, transparent);
}
.name {
  flex: 1;
  min-width: 0;
  font-weight: 600;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
.current .name::after {
  content: ' •';
  color: v-bind('vars.primaryColor');
}
.meta {
  font-size: 12px;
  opacity: 0.6;
  margin-top: -6px;
}
.metric {
  display: grid;
  grid-template-columns: 64px minmax(64px, auto) 1fr;
  align-items: center;
  gap: 10px;
}
.label {
  font-size: 13px;
  opacity: 0.65;
}
.value {
  font-variant-numeric: tabular-nums;
  font-weight: 600;
  text-align: right;
}
.spark {
  color: v-bind('vars.infoColor');
  min-width: 0;
}
.reasons {
  margin: 2px 0 0;
  padding: 8px 0 0;
  list-style: none;
  border-top: 1px dashed v-bind('vars.dividerColor');
  font-size: 12.5px;
  display: flex;
  flex-direction: column;
  gap: 4px;
}
.reasons li.crit {
  color: v-bind('vars.errorColor');
}
.reasons li.warn {
  color: v-bind('vars.warningColor');
}
.offline {
  display: flex;
  align-items: center;
  gap: 8px;
  font-size: 13px;
  opacity: 0.75;
  padding: 12px 0;
  overflow-wrap: anywhere;
}
</style>
