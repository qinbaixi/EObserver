<script setup lang="ts">
// Messages between the chosen traced processes as a sequence diagram: a
// lifeline per process, one arrow per message, top to bottom in time
// order. Each message is drawn from its sender's "sent" event (so it is
// not drawn twice); only the rows in view are rendered, so thousands of
// messages scroll smoothly.
import { computed, onBeforeUnmount, onMounted, ref, watch } from 'vue'
import { useI18n } from 'vue-i18n'
import { NSelect, NEmpty, useThemeVars } from 'naive-ui'
import { useChartTheme } from '../../composables/useChartTheme'
import { formatLatency, formatTime } from '../../api/trace'
import type { TraceEvent, TraceProcess } from '../../api/types'
import type { Pair } from '../../stores/trace'

const props = defineProps<{
  events: TraceEvent[]
  processes: TraceProcess[]
  pair: (ref: string | null) => Pair | undefined
}>()
const emit = defineEmits<{ select: [e: TraceEvent] }>()
const { t } = useI18n()
const th = useChartTheme()
const vars = useThemeVars()

const ROW = 30
const HEAD = 40
// gap between the header and the first arrow's label
const PAD = 10
const TIME_W = 104
const MIN_LANE = 170
const MAX_DEFAULT = 6

// --- lanes ----------------------------------------------------------------

const lanes = ref<string[]>([])
watch(() => props.processes.map((p) => p.pid).join(' '), () => {
  const pids = props.processes.map((p) => p.pid)
  const kept = lanes.value.filter((p) => pids.includes(p))
  lanes.value = kept.length >= 2 ? kept : pids.slice(0, MAX_DEFAULT)
}, { immediate: true })

const label = (p: TraceProcess) => p.name ?? p.pid
const options = computed(() => props.processes.map((p) => ({
  label: p.name ? `${p.name}  ${p.pid}` : p.pid, value: p.pid,
})))
const laneProcs = computed(() => lanes.value
  .map((pid) => props.processes.find((p) => p.pid === pid))
  .filter((p): p is TraceProcess => !!p))

// A peer is a pid or a registered name.
const laneIndex = computed(() => {
  const m = new Map<string, number>()
  laneProcs.value.forEach((p, i) => {
    m.set(p.pid, i)
    if (p.name) m.set(p.name, i)
  })
  return m
})

interface Msg {
  e: TraceEvent
  from: number
  to: number
  latency: number | null
}

function target(e: TraceEvent): number | undefined {
  const idx = laneIndex.value
  const direct = (e.peer !== null ? idx.get(e.peer) : undefined)
    ?? (e.peer_name !== null ? idx.get(e.peer_name) : undefined)
  if (direct !== undefined) return direct
  // Replies go to an alias on OTP 24+: the caller comes from the call.
  if (e.kind === 'reply') {
    const call = props.pair(e.ref)?.call
    // With both sides traced the pair holds whichever call event came last.
    if (call && call.dir === 'in' && call.pid === e.pid && call.peer) return idx.get(call.peer)
    if (call && call.dir === 'out' && call.pid !== e.pid) return idx.get(call.pid)
  }
  return undefined
}

const messages = computed<Msg[]>(() => {
  const idx = laneIndex.value
  if (idx.size === 0 || laneProcs.value.length < 2) return []
  const out: Msg[] = []
  for (const e of props.events) {
    if (e.dir !== 'out') continue
    const from = idx.get(e.pid)
    if (from === undefined) continue
    const to = target(e)
    if (to === undefined) continue
    let latency: number | null = null
    if (e.kind === 'reply') {
      const call = props.pair(e.ref)?.call
      if (call) latency = e.t - call.t
    }
    out.push({ e, from, to, latency })
  }
  return out.sort((a, b) => a.e.t - b.e.t || a.e.seq - b.e.seq)
})

// --- layout and virtual scrolling ------------------------------------------

const scroller = ref<HTMLElement | null>(null)
const scrollTop = ref(0)
const viewW = ref(800)
const viewH = ref(400)
let ro: ResizeObserver | null = null
onMounted(() => {
  const el = scroller.value
  if (!el) return
  ro = new ResizeObserver(() => {
    viewW.value = el.clientWidth
    viewH.value = el.clientHeight
  })
  ro.observe(el)
})
onBeforeUnmount(() => ro?.disconnect())

const laneW = computed(() =>
  Math.max(MIN_LANE, (viewW.value - TIME_W) / Math.max(1, laneProcs.value.length)))
const totalW = computed(() => TIME_W + laneW.value * laneProcs.value.length)
const laneX = (i: number) => TIME_W + laneW.value * (i + 0.5)

