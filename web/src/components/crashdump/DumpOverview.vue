<script setup lang="ts">
import { computed, onBeforeUnmount, ref, watch, type Component } from 'vue'
import { useI18n } from 'vue-i18n'
import { NGrid, NGi, NCard, NIcon, NAlert, NSkeleton, NEmpty, NButton, NTooltip } from 'naive-ui'
import {
  CloseCircle, Warning, InformationCircle, ChevronForward, SkullOutline, FlashOutline, PowerOutline,
  HardwareChipOutline, HelpCircleOutline, BanOutline,
} from '@vicons/ionicons5'
import { dumpRequest, type DumpFinding, type DumpInfo, type DumpOverview, type DumpRow } from '../../api/dump'
import { errorText } from '../../api/errors'
import { formatBytes, formatNumber } from '../../api/format'
import { useChartTheme } from '../../composables/useChartTheme'
import DonutChart from '../../charts/DonutChart.vue'
import UsageBar from '../UsageBar.vue'
import StatCard from '../StatCard.vue'
import Term from '../Term.vue'
import KnowledgeIcon from '../KnowledgeIcon.vue'
import { formatParams, refLink, useNav } from './cells'

const props = defineProps<{ id: string; info: DumpInfo }>()
const emit = defineEmits<{ tab: [tab: string, sort?: string] }>()
const { t, te } = useI18n()
const nav = useNav()
const chart = useChartTheme()

const data = ref<DumpOverview | null>(null)
const error = ref<string | null>(null)
let timer: number | undefined
let alive = true
// Only the latest request may fill in: one started while scanning can
// answer after the one started when the scan finished.
let seq = 0
// A request is out: an empty list may only mean "not computed yet".
const loading = ref(false)

async function load() {
  clearTimeout(timer)
  const mine = ++seq
  loading.value = true
  try {
    const d = await dumpRequest<DumpOverview>('dump.overview', { id: props.id })
    if (!alive || mine !== seq) return
    data.value = d
    error.value = null
  } catch (e) {
    if (alive && mine === seq) error.value = errorText(e)
  }
  if (mine !== seq) return
  loading.value = false
  // While scanning, the overview fills in: ask again every 1.5 s.
  if (alive && props.info.status === 'scanning') timer = window.setTimeout(load, 1500)
}
watch(() => [props.id, props.info.status], () => { void load() }, { immediate: true })
onBeforeUnmount(() => { alive = false; clearTimeout(timer) })

const has = (key: string) => te(key) || te(key, 'zh')

// --- crash reason ------------------------------------------------------------

const REASON_STYLE: Record<string, { tone: 'critical' | 'warning' | 'info'; icon: Component }> = {
  oom: { tone: 'critical', icon: HardwareChipOutline },
  out_of_memory_heap: { tone: 'critical', icon: HardwareChipOutline },
  kernel_pid_terminated: { tone: 'critical', icon: SkullOutline },
  init_terminating: { tone: 'critical', icon: PowerOutline },
  system_limit: { tone: 'critical', icon: BanOutline },
  kernel_start_failed: { tone: 'critical', icon: PowerOutline },
  system_process_terminated: { tone: 'critical', icon: SkullOutline },
  halt: { tone: 'info', icon: FlashOutline },
  sigusr1: { tone: 'info', icon: FlashOutline },
  user_requested: { tone: 'info', icon: FlashOutline },
  unknown: { tone: 'warning', icon: HelpCircleOutline },
}

