<script setup lang="ts">
import { computed, h, nextTick, onBeforeUnmount, ref, watch } from 'vue'
import { useI18n } from 'vue-i18n'
import { useRoute, useRouter } from 'vue-router'
import {
  NCard, NSelect, NInputNumber, NButton, NSpace, NTag, NAlert, NDataTable, NInput, NIcon,
  NRadioGroup, NRadioButton, NCheckbox, NCheckboxGroup, NModal, NSwitch, NText, NTooltip,
  NEmpty, NTabs, NTabPane, useMessage, type DataTableColumns,
} from 'naive-ui'
import {
  SearchOutline, PlayOutline, StopOutline, TrashOutline, DownloadOutline,
  ArrowBackOutline, ArrowForwardOutline, SaveOutline, FolderOpenOutline, CloseOutline,
} from '@vicons/ionicons5'
import { client } from '../api/ws'
import { errorText } from '../api/errors'
import { formatNumber } from '../api/format'
import type { ProcessPage, TraceCategory, TraceEvent } from '../api/types'
import {
  categoryLabel, kindLabel, kindTip, kindCard, refusedReason, stopReason,
  eventLine, formatLatency, formatTime, peerText,
} from '../api/trace'
import { useTrace } from '../stores/trace'
import { useSettings } from '../stores/settings'
import { useNodes } from '../stores/nodes'
import PageHeader from '../components/PageHeader.vue'
import NodeGuard from '../components/NodeGuard.vue'
import CallStats from '../components/trace/CallStats.vue'
import SequenceView from '../components/trace/SequenceView.vue'
import { useQueryRef } from '../composables/useQueryRef'
import KnowledgeLink from '../components/KnowledgeLink.vue'
import KnowledgeIcon from '../components/KnowledgeIcon.vue'

const trace = useTrace()
const settings = useSettings()
const nodes = useNodes()
const message = useMessage()
const route = useRoute()
const router = useRouter()
const { t } = useI18n()

// --- tabs, saving and opening a trace ----------------------------------------

const tabRef = useQueryRef('tab')
const tab = computed({
  get: () => (tabRef.value === 'stats' || tabRef.value === 'sequence' ? tabRef.value : 'list'),
  set: (v: string) => { tabRef.value = v === 'list' ? null : v },
})

const saving = ref(false)
async function save() {
  saving.value = true
  try {
    const n = await trace.save()
    message.success(t('trace.file.saved', { n }))
  } catch (e) {
    message.error(errorText(e))
  } finally {
    saving.value = false
  }
}

const fileInput = ref<HTMLInputElement | null>(null)
async function onFile(ev: Event) {
  const input = ev.target as HTMLInputElement
  const file = input.files?.[0]
  input.value = ''
  if (!file) return
  try {
    const n = await trace.open(file)
    message.success(t('trace.file.opened', { n }))
  } catch (e) {
    message.error(e instanceof Error && e.message === 'bad_file' ? t('trace.file.bad_file') : errorText(e))
  }
}

const replay = computed(() => trace.replay)
const savedAt = computed(() => (replay.value ? new Date(replay.value.data.saved_at).toLocaleString() : ''))
// A saved trace is shown even without a connected node.
const Guard = computed(() => (replay.value ? 'div' : NodeGuard))

// --- starting a trace -------------------------------------------------

const targets = ref<string[]>([])
const maxEvents = ref(10000)
const maxSeconds = ref(60)
const starting = ref(false)
const refused = ref<{ target: string; reason: string }[]>([])
const nameOptions = ref<{ label: string; value: string }[]>([])

// Registered names to pick from: one page of the process list, by name.
function loadNames() {
  const n = trace.node
  if (!n) return
  const unsub = client.subscribe('node.processes',
    { node: n, sort: 'name', order: 'asc', offset: 0, limit: 500 }, 60000,
    (d: ProcessPage) => {
      unsub()
      nameOptions.value = d.rows.filter((r) => r.name)
        .map((r) => ({ label: `${r.name}  ${r.pid}`, value: r.name! }))
    })
}
watch(() => trace.node, loadNames, { immediate: true })

const running = computed(() => trace.state.status === 'running')

async function start() {
  if (!targets.value.length) return
  starting.value = true
  refused.value = []
  try {
    const r = await trace.start(targets.value, maxEvents.value, maxSeconds.value)
    refused.value = r.refused
    if (r.processes.length) message.success(t('procs.trace.started', { n: r.processes.length }, r.processes.length))
  } catch (e) {
    message.error(t('procs.trace.start_failed', { err: errorText(e) }))
  } finally {
    starting.value = false
  }
}