const range = computed(() => {
  const n = messages.value.length
  const start = Math.max(0, Math.floor(scrollTop.value / ROW) - 5)
  const end = Math.min(n, start + Math.ceil(viewH.value / ROW) + 10)
  return { start, end }
})

// Stay at the bottom while new messages arrive, like the list.
const atBottom = ref(true)
function onScroll() {
  const el = scroller.value
  if (!el) return
  scrollTop.value = el.scrollTop
  atBottom.value = el.scrollTop + el.clientHeight >= el.scrollHeight - ROW
}
watch(() => messages.value.length, () => {
  const el = scroller.value
  if (el && atBottom.value) {
    requestAnimationFrame(() => { el.scrollTop = el.scrollHeight })
  }
})

// --- drawing ---------------------------------------------------------------

type Style = 'call' | 'reply' | 'cast' | 'info' | 'other'
function styleOf(e: TraceEvent): Style {
  if (e.cat !== 'business') return 'other'
  if (e.kind === 'call' || e.kind === 'reply' || e.kind === 'cast') return e.kind
  return 'info'
}
const colors = computed<Record<Style, string>>(() => ({
  call: th.value.series[0],
  reply: th.value.series[0],
  cast: th.value.series[2],
  info: th.value.series[6],
  other: th.value.muted,
}))
const dash: Record<Style, string | undefined> = {
  call: undefined, reply: '6 4', cast: undefined, info: undefined, other: '2 3',
}
const STYLES: Style[] = ['call', 'reply', 'cast', 'info', 'other']

interface Drawn {
  key: number
  m: Msg
  y: number
  x1: number
  x2: number
  style: Style
  text: string
  tx: number
}

const drawn = computed<Drawn[]>(() => {
  const { start, end } = range.value
  const list: Drawn[] = []
  for (let i = start; i < end; i++) {
    const m = messages.value[i]
    const y = (i - start) * ROW + ROW / 2 + 6
    const x1 = laneX(m.from)
    const x2 = m.from === m.to ? x1 + 28 : laneX(m.to)
    const room = Math.max(40, Math.abs(x2 - x1) - 16)
    const lat = m.latency !== null ? ` · ${formatLatency(m.latency)}` : ''
    const full = m.e.summary + lat
    const max = Math.floor(room / 6.6)
    const text = full.length > max ? `${full.slice(0, Math.max(1, max - 1))}…` : full
    list.push({
      key: m.e.seq, m, y, x1, x2, style: styleOf(m.e), text,
      tx: m.from === m.to ? x1 + 34 : (x1 + x2) / 2,
    })
  }
  return list
})

function path(d: Drawn): string {
  if (d.m.from === d.m.to) {
    return `M ${d.x1} ${d.y - 7} H ${d.x2} V ${d.y + 5} H ${d.x1 + 6}`
  }
  const dir = d.x2 > d.x1 ? 1 : -1
  return `M ${d.x1 + dir * 3} ${d.y} H ${d.x2 - dir * 4}`
}
</script>