const reason = computed(() => {
  const r = data.value?.reason
  const slogan = data.value?.general?.slogan ?? ''
  if (!r) return null
  const code = has(`crashdump.reason.${r.code}.title`) ? r.code : 'unknown'
  const params: Record<string, string> = formatParams(r.params)
  if (r.params?.what) {
    const w = String(r.params.what)
    params.what = has(`crashdump.what.${w}`) ? t(`crashdump.what.${w}`) : w
  }
  if (code === 'unknown' && !params.text) params.text = slogan
  if (!params.allocator) params.allocator = '?'
  if (!params.size) params.size = t('crashdump.overview.unknown_size')
  if (!params.app) params.app = params.process ?? ''
  // A long exit reason is shown as a block of its own, not in the title.
  const detail = typeof r.params?.reason === 'string' && r.params.reason ? r.params.reason : null
  return {
    code,
    detail,
    title: t(`crashdump.reason.${code}.title`, params),
    cause: t(`crashdump.reason.${code}.cause`, params),
    check: t(`crashdump.reason.${code}.check`, params),
    ...(REASON_STYLE[code] ?? REASON_STYLE.unknown),
  }
})

// --- key facts ---------------------------------------------------------------

const facts = computed(() => {
  const g = data.value?.general ?? {}
  const sv = String(g.system_version ?? '')
  const otp = sv.match(/Erlang\/OTP\s+(\S+)/)?.[1]
  const erts = sv.match(/\[erts-([^\]]+)\]/)?.[1]
  const bits = sv.match(/\[(\d+)-bit\]/)?.[1]
  const smp = sv.match(/\[smp:([^\]]+)\]/)?.[1]
  const rows: { label: string; value: string; card?: string }[] = [
    { label: t('crashdump.facts.node'), value: String(g.node ?? '-') },
    { label: t('crashdump.facts.time'), value: String(g.time ?? '-') },
    { label: t('crashdump.facts.otp'), value: otp ? `OTP ${otp}${erts ? ` · erts ${erts}` : ''}` : sv || '-' },
  ]
  if (bits || smp) rows.push({ label: t('crashdump.facts.arch'), value: [bits ? `${bits}-bit` : '', smp ? `smp ${smp}` : ''].filter(Boolean).join(' · ') })
  if (g.calling_thread) rows.push({ label: t('crashdump.facts.thread'), value: String(g.calling_thread) })
  if (g.taints) rows.push({ label: t('crashdump.facts.taints'), value: String(g.taints), card: 'crash_dump' })
  rows.push({ label: t('crashdump.facts.file'), value: formatBytes(props.info.size) })
  return rows
})

// --- counts vs limits ----------------------------------------------------------

const LIMITED = ['processes', 'ports', 'atoms', 'ets'] as const
// The counts' own explanations and cards; their labels also name memory
// glossary entries (进程, 原子), which mean something else here.
const COUNT_TIP: Record<string, string | undefined> = { processes: 'process', ports: 'port', atoms: 'atom' }
// The BEAM Book card behind each kind of finding.
const FINDING_CARD: Record<string, string> = {
  top_memory_process: 'process_memory', long_message_queue: 'mailbox', big_ets: 'ets', binary_heavy: 'binary',
  many_processes_in_state: 'process_state', garbage_collecting: 'gc', run_queue_long: 'run_queue',
  port_queue: 'port_queue', calling_process: 'crash_dump', truncated: 'crash_dump', dump_aborted: 'crash_dump',
}
const COUNT_CARD: Record<string, string> = { processes: 'process', ports: 'ports', atoms: 'atom', ets: 'ets' }
const usage = computed(() => {
  const d = data.value
  if (!d) return []
  return LIMITED.filter((k) => typeof d.counts?.[k] === 'number' && typeof d.limits?.[k] === 'number' && d.limits[k]! > 0)
    .map((k) => ({ key: k, used: d.counts[k] as number, limit: d.limits[k] as number }))
})
const plainCounts = computed(() => {
  const d = data.value
  if (!d) return []
  const shown = new Set(usage.value.map((u) => u.key as string))
  return (['processes', 'ports', 'ets', 'atoms', 'timers', 'modules', 'funs', 'nodes'] as const)
    .filter((k) => !shown.has(k))
    .map((k) => ({ key: k, value: d.counts?.[k] }))
})
const COUNT_TAB: Record<string, string> = {
  processes: 'processes', ports: 'ports', ets: 'ets', atoms: 'atoms', timers: 'timers', modules: 'modules', funs: 'funs', nodes: 'nodes',
}