async function stop() {
  try {
    await trace.stop()
  } catch (e) {
    message.error(errorText(e))
  }
}

// "Trace messages" from the process list or the process drawer: ?target=<pid>.
watch(() => [route.query.target, trace.node] as const, ([target, n]) => {
  if (typeof target !== 'string' || !target || !n || settings.readOnly) return
  trace.closeReplay()
  targets.value = [target]
  const query = { ...route.query }
  delete query.target
  void router.replace({ query })
  void start()
}, { immediate: true })

// --- the event list -----------------------------------------------------

const dir = ref<'all' | 'in' | 'out'>('all')
const cats = ref<TraceCategory[]>(['business'])
const search = ref('')
const follow = ref(true)
const selected = ref<TraceEvent | null>(null)

const procNames = computed(() => new Map(trace.processes.map((p) => [p.pid, p.name ?? p.pid])))
const processName = (pid: string) => procNames.value.get(pid) ?? pid
const multi = computed(() => trace.processes.length > 1)

const counts = computed(() => {
  const c = { business: 0, system: 0, network: 0 } as Record<string, number>
  for (const e of trace.events) c[e.cat] = (c[e.cat] ?? 0) + 1
  return c
})

const filtered = computed(() => {
  const q = search.value.trim().toLowerCase()
  const cs = new Set(cats.value)
  return trace.events.filter((e) =>
    cs.has(e.cat)
    && (dir.value === 'all' || e.dir === dir.value)
    && (!q || e.text.toLowerCase().includes(q) || peerText(e).toLowerCase().includes(q)
        || kindLabel(e.kind).toLowerCase().includes(q)))
})

function latencyOf(e: TraceEvent): number | null {
  const p = trace.pair(e.ref)
  return p?.call && p.reply ? p.reply.t - p.call.t : null
}

const columns = computed<DataTableColumns<TraceEvent>>(() => [
  {
    key: 't', title: t('procs.trace.col.time'), width: 124,
    render: (e) => h('span', { class: 'mono muted nowrap' }, formatTime(e.t)),
  },
  ...(multi.value ? [{
    key: 'pid', title: t('procs.trace.col.process'), width: 160, ellipsis: { tooltip: true },
    render: (e: TraceEvent) => h('span', { class: 'mono' }, processName(e.pid)),
  }] : []),
  {
    key: 'dir', title: '', width: 44, align: 'center',
    render: (e) => h(NIcon, {
      component: e.dir === 'in' ? ArrowBackOutline : ArrowForwardOutline,
      class: e.dir === 'in' ? 'dir-in' : 'dir-out', size: 16,
      title: t(e.dir === 'in' ? 'procs.trace.received' : 'procs.trace.sent'),
    }),
  },
  {
    key: 'kind', title: t('procs.trace.col.kind'), width: 110,
    render: (e) => h(NTag, {
      size: 'small', bordered: false,
      type: e.cat === 'business' ? (e.kind === 'call' || e.kind === 'reply' ? 'info' : 'success')
        : e.cat === 'network' ? 'warning' : 'default',
    }, { default: () => h(KnowledgeLink, { text: kindLabel(e.kind), card: kindCard(e.kind) }) }),
  },
  {
    key: 'peer', title: t('procs.trace.col.peer'), width: 220, ellipsis: { tooltip: true },
    render: (e) => {
      if (e.kind === 'reply' && !e.peer) {
        const call = trace.pair(e.ref)?.call
        return h('span', { class: 'mono muted' }, call ? `↩ ${peerText(call)}` : t('procs.trace.caller'))
      }
      return h('span', { class: ['mono', e.dead ? 'dead' : ''] },
        e.dead ? t('procs.trace.dead_peer', { peer: peerText(e) }) : peerText(e))
    },
  },
  {
    key: 'summary', title: t('procs.trace.col.content'), minWidth: 300, ellipsis: { tooltip: false },
    render: (e) => h('span', { class: ['mono', e.cat !== 'business' ? 'muted' : ''] }, e.summary),
  },
  {
    key: 'lat', title: t('procs.trace.col.latency'), width: 96, align: 'right',
    render: (e) => {
      if (e.kind !== 'call' && e.kind !== 'reply') return ''
      const l = latencyOf(e)
      return h('span', { class: 'mono muted' }, l === null ? (e.kind === 'call' ? '…' : '') : formatLatency(l))
    },
  },
])

