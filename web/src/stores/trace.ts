import { defineStore } from 'pinia'
import { computed, ref, shallowRef, triggerRef, watch } from 'vue'
import { client } from '../api/ws'
import type {
  SavedTrace, TraceEvent, TraceProcess, TraceStart, TraceState, TraceStats,
} from '../api/types'
import { useNodes } from './nodes'
import { i18n } from '../i18n'

// Events kept in the browser; older ones are dropped.
export const MAX_EVENTS = 20000

// A call and its reply, matched by the gen call reference.
export interface Pair {
  call?: TraceEvent
  reply?: TraceEvent
}

// A saved trace opened from a file: shown instead of the live trace,
// read-only, until it is closed.
export interface Replay {
  file: string
  data: SavedTrace
  pairs: Map<string, Pair>
}

function addPair(pairs: Map<string, Pair>, e: TraceEvent) {
  if (e.ref && (e.kind === 'call' || e.kind === 'reply')) {
    const p = pairs.get(e.ref) ?? {}
    if (e.kind === 'call') p.call = e
    else p.reply = e
    pairs.set(e.ref, p)
  }
}

// The current node's message trace. Collects events while the app is
// open, so the list survives navigating between pages.
export const useTrace = defineStore('trace', () => {
  const nodes = useNodes()
  const liveState = ref<TraceState>({ status: 'none' })
  let live: TraceEvent[] = []
  const livePairs = new Map<string, Pair>()
  // What the page shows: the live events, or the replay's.
  const events = shallowRef<TraceEvent[]>(live)
  const replay = shallowRef<Replay | null>(null)
  const error = ref<string | null>(null)
  let id: number | undefined
  let stop: (() => void) | null = null

  const node = computed(() =>
    nodes.currentInfo?.status === 'connected' ? nodes.currentInfo.node : null)

  function clear() {
    live = []
    livePairs.clear()
    if (!replay.value) events.value = live
  }

  function add(list: TraceEvent[]) {
    if (!list.length) return
    for (const e of list) {
      live.push(e)
      addPair(livePairs, e)
    }
    if (live.length > MAX_EVENTS) {
      for (const e of live.splice(0, live.length - MAX_EVENTS)) if (e.ref) livePairs.delete(e.ref)
    }
    if (!replay.value) triggerRef(events)
  }

  function restart() {
    stop?.()
    stop = null
    id = undefined
    if (!node.value) return
    stop = client.subscribe('trace.events', { node: node.value }, 1000, (d: TraceState) => {
      error.value = null
      if (d.id !== id) {
        id = d.id
        clear()
      }
      const { events: list, ...rest } = d
      liveState.value = rest
      add(list ?? [])
    }, (e) => { error.value = e })
  }

  watch(node, () => { clear(); liveState.value = { status: 'none' }; restart() }, { immediate: true })

  async function start(targets: string[], maxEvents: number, maxSeconds: number) {
    const n = node.value
    if (!n) throw new Error(i18n.global.t('procs.trace.not_connected'))
    const r = await client.request<TraceStart>('trace.start', {
      node: n, targets, max_events: maxEvents, max_seconds: maxSeconds,
    })
    // Pick the new trace up right away instead of on the next tick.
    restart()
    return r
  }

  async function stopTrace() {
    const n = node.value
    if (n) await client.request('trace.stop', { node: n })
  }

  function pair(ref: string | null): Pair | undefined {
    if (!ref) return undefined
    return (replay.value?.pairs ?? livePairs).get(ref)
  }

  const state = computed<TraceState>(() => replay.value?.data.state ?? liveState.value)
  const processes = computed<TraceProcess[]>(() => state.value.processes ?? [])

  // The live trace as a file: its events, plus the call statistics with
  // details while the node still has them.
  async function save(): Promise<number> {
    const n = node.value
    let stats: TraceStats | null = null
    if (n && liveState.value.status !== 'none') {
      try {
        stats = await client.request<TraceStats>('trace.stats', { node: n, id: liveState.value.id ?? null })
      } catch {
        stats = null
      }
    }
    const data: SavedTrace = {
      format: 'eobserver-trace', version: 1, node: n, saved_at: Date.now(),
      state: liveState.value, events: live, stats,
    }
    const blob = new Blob([JSON.stringify(data)], { type: 'application/json' })
    const a = document.createElement('a')
    a.href = URL.createObjectURL(blob)
    a.download = `trace-${n ?? 'node'}-${new Date().toISOString().replace(/[:.]/g, '-')}.json`
    a.click()
    setTimeout(() => URL.revokeObjectURL(a.href), 1000)
    return live.length
  }

  // Throws 'bad_file' when the file is not a saved trace.
  async function open(file: File) {
    let data: SavedTrace
    try {
      data = JSON.parse(await file.text())
    } catch {
      throw new Error('bad_file')
    }
    if (!data || data.format !== 'eobserver-trace' || !Array.isArray(data.events)
        || typeof data.state !== 'object' || data.state === null) {
      throw new Error('bad_file')
    }
    const pairs = new Map<string, Pair>()
    for (const e of data.events) addPair(pairs, e)
    replay.value = { file: file.name, data, pairs }
    events.value = data.events
    return data.events.length
  }

  function closeReplay() {
    replay.value = null
    events.value = live
  }

  return {
    state, events, error, node, processes, replay, start, stop: stopTrace, clear, pair,
    save, open, closeReplay,
  }
})
