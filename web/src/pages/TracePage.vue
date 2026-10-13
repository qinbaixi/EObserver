<script setup lang="ts">
import { computed, h, nextTick, onBeforeUnmount, ref, watch } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import {
  NCard, NSelect, NInputNumber, NButton, NSpace, NTag, NAlert, NDataTable, NInput, NIcon,
  NRadioGroup, NRadioButton, NCheckbox, NCheckboxGroup, NModal, NSwitch, NText, NTooltip,
  NEmpty, useMessage, type DataTableColumns,
} from 'naive-ui'
import {
  SearchOutline, PlayOutline, StopOutline, TrashOutline, DownloadOutline,
  ArrowBackOutline, ArrowForwardOutline,
} from '@vicons/ionicons5'
import { client } from '../api/ws'
import { errorText } from '../api/errors'
import { formatNumber } from '../api/format'
import type { ProcessPage, TraceCategory, TraceEvent } from '../api/types'
import {
  CATEGORY_LABEL, KIND_LABEL, KIND_TIP, REFUSED_REASON, STOP_REASON,
  eventLine, formatLatency, formatTime, peerText,
} from '../api/trace'
import { useTrace } from '../stores/trace'
import { useSettings } from '../stores/settings'
import { useNodes } from '../stores/nodes'
import PageHeader from '../components/PageHeader.vue'
import NodeGuard from '../components/NodeGuard.vue'

const trace = useTrace()
const settings = useSettings()
const nodes = useNodes()
const message = useMessage()
const route = useRoute()
const router = useRouter()

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
    if (r.processes.length) message.success(`开始跟踪 ${r.processes.length} 个进程`)
  } catch (e) {
    message.error(`无法开始跟踪：${errorText(e)}`)
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

// "跟踪消息" from the process list or the process drawer: ?target=<pid>.
watch(() => [route.query.target, trace.node] as const, ([t, n]) => {
  if (typeof t !== 'string' || !t || !n || settings.readOnly) return
  targets.value = [t]
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
        || (KIND_LABEL[e.kind] ?? e.kind).includes(q)))
})

function latencyOf(e: TraceEvent): number | null {
  const p = trace.pair(e.ref)
  return p?.call && p.reply ? p.reply.t - p.call.t : null
}