const rowProps = (e: TraceEvent) => ({
  style: 'cursor: pointer',
  onClick: () => { selected.value = e },
})

const table = ref<InstanceType<typeof NDataTable> | null>(null)
watch(() => filtered.value.length, async () => {
  if (!follow.value) return
  await nextTick()
  table.value?.scrollTo({ top: Number.MAX_SAFE_INTEGER })
})

const statusText = computed(() => {
  const s = trace.state
  if (s.status === 'running') return t('procs.trace.running', { n: formatNumber(s.count ?? 0) })
  if (s.status === 'stopped') return stopReason(s.reason ?? 'stopped')
  return ''
})

function exportText() {
  const lines = filtered.value.map((e) => eventLine(e, processName))
  const blob = new Blob([lines.join('\n') + '\n'], { type: 'text/plain;charset=utf-8' })
  const a = document.createElement('a')
  a.href = URL.createObjectURL(blob)
  a.download = `trace-${trace.node ?? 'node'}-${new Date().toISOString().replace(/[:.]/g, '-')}.txt`
  a.click()
  setTimeout(() => URL.revokeObjectURL(a.href), 1000)
}

// The modal keeps showing the last event while it fades out.
const shown = ref<TraceEvent | null>(null)
watch(selected, (e) => { if (e) shown.value = e })
const selectedPair = computed(() => trace.pair(shown.value?.ref ?? null))
const showDetail = computed({
  get: () => selected.value !== null,
  set: (v) => { if (!v) selected.value = null },
})

onBeforeUnmount(() => { selected.value = null })
</script>