<template>
  <div class="seq" :style="{ '--seq-bg': vars.cardColor }">
    <NEmpty v-if="processes.length < 2" :description="t('trace.seq.need_two')" class="empty" />
    <template v-else>
      <div class="bar">
        <label class="pick">
          {{ t('trace.seq.pick') }}
          <NSelect v-model:value="lanes" multiple :options="options" size="small" :max-tag-count="6"
                   :placeholder="t('trace.seq.pick_placeholder')" class="pick-select" />
        </label>
        <div class="legend">
          <span v-for="s in STYLES" :key="s" class="legend-item">
            <svg width="30" height="10" aria-hidden="true">
              <line x1="1" y1="5" x2="24" y2="5" :stroke="colors[s]" stroke-width="1.6"
                    :stroke-dasharray="dash[s]" />
              <path d="M 22 1.5 L 29 5 L 22 8.5 z" :fill="colors[s]" />
            </svg>
            {{ t(`trace.seq.legend.${s}`) }}
          </span>
        </div>
      </div>
      <div ref="scroller" class="scroller" @scroll="onScroll">
        <div class="inner" :style="{ height: `${HEAD + PAD + messages.length * ROW}px`, width: `${totalW}px` }">
          <div class="head" :style="{ width: `${totalW}px` }">
            <span class="head-time">{{ t('trace.seq.time') }}</span>
            <span v-for="(p, i) in laneProcs" :key="p.pid" class="head-lane mono"
                  :style="{ left: `${laneX(i)}px`, maxWidth: `${laneW - 12}px` }" :title="`${label(p)} ${p.pid}`">
              {{ label(p) }}
            </span>
          </div>
          <svg v-if="messages.length" class="canvas" :width="totalW"
               :height="(range.end - range.start) * ROW + 12"
               :style="{ top: `${HEAD + PAD + range.start * ROW - 6}px` }">
            <defs>
              <marker v-for="s in STYLES" :id="`seq-head-${s}`" :key="s" viewBox="0 0 10 10" refX="8" refY="5"
                      markerWidth="8" markerHeight="8" orient="auto-start-reverse">
                <path d="M 0 1 L 10 5 L 0 9 z" :fill="colors[s]" />
              </marker>
            </defs>
            <line v-for="(p, i) in laneProcs" :key="p.pid" :x1="laneX(i)" :x2="laneX(i)" y1="0"
                  :y2="(range.end - range.start) * ROW + 12" class="lifeline" />
            <g v-for="d in drawn" :key="d.key" class="msg" @click="emit('select', d.m.e)">
              <text x="8" :y="d.y + 4" class="time">{{ formatTime(d.m.e.t).slice(3) }}</text>
              <path :d="path(d)" fill="none" stroke="transparent" stroke-width="16" />
              <path :d="path(d)" fill="none" :stroke="colors[d.style]" stroke-width="1.6" class="line"
                    :stroke-dasharray="dash[d.style]" :marker-end="`url(#seq-head-${d.style})`" />
              <text :x="d.tx" :y="d.y - 6" :text-anchor="d.m.from === d.m.to ? 'start' : 'middle'"
                    class="label" :class="{ dead: d.m.e.dead }">{{ d.text }}</text>
            </g>
          </svg>
          <NEmpty v-else :description="laneProcs.length < 2 ? t('trace.seq.pick_two') : t('trace.seq.empty')"
                  class="empty" />
        </div>
      </div>
      <p class="note">
        <template v-if="messages.length">{{ t('trace.seq.note', { n: messages.length }) }}</template>
        {{ t('trace.seq.only_between') }}
      </p>
    </template>
  </div>
</template>

<style scoped>
.bar {
  display: flex;
  flex-wrap: wrap;
  justify-content: space-between;
  align-items: center;
  gap: 8px 24px;
  margin-bottom: 10px;
}
.pick {
  display: flex;
  align-items: center;
  gap: 8px;
  font-size: 13px;
  flex: 1 1 360px;
  min-width: 0;
  max-width: 720px;
}
.pick-select {
  flex: 1;
  min-width: 0;
}
.legend {
  display: flex;
  flex-wrap: wrap;
  gap: 4px 14px;
  font-size: 12px;
  opacity: 0.85;
}
.legend-item {
  display: inline-flex;
  align-items: center;
  gap: 4px;
}
.scroller {
  position: relative;
  overflow: auto;
  height: calc(100vh - 360px);
  min-height: 320px;
  border: 1px solid rgba(128, 128, 128, 0.2);
  border-radius: 6px;
  background: var(--seq-bg);
}
.inner {
  position: relative;
  min-width: 100%;
}
.head {
  position: sticky;
  top: 0;
  z-index: 1;
  height: 40px;
  background: var(--seq-bg);
  border-bottom: 1px solid rgba(128, 128, 128, 0.2);
}
.head-time {
  position: absolute;
  left: 8px;
  top: 12px;
  font-size: 12px;
  opacity: 0.6;
}
.head-lane {
  position: absolute;
  top: 10px;
  transform: translateX(-50%);
  padding: 2px 8px;
  border-radius: 4px;
  font-size: 12.5px;
  font-weight: 600;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
  background: rgba(32, 128, 240, 0.12);
}
.canvas {
  position: absolute;
  left: 0;
  display: block;
}
.lifeline {
  stroke: rgba(128, 128, 128, 0.35);
  stroke-width: 1;
  stroke-dasharray: 3 3;
}
.msg {
  cursor: pointer;
}
.msg:hover .line {
  stroke-width: 2.6;
}
.msg:hover .label {
  opacity: 1;
  font-weight: 600;
}
.time {
  font-size: 11px;
  fill: currentColor;
  opacity: 0.5;
  font-family: var(--mono, ui-monospace, SFMono-Regular, Menlo, monospace);
}
.label {
  font-size: 11px;
  fill: currentColor;
  opacity: 0.85;
  font-family: var(--mono, ui-monospace, SFMono-Regular, Menlo, monospace);
}
.label.dead {
  text-decoration: line-through;
  opacity: 0.5;
}
.empty {
  padding: 48px 0;
}
.note {
  font-size: 12px;
  opacity: 0.6;
  margin: 8px 0 0;
}
</style>