// --- findings ----------------------------------------------------------------

const LEVEL_ICON: Record<string, Component> = { critical: CloseCircle, warning: Warning, info: InformationCircle }
const LEVEL_ORDER: Record<string, number> = { critical: 0, warning: 1, info: 2 }

function findingText(f: DumpFinding): string {
  const p = formatParams(f.params)
  const raw = f.params ?? {}
  p.who = raw.name ? `${raw.name} (${raw.pid ?? raw.port ?? ''})` : String(raw.pid ?? raw.port ?? '')
  if (raw.what) p.what = has(`crashdump.what.${raw.what}`) ? t(`crashdump.what.${raw.what}`) : String(raw.what)
  if (typeof raw.used === 'number' && typeof raw.limit === 'number' && raw.limit > 0) p.pct = `${((raw.used / raw.limit) * 100).toFixed(0)}%`
  if (raw.state && has(`crashdump.state.${raw.state}`)) p.state = t(`crashdump.state.${raw.state}`)
  if (has(`crashdump.finding.${f.code}`)) return t(`crashdump.finding.${f.code}`, p)
  return `${f.code} ${Object.entries(p).map(([k, v]) => `${k}=${v}`).join(' ')}`
}

const findings = computed(() => [...(data.value?.findings ?? [])]
  .sort((a, b) => (LEVEL_ORDER[a.level] ?? 3) - (LEVEL_ORDER[b.level] ?? 3))
  .map((f, i) => ({ key: i, f, text: findingText(f) })))

function openFinding(f: DumpFinding) {
  const tg = f.target
  if (!tg) return
  if (tg.kind === 'memory' || tg.kind === 'allocators') emit('tab', 'memory')
  else nav.open(tg)
}

// --- memory ------------------------------------------------------------------

const memItems = computed(() => {
  const m = data.value?.memory
  if (!m || !m.total) return []
  const sys = m.system ?? 0
  const parts = [
    { key: 'processes', value: m.processes ?? 0 },
    { key: 'binary', value: m.binary ?? 0 },
    { key: 'ets', value: m.ets ?? 0 },
    { key: 'code', value: m.code ?? 0 },
    { key: 'atom', value: m.atom ?? 0 },
  ]
  const other = Math.max(0, sys - (m.binary ?? 0) - (m.ets ?? 0) - (m.code ?? 0) - (m.atom ?? 0))
  parts.push({ key: 'other', value: other })
  return parts.filter((p) => p.value > 0).map((p) => ({ ...p, name: t(`crashdump.mem.${p.key}`) }))
})
const memTotal = computed(() => data.value?.memory?.total ?? 0)

// --- top processes -----------------------------------------------------------

const procName = (r: DumpRow) => String(r.name || r.registered_name || r.init || r.initial_call || r.current || r.current_function || '')
const mqlOf = (r: DumpRow) => Number(r.mq ?? r.message_queue_len ?? r.msg_q_len ?? 0)
const tops = computed(() => {
  const top = data.value?.top
  if (!top) return []
  const mem = (top.memory ?? []).map((r) => ({ r, v: Number(r.memory ?? 0) }))
  const mql = (top.mql ?? []).map((r) => ({ r, v: mqlOf(r) })).filter((x) => x.v > 0)
  return [
    { key: 'memory', title: t('crashdump.overview.top_memory'), sort: 'memory', fmt: formatBytes, items: mem, max: Math.max(1, ...mem.map((x) => x.v)) },
    { key: 'mql', title: t('crashdump.overview.top_mql'), sort: 'mq', fmt: formatNumber, items: mql, max: Math.max(1, ...mql.map((x) => x.v)) },
  ]
})

const scanning = computed(() => props.info.status === 'scanning')
</script>