<template>
  <PageHeader :title="t('procs.trace.title')" :subtitle="(replay ? replay.data.node : nodes.current) ?? undefined">
    <NSpace align="center" :size="8">
      <NTag v-if="statusText && !replay" :type="running ? 'success' : trace.state.reason === 'stopped_by_user' || trace.state.reason === 'max_events' || trace.state.reason === 'max_seconds' ? 'default' : 'warning'"
            :bordered="false" round>
        {{ statusText }}
      </NTag>
      <NButton v-if="running && !replay" secondary type="error" @click="stop">
        <template #icon><NIcon :component="StopOutline" /></template>
        {{ t('common.stop') }}
      </NButton>
      <NTooltip v-if="!replay && (trace.state.status !== 'none' || trace.events.length)">
        <template #trigger>
          <NButton secondary :loading="saving" @click="save">
            <template #icon><NIcon :component="SaveOutline" /></template>
            {{ t('trace.file.save') }}
          </NButton>
        </template>
        {{ t('trace.file.save_tip') }}
      </NTooltip>
      <NTooltip>
        <template #trigger>
          <NButton secondary @click="fileInput?.click()">
            <template #icon><NIcon :component="FolderOpenOutline" /></template>
            {{ t('trace.file.open') }}
          </NButton>
        </template>
        {{ t('trace.file.open_tip') }}
      </NTooltip>
      <input ref="fileInput" type="file" accept=".json,application/json" hidden @change="onFile" />
    </NSpace>
  </PageHeader>
  <NAlert v-if="replay" type="info" :bordered="false" class="replay">
    <template #header>{{ t('trace.file.viewing', { file: replay.file }) }}</template>
    <div class="replay-row">
      <span>{{ t('trace.file.viewing_detail', { node: replay.data.node ?? '-', time: savedAt, n: formatNumber(replay.data.events.length) }) }}</span>
      <NButton size="small" @click="trace.closeReplay()">
        <template #icon><NIcon :component="CloseOutline" /></template>
        {{ t('trace.file.close') }}
      </NButton>
    </div>
  </NAlert>
  <component :is="Guard">
    <NCard v-if="!running && !replay" size="small" class="setup" :title="t('procs.trace.setup_title')">
      <NAlert v-if="settings.readOnly" type="info" :bordered="false">
        {{ t('procs.trace.read_only') }}
      </NAlert>
      <template v-else>
        <div class="setup-row">
          <NSelect v-model:value="targets" multiple filterable tag :options="nameOptions"
                   :max-tag-count="6" :placeholder="t('procs.trace.targets_placeholder', { example: '<0.123.0>' })"
                   class="targets" />
          <i18n-t keypath="procs.trace.max_events" tag="label" class="lim" scope="global">
            <template #n>
              <NInputNumber v-model:value="maxEvents" :min="1" :max="100000" :step="1000" size="small"
                            style="width: 120px" />
            </template>
          </i18n-t>
          <i18n-t keypath="procs.trace.max_seconds" tag="label" class="lim" scope="global">
            <template #n>
              <NInputNumber v-model:value="maxSeconds" :min="1" :max="600" :step="30" size="small"
                            style="width: 100px" />
            </template>
          </i18n-t>
          <NButton type="primary" :loading="starting" :disabled="!targets.length" @click="start">
            <template #icon><NIcon :component="PlayOutline" /></template>
            {{ t('procs.trace.start') }}
          </NButton>
        </div>
        <NText depth="3" class="hint">
          {{ t('procs.trace.hint') }}
        </NText>
      </template>
      <NAlert v-for="r in refused" :key="r.target" type="warning" :bordered="false" style="margin-top: 8px">
        <i18n-t keypath="procs.colon" scope="global">
          <template #label><span class="mono">{{ r.target }}</span></template>
        </i18n-t>{{ refusedReason(r.reason) }}
      </NAlert>
    </NCard>

    <NAlert v-if="trace.error && !replay" type="error" style="margin-bottom: 12px">{{ trace.error }}</NAlert>

    <template v-if="replay || trace.state.status !== 'none' || trace.events.length">
      <div v-if="trace.processes.length" class="procs">
        <NTag v-for="p in trace.processes" :key="p.pid" size="small" :bordered="false" class="mono">
          {{ p.name ?? p.pid }}<template v-if="p.name"> {{ p.pid }}</template>
        </NTag>
      </div>
      <NTabs v-model:value="tab" type="line" size="small" animated>
        <NTabPane name="list" :tab="t('trace.tabs.list')" display-directive="show">
          <div class="bar">
            <NSpace align="center" :size="12">
              <NRadioGroup v-model:value="dir" size="small">
                <NRadioButton value="all">{{ t('procs.trace.all') }}</NRadioButton>
                <NRadioButton value="in">{{ t('procs.trace.in') }}</NRadioButton>
                <NRadioButton value="out">{{ t('procs.trace.out') }}</NRadioButton>
              </NRadioGroup>
              <NCheckboxGroup v-model:value="cats">
                <NSpace :size="12">
                  <NCheckbox v-for="c in (['business', 'system', 'network'] as const)" :key="c" :value="c">
                    {{ t('procs.paren', { text: categoryLabel(c), detail: formatNumber(counts[c] ?? 0) }) }}
                  </NCheckbox>
                </NSpace>
              </NCheckboxGroup>
            </NSpace>
            <NSpace align="center" :size="8">
              <NInput v-model:value="search" size="small" clearable :placeholder="t('procs.trace.search')" style="width: 220px">
                <template #prefix><NIcon :component="SearchOutline" /></template>
              </NInput>
              <label class="follow"><NSwitch v-model:value="follow" size="small" /> {{ t('logs.live.follow') }}</label>
              <NTooltip>
                <template #trigger>
                  <NButton size="small" quaternary circle :disabled="!filtered.length" @click="exportText">
                    <template #icon><NIcon :component="DownloadOutline" /></template>
                  </NButton>
                </template>
                {{ t('logs.live.export') }}
              </NTooltip>
              <NTooltip v-if="!replay">
                <template #trigger>
                  <NButton size="small" quaternary circle @click="trace.clear()">
                    <template #icon><NIcon :component="TrashOutline" /></template>
                  </NButton>
                </template>
                {{ t('procs.trace.clear') }}
              </NTooltip>
            </NSpace>
          </div>
          <NDataTable ref="table" :columns="columns" :data="filtered" :row-key="(e: TraceEvent) => e.seq"
                      :row-props="rowProps" size="small" virtual-scroll :max-height="'calc(100vh - 420px)'"
                      :min-height="240" :scroll-x="900">
            <template #empty>
              <NEmpty :description="t(trace.events.length ? 'procs.trace.empty_filtered' : running ? 'procs.trace.waiting' : 'procs.trace.empty')" />
            </template>
          </NDataTable>
          <p v-if="(trace.state.dropped ?? 0) > 0" class="note">
            {{ t('procs.trace.dropped', { n: formatNumber(trace.state.dropped ?? 0) }) }}
          </p>
          <p class="note">{{ t('procs.trace.note') }}</p>
        </NTabPane>
        <NTabPane name="stats" :tab="t('trace.tabs.stats')" display-directive="if">
          <NAlert v-if="replay && !replay.data.stats" type="warning" :bordered="false" style="margin-bottom: 10px">
            {{ t('trace.file.no_stats') }}
          </NAlert>
          <CallStats :node="replay ? null : trace.node" :saved="replay?.data.stats ?? null"
                     :processes="trace.processes" />
        </NTabPane>
        <NTabPane name="sequence" :tab="t('trace.tabs.sequence')" display-directive="if">
          <SequenceView :events="trace.events" :processes="trace.processes" :pair="trace.pair"
                        @select="selected = $event" />
        </NTabPane>
      </NTabs>
    </template>

    <NModal v-model:show="showDetail">
      <NCard v-if="shown" closable style="width: min(900px, 94vw)" @close="selected = null">
        <template #header>
          <NSpace align="center" :size="8">
            <NTag size="small" :bordered="false">{{ categoryLabel(shown.cat) }} · {{ kindLabel(shown.kind) }}</NTag>
            <span class="mono">{{ processName(shown.pid) }}</span>
            <span>{{ t(shown.dir === 'in' ? 'procs.trace.received' : 'procs.trace.sent') }}</span>
            <NText depth="3" class="mono">{{ formatTime(shown.t) }}</NText>
          </NSpace>
        </template>
        <p v-if="kindTip(shown.kind)" class="tip">
          {{ kindTip(shown.kind) }}
          <KnowledgeIcon v-if="kindCard(shown.kind)" :card="kindCard(shown.kind)!" />
        </p>
        <p v-if="peerText(shown)" class="peer">
          {{ t(shown.dir === 'in' ? 'procs.trace.from' : 'procs.trace.to') }} <span class="mono">{{ peerText(shown) }}</span>
          <template v-if="shown.dead">{{ t('procs.trace.peer_gone') }}</template>
        </p>
        <template v-if="selectedPair && (shown.kind === 'call' || shown.kind === 'reply')">
          <div class="pair-title">{{ t('procs.trace.call') }}</div>
          <pre class="term">{{ selectedPair.call?.text ?? t('procs.trace.call_missing') }}</pre>
          <div class="pair-title">
            {{ t('procs.trace.reply') }}
            <NText v-if="latencyOf(shown) !== null" depth="3">{{ t('procs.trace.latency', { t: formatLatency(latencyOf(shown)!) }) }}</NText>
          </div>
          <pre class="term">{{ selectedPair.reply?.text ?? t('procs.trace.no_reply') }}</pre>
        </template>
        <pre v-else class="term">{{ shown.text }}</pre>
      </NCard>
    </NModal>
  </component>
