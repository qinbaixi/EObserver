import { defineStore } from 'pinia'
import { computed, ref, shallowRef, triggerRef, watch } from 'vue'
import { client } from '../api/ws'
import type { TraceEvent, TraceProcess, TraceStart, TraceState } from '../api/types'
import { useNodes } from './nodes'

// Events kept in the browser; older ones are dropped.
export const MAX_EVENTS = 20000

// A call and its reply, matched by the gen call reference.
export interface Pair {
  call?: TraceEvent
  reply?: TraceEvent
}

// The current node's message trace. Collects events while the app is
// open, so the list survives navigating between pages.
export const useTrace = defineStore('trace', () => {
  const nodes = useNodes()
  const state = ref<TraceState>({ status: 'none' })
  const events = shallowRef<TraceEvent[]>([])
  const pairs = new Map<string, Pair>()
  const error = ref<string | null>(null)
  let id: number | undefined
  let stop: (() => void) | null = null

  const node = computed(() =>
    nodes.currentInfo?.status === 'connected' ? nodes.currentInfo.node : null)

  function clear() {
    events.value = []
    pairs.clear()
  }

  function add(list: TraceEvent[]) {
    if (!list.length) return
    const all = events.value
    for (const e of list) {
      all.push(e)
      if (e.ref && (e.kind === 'call' || e.kind === 'reply')) {
        const p = pairs.get(e.ref) ?? {}
        if (e.kind === 'call') p.call = e
        else p.reply = e
        pairs.set(e.ref, p)
      }
    }
    if (all.length > MAX_EVENTS) {
      for (const e of all.splice(0, all.length - MAX_EVENTS)) if (e.ref) pairs.delete(e.ref)
    }
    triggerRef(events)
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
      state.value = rest
      add(list ?? [])
    }, (e) => { error.value = e })
  }

  watch(node, () => { clear(); state.value = { status: 'none' }; restart() }, { immediate: true })

  async function start(targets: string[], maxEvents: number, maxSeconds: number) {
    const n = node.value
    if (!n) throw new Error('节点未连接')
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
    return ref ? pairs.get(ref) : undefined
  }

  const processes = computed<TraceProcess[]>(() => state.value.processes ?? [])

  return { state, events, error, node, processes, start, stop: stopTrace, clear, pair }
})