<template>
  <NAlert v-if="error && !data" type="error">{{ error }}</NAlert>
  <div v-else class="overview">
    <!-- 1. Why it crashed -->
    <NGrid :cols="3" :x-gap="16" :y-gap="16" responsive="screen" item-responsive>
      <NGi span="3 l:2">
        <NCard size="small" class="reason" :class="reason?.tone ?? 'pending'">
          <template v-if="reason">
            <div class="reason-head">
              <div class="reason-icon"><NIcon :component="reason.icon" :size="26" /></div>
              <div class="reason-main">
                <div class="reason-kicker">{{ t('crashdump.overview.reason') }}</div>
                <div class="reason-title">{{ reason.title }}</div>
              </div>
            </div>
            <div v-if="reason.detail" class="reason-detail">
              <span class="reason-detail-label">{{ t('crashdump.overview.exit_reason') }}</span>
              <pre class="mono">{{ reason.detail }}</pre>
            </div>
            <dl class="reason-notes">
              <dt>{{ t('crashdump.overview.cause') }}</dt><dd>{{ reason.cause }}</dd>
              <dt>{{ t('crashdump.overview.check') }}</dt><dd>{{ reason.check }}</dd>
            </dl>
            <div class="slogan">
              <span class="slogan-label"><Term label="Slogan" card="crash_dump" /></span>
              <code class="mono">{{ data?.general?.slogan }}</code>
            </div>
          </template>
          <template v-else>
            <div class="reason-kicker">{{ t('crashdump.overview.reason') }}</div>
            <NSkeleton text :repeat="3" style="margin-top: 10px" />
          </template>
        </NCard>
      </NGi>
      <NGi span="3 l:1">
        <StatCard :title="t('crashdump.overview.facts')" :rows="data ? facts : []" class="facts" />
      </NGi>

      <!-- 2. What looks suspicious -->
      <NGi span="3 l:2">
        <NCard size="small" :title="t('crashdump.overview.findings')" class="findings">
          <template #header-extra>
            <span v-if="scanning" class="muted small">{{ t('crashdump.overview.findings_partial') }}</span>
          </template>
          <div v-if="findings.length" class="finding-list">
            <component :is="x.f.target ? 'button' : 'div'" v-for="x in findings" :key="x.key" type="button"
                       class="finding" :class="[x.f.level, { clickable: !!x.f.target }]" @click="openFinding(x.f)">
              <NIcon :component="LEVEL_ICON[x.f.level] ?? InformationCircle" :size="18" class="finding-icon" />
              <span class="finding-text">{{ x.text }}</span>
              <KnowledgeIcon v-if="FINDING_CARD[x.f.code]" :card="FINDING_CARD[x.f.code]" />
              <NIcon v-if="x.f.target" :component="ChevronForward" class="finding-go" />
            </component>
          </div>
          <NEmpty v-else-if="data && !scanning && !loading" :description="t('crashdump.overview.no_findings')" size="small" />
          <NSkeleton v-else text :repeat="4" />
        </NCard>
      </NGi>
      <NGi span="3 l:1">
        <NCard size="small" :title="t('crashdump.overview.counts')">
          <template v-if="data">
            <template v-for="u in usage" :key="u.key">
              <UsageBar :label="t(`crashdump.counts.${u.key}`)" :used="u.used" :limit="u.limit"
                        :tip="COUNT_TIP[u.key] ? t(`pages.system.tips.${COUNT_TIP[u.key]}`) : undefined" :card="COUNT_CARD[u.key]" />
            </template>
            <div class="count-grid" :class="{ spaced: usage.length }">
              <button v-for="c in plainCounts" :key="c.key" type="button" class="count" @click="emit('tab', COUNT_TAB[c.key])">
                <span class="count-label">{{ t(`crashdump.counts.${c.key}`) }}</span>
                <span class="count-value mono">{{ typeof c.value === 'number' ? formatNumber(c.value) : '-' }}</span>
              </button>
            </div>
          </template>
          <NSkeleton v-else text :repeat="5" />
        </NCard>
      </NGi>

      <!-- 3. Where the memory went -->
      <NGi span="3 l:1">
        <NCard size="small" :title="t('crashdump.overview.memory')">
          <template #header-extra>
            <NButton text size="small" @click="emit('tab', 'memory')">{{ t('crashdump.overview.details') }}</NButton>
          </template>
          <template v-if="memItems.length">
            <DonutChart :items="memItems" :format="formatBytes" :center="formatBytes(memTotal)"
                        :center-label="t('crashdump.overview.mem_total')" :height="220" />
            <table class="mem-legend">
              <tr v-for="(m, i) in memItems" :key="m.key">
                <td><span class="swatch" :style="{ background: chart.series[i % chart.series.length] }" />{{ m.name }}</td>
                <td class="mono num">{{ formatBytes(m.value) }}</td>
                <td class="mono num muted">{{ memTotal ? ((m.value / memTotal) * 100).toFixed(1) : '0' }}%</td>
              </tr>
            </table>
          </template>
          <NEmpty v-else-if="data && !scanning && !loading" :description="t('crashdump.overview.no_memory')" size="small" />
          <NSkeleton v-else height="220px" />
        </NCard>
      </NGi>
      <NGi v-for="tp in tops" :key="tp.key" span="3 m:3 l:1">
        <NCard size="small" :title="tp.title">
          <template #header-extra>
            <NButton text size="small" @click="emit('tab', 'processes', tp.sort)">{{ t('crashdump.overview.all') }}</NButton>
          </template>
          <div v-if="tp.items.length" class="top-list">
            <button v-for="x in tp.items" :key="String(x.r.pid)" type="button" class="top-row"
                    @click="nav.open({ kind: 'process', key: String(x.r.pid) })">
              <div class="top-line">
                <component :is="() => refLink(String(x.r.pid), nav)" />
                <NTooltip :disabled="!procName(x.r)">
                  <template #trigger><span class="top-name">{{ procName(x.r) }}</span></template>
                  {{ procName(x.r) }}
                </NTooltip>
                <span class="top-value mono">{{ tp.fmt(x.v) }}</span>
              </div>
              <div class="top-bar"><div :style="{ width: `${Math.max(2, (x.v / tp.max) * 100)}%` }" /></div>
            </button>
          </div>
          <NEmpty v-else-if="data && !scanning && !loading" :description="t('crashdump.overview.none')" size="small" />
          <NSkeleton v-else text :repeat="5" />
        </NCard>
      </NGi>
    </NGrid>
  </div>