</template>

<style scoped>
.setup {
  margin-bottom: 16px;
}
.setup-row {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  gap: 12px;
}
.targets {
  flex: 1 1 360px;
  min-width: 260px;
}
.lim, .follow {
  display: inline-flex;
  align-items: center;
  gap: 6px;
  font-size: 13px;
  white-space: nowrap;
}
.hint {
  display: block;
  margin-top: 10px;
  font-size: 12px;
}
.bar {
  display: flex;
  flex-wrap: wrap;
  justify-content: space-between;
  align-items: center;
  gap: 8px 16px;
  margin-bottom: 10px;
}
.procs {
  display: flex;
  gap: 6px;
  flex-wrap: wrap;
  margin-bottom: 4px;
}
.replay {
  margin-bottom: 16px;
}
.replay-row {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  justify-content: space-between;
  gap: 8px 16px;
}
.note {
  font-size: 12px;
  opacity: 0.6;
  margin: 8px 0 0;
}
:deep(.muted) {
  opacity: 0.6;
}
:deep(.nowrap) {
  white-space: nowrap;
}
:deep(.dead) {
  text-decoration: line-through;
  opacity: 0.6;
}
:deep(.dir-in) {
  color: #18a058;
}
:deep(.dir-out) {
  color: #2080f0;
}
.tip {
  margin: 0 0 8px;
  font-size: 13px;
  opacity: 0.7;
}
.peer {
  margin: 0 0 8px;
}
.pair-title {
  margin: 12px 0 6px;
  font-weight: 600;
}
.term {
  margin: 0;
  padding: 10px 12px;
  border-radius: 6px;
  background: rgba(128, 128, 128, 0.1);
  font-family: var(--mono, ui-monospace, SFMono-Regular, Menlo, monospace);
  font-size: 12.5px;
  white-space: pre-wrap;
  word-break: break-all;
  max-height: 50vh;
  overflow: auto;
}
</style>