const columns = computed<DataTableColumns<TraceEvent>>(() => [
  {
    key: 't', title: '时间', width: 124,
    render: (e) => h('span', { class: 'mono muted nowrap' }, formatTime(e.t)),
  },
  ...(multi.value ? [{
    key: 'pid', title: '进程', width: 160, ellipsis: { tooltip: true },
    render: (e: TraceEvent) => h('span', { class: 'mono' }, processName(e.pid)),
  }] : []),
  {
    key: 'dir', title: '', width: 44, align: 'center',
    render: (e) => h(NIcon, {
      component: e.dir === 'in' ? ArrowBackOutline : ArrowForwardOutline,
      class: e.dir === 'in' ? 'dir-in' : 'dir-out', size: 16,
      title: e.dir === 'in' ? '收到' : '发出',
    }),
  },
  {
    key: 'kind', title: '类型', width: 110,
    render: (e) => h(NTag, {
      size: 'small', bordered: false,
      type: e.cat === 'business' ? (e.kind === 'call' || e.kind === 'reply' ? 'info' : 'success')
        : e.cat === 'network' ? 'warning' : 'default',
    }, { default: () => KIND_LABEL[e.kind] ?? e.kind }),
  },
  {
    key: 'peer', title: '对方', width: 220, ellipsis: { tooltip: true },
    render: (e) => {
      if (e.kind === 'reply' && !e.peer) {
        const call = trace.pair(e.ref)?.call
        return h('span', { class: 'mono muted' }, call ? `↩ ${peerText(call)}` : '调用方')
      }
      return h('span', { class: ['mono', e.dead ? 'dead' : ''] },
        (e.dead ? '（已不存在）' : '') + peerText(e))
    },
  },
  {
    key: 'summary', title: '内容', minWidth: 300, ellipsis: { tooltip: false },
    render: (e) => h('span', { class: ['mono', e.cat !== 'business' ? 'muted' : ''] }, e.summary),
  },
  {
    key: 'lat', title: '耗时', width: 96, align: 'right',
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
  if (s.status === 'running') return `跟踪中 · 已收到 ${formatNumber(s.count ?? 0)} 条`
  if (s.status === 'stopped') return STOP_REASON[s.reason ?? ''] ?? `已停止（${s.reason}）`
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
  <PageHeader title="消息跟踪" :subtitle="nodes.current ?? undefined">
    <NSpace align="center" :size="8">
      <NTag v-if="statusText" :type="running ? 'success' : trace.state.reason === 'stopped_by_user' || trace.state.reason === 'max_events' || trace.state.reason === 'max_seconds' ? 'default' : 'warning'"
            :bordered="false" round>
        {{ statusText }}
      </NTag>
      <NButton v-if="running" secondary type="error" @click="stop">
        <template #icon><NIcon :component="StopOutline" /></template>
        停止
      </NButton>
    </NSpace>
  </PageHeader>
  <NodeGuard>
    <NCard v-if="!running" size="small" class="setup" title="跟踪哪些进程">
      <NAlert v-if="settings.readOnly" type="info" :bordered="false">
        只读模式下不能开始跟踪：跟踪会给目标节点带来额外开销。
      </NAlert>
      <template v-else>
        <div class="setup-row">
          <NSelect v-model:value="targets" multiple filterable tag :options="nameOptions"
                   :max-tag-count="6" placeholder="输入注册名或 PID（如 <0.123.0>），最多 10 个"
                   class="targets" />
          <label class="lim">最多
            <NInputNumber v-model:value="maxEvents" :min="1" :max="100000" :step="1000" size="small"
                          style="width: 120px" />
            条</label>
          <label class="lim">最长
            <NInputNumber v-model:value="maxSeconds" :min="1" :max="600" :step="30" size="small"
                          style="width: 100px" />
            秒</label>
          <NButton type="primary" :loading="starting" :disabled="!targets.length" @click="start">
            <template #icon><NIcon :component="PlayOutline" /></template>
            开始跟踪
          </NButton>
        </div>
        <NText depth="3" class="hint">
          只记录收发的消息，不跟踪函数调用。为保护目标节点：消息速率超过每秒 2000 条、处理不过来、或达到上面的上限时会自动停止；EObserver 断开时也会自动停止。
          也可以在进程列表里右键一个进程选择「跟踪消息」。
        </NText>
      </template>
      <NAlert v-for="r in refused" :key="r.target" type="warning" :bordered="false" style="margin-top: 8px">
        <span class="mono">{{ r.target }}</span>：{{ REFUSED_REASON[r.reason] ?? r.reason }}
      </NAlert>
    </NCard>

    <NAlert v-if="trace.error" type="error" style="margin-bottom: 12px">{{ trace.error }}</NAlert>

    <template v-if="trace.state.status !== 'none' || trace.events.length">
      <div class="bar">
        <NSpace align="center" :size="12">
          <span v-if="trace.processes.length" class="procs">
            <NTag v-for="p in trace.processes" :key="p.pid" size="small" :bordered="false" class="mono">
              {{ p.name ?? p.pid }}<template v-if="p.name"> {{ p.pid }}</template>
            </NTag>
          </span>
          <NRadioGroup v-model:value="dir" size="small">
            <NRadioButton value="all">全部</NRadioButton>
            <NRadioButton value="in">收到</NRadioButton>
            <NRadioButton value="out">发出</NRadioButton>
          </NRadioGroup>
          <NCheckboxGroup v-model:value="cats">
            <NSpace :size="12">
              <NCheckbox v-for="c in (['business', 'system', 'network'] as const)" :key="c" :value="c">
                {{ CATEGORY_LABEL[c] }}（{{ formatNumber(counts[c] ?? 0) }}）
              </NCheckbox>
            </NSpace>
          </NCheckboxGroup>
        </NSpace>
        <NSpace align="center" :size="8">
          <NInput v-model:value="search" size="small" clearable placeholder="搜索内容或对方" style="width: 220px">
            <template #prefix><NIcon :component="SearchOutline" /></template>
          </NInput>
          <label class="follow"><NSwitch v-model:value="follow" size="small" /> 自动滚到最新</label>
          <NTooltip>
            <template #trigger>
              <NButton size="small" quaternary circle :disabled="!filtered.length" @click="exportText">
                <template #icon><NIcon :component="DownloadOutline" /></template>
              </NButton>
            </template>
            按当前筛选导出为文本
          </NTooltip>
          <NTooltip>
            <template #trigger>
              <NButton size="small" quaternary circle @click="trace.clear()">
                <template #icon><NIcon :component="TrashOutline" /></template>
              </NButton>
            </template>
            清空列表（不影响跟踪）
          </NTooltip>
        </NSpace>
      </div>
      <NDataTable ref="table" :columns="columns" :data="filtered" :row-key="(e: TraceEvent) => e.seq"
                  :row-props="rowProps" size="small" virtual-scroll :max-height="'calc(100vh - 380px)'"
                  :min-height="240" :scroll-x="900">
        <template #empty>
          <NEmpty :description="trace.events.length ? '没有符合筛选条件的消息' : running ? '等待消息…' : '没有记录到消息'" />
        </template>
      </NDataTable>
      <p v-if="(trace.state.dropped ?? 0) > 0" class="note">
        目标节点上只保留最近 5000 条，较早的 {{ formatNumber(trace.state.dropped ?? 0) }} 条在读取前已被丢弃。
      </p>
      <p class="note">点击一行查看完整内容。调用和回复按引用自动配对并计算耗时。</p>
    </template>

    <NModal v-model:show="showDetail">
      <NCard v-if="shown" closable style="width: min(900px, 94vw)" @close="selected = null">
        <template #header>
          <NSpace align="center" :size="8">
            <NTag size="small" :bordered="false">{{ CATEGORY_LABEL[shown.cat] }} · {{ KIND_LABEL[shown.kind] ?? shown.kind }}</NTag>
            <span class="mono">{{ processName(shown.pid) }}</span>
            <span>{{ shown.dir === 'in' ? '收到' : '发出' }}</span>
            <NText depth="3" class="mono">{{ formatTime(shown.t) }}</NText>
          </NSpace>
        </template>
        <p v-if="KIND_TIP[shown.kind]" class="tip">{{ KIND_TIP[shown.kind] }}</p>
        <p v-if="peerText(shown)" class="peer">
          {{ shown.dir === 'in' ? '来自' : '发给' }} <span class="mono">{{ peerText(shown) }}</span>
          <template v-if="shown.dead">（目标进程已不存在）</template>
        </p>
        <template v-if="selectedPair && (shown.kind === 'call' || shown.kind === 'reply')">
          <div class="pair-title">调用</div>
          <pre class="term">{{ selectedPair.call?.text ?? '（调用不在列表中）' }}</pre>
          <div class="pair-title">
            回复
            <NText v-if="latencyOf(shown) !== null" depth="3">· 耗时 {{ formatLatency(latencyOf(shown)!) }}</NText>
          </div>
          <pre class="term">{{ selectedPair.reply?.text ?? '（还没有收到回复）' }}</pre>
        </template>
        <pre v-else class="term">{{ shown.text }}</pre>
      </NCard>
    </NModal>
  </NodeGuard>
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
  display: inline-flex;
  gap: 6px;
  flex-wrap: wrap;
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