</template>

<style scoped>
.muted { opacity: 0.55; }
.small { font-size: 12px; }

.reason {
  height: 100%;
  border-left: 4px solid var(--tone);
  --tone: #8a8f98;
}
.reason.critical { --tone: #d03050; }
.reason.warning { --tone: #f0a020; }
.reason.info { --tone: #2080f0; }
.reason-head {
  display: flex;
  gap: 14px;
  align-items: flex-start;
}
.reason-icon {
  flex: none;
  width: 44px;
  height: 44px;
  border-radius: 10px;
  display: flex;
  align-items: center;
  justify-content: center;
  color: var(--tone);
  background: color-mix(in srgb, var(--tone) 14%, transparent);
}
.reason-kicker {
  font-size: 12px;
  opacity: 0.6;
  letter-spacing: 0.3px;
}
.reason-title {
  font-size: 22px;
  font-weight: 650;
  line-height: 1.3;
  margin-top: 2px;
  overflow-wrap: anywhere;
}
.reason-detail {
  margin-top: 12px;
  font-size: 12px;
}
.reason-detail-label {
  opacity: 0.55;
}
.reason-detail pre {
  margin: 4px 0 0;
  padding: 8px 10px;
  border-radius: 6px;
  background: rgba(128, 128, 128, 0.08);
  white-space: pre-wrap;
  word-break: break-all;
  max-height: 160px;
  overflow: auto;
}
.reason-notes {
  display: grid;
  grid-template-columns: auto 1fr;
  gap: 6px 12px;
  margin: 16px 0 0;
  font-size: 13px;
  line-height: 1.6;
}
.reason-notes dt {
  opacity: 0.55;
  white-space: nowrap;
}
.reason-notes dd {
  margin: 0;
}
.slogan {
  margin-top: 14px;
  padding-top: 10px;
  border-top: 1px dashed rgba(128, 128, 128, 0.25);
  display: flex;
  gap: 10px;
  align-items: baseline;
  font-size: 12px;
}
.slogan-label {
  opacity: 0.5;
  flex: none;
}
.slogan code {
  opacity: 0.75;
  overflow-wrap: anywhere;
}
.facts {
  height: 100%;
}
.facts :deep(dd) {
  overflow-wrap: anywhere;
}

.finding-list {
  display: flex;
  flex-direction: column;
  gap: 4px;
}
.finding {
  display: flex;
  align-items: center;
  gap: 10px;
  padding: 8px 10px;
  border-radius: 8px;
  border: none;
  background: transparent;
  color: inherit;
  font: inherit;
  text-align: left;
  width: 100%;
}
.finding.clickable {
  cursor: pointer;
}
.finding.clickable:hover {
  background: rgba(128, 128, 128, 0.1);
}
.finding-icon { flex: none; }
.finding.critical .finding-icon { color: #d03050; }
.finding.warning .finding-icon { color: #f0a020; }
.finding.info .finding-icon { color: #2080f0; }
.finding.critical { background: rgba(208, 48, 80, 0.07); }
.finding.critical.clickable:hover { background: rgba(208, 48, 80, 0.13); }
.finding-text {
  flex: 1;
  min-width: 0;
  line-height: 1.5;
  overflow-wrap: anywhere;
}
.finding-go {
  flex: none;
  opacity: 0.4;
}

.count-grid {
  display: grid;
  grid-template-columns: 1fr 1fr;
  gap: 6px;
}
.count-grid.spaced {
  margin-top: 16px;
}
.count {
  display: flex;
  justify-content: space-between;
  gap: 8px;
  padding: 6px 8px;
  border-radius: 6px;
  border: none;
  background: rgba(128, 128, 128, 0.07);
  color: inherit;
  font: inherit;
  font-size: 13px;
  cursor: pointer;
}
.count:hover {
  background: rgba(128, 128, 128, 0.14);
}
.count-label { opacity: 0.65; }
.count-value { font-variant-numeric: tabular-nums; }

.mem-legend {
  width: 100%;
  border-collapse: collapse;
  font-size: 13px;
  margin-top: 4px;
}
.mem-legend td {
  padding: 3px 4px;
}
.mem-legend .num {
  text-align: right;
  font-variant-numeric: tabular-nums;
}
.swatch {
  display: inline-block;
  width: 9px;
  height: 9px;
  border-radius: 2px;
  margin-right: 8px;
}

.top-list {
  display: flex;
  flex-direction: column;
  gap: 2px;
}
.top-row {
  display: block;
  width: 100%;
  border: none;
  background: transparent;
  color: inherit;
  font: inherit;
  text-align: left;
  padding: 6px 6px;
  border-radius: 6px;
  cursor: pointer;
}
.top-row:hover {
  background: rgba(128, 128, 128, 0.1);
}
.top-line {
  display: flex;
  align-items: baseline;
  gap: 10px;
  font-size: 13px;
}
.top-name {
  flex: 1;
  min-width: 0;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
  opacity: 0.7;
}
.top-value {
  flex: none;
  font-variant-numeric: tabular-nums;
  font-weight: 600;
}
.top-bar {
  height: 4px;
  border-radius: 2px;
  background: rgba(128, 128, 128, 0.12);
  margin-top: 5px;
  overflow: hidden;
}
.top-bar > div {
  height: 100%;
  border-radius: 2px;
  background: var(--n-color, #2a78d6);
  background: #2a78d6;
}
</style>
