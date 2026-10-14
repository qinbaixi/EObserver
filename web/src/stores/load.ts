import { defineStore } from 'pinia'
import { computed, onBeforeUnmount, ref, shallowReactive, shallowRef, watch, type ShallowRef } from 'vue'
import { client } from '../api/ws'
import type { LoadPoint, NodeSummary } from '../api/types'
import { useNodes } from './nodes'

// Keeps load samples per node while the app is open, so the charts keep
// their history when the user navigates between pages. Everything lives in
// the browser; nothing is stored on the observed nodes.
//
// The current node is sampled once the Load page has been opened, at the
// interval chosen there. Every connected node (at most MAX_PEERS) is also
// sampled in the background from app start, so the overview wall has
// history when it is opened, unless the user paused it there. Views can ask
// for more nodes (the compare mode, the cards on screen when there are more
// than MAX_PEERS). Peers use the light `node.load` topic every peerInterval.
export const MAX_WINDOW_MS = 10 * 60 * 1000
export const PEER_INTERVAL = 2000
export const SUMMARY_INTERVAL = 5000
export const MAX_PEERS = 50

const PEER_INTERVAL_KEY = 'eobs.interval.overview'

function loadPeerInterval() {
  try {
    const v = Number(localStorage.getItem(PEER_INTERVAL_KEY))
    return v >= 500 ? v : PEER_INTERVAL
  } catch {
    return PEER_INTERVAL
  }
}

interface Sampler {
  interval: number
  stop: () => void
}

export const useLoad = defineStore('load', () => {
  const nodes = useNodes()
  const interval = ref(1000)
  const active = ref(false)
  // Background sampling for the overview wall; not remembered across runs,
  // so it always starts collecting.
  const paused = ref(false)
  const peerInterval = ref(loadPeerInterval())
  // Per node history and last error; each history is its own ref so a view
  // only re-renders for the nodes it shows.
  const history = shallowReactive<Record<string, ShallowRef<LoadPoint[]>>>({})
  const errors = shallowReactive<Record<string, string | null>>({})
  // Latest node.summary of nodes a view asked limits for.
  const summaries = shallowReactive<Record<string, NodeSummary>>({})
  // Which nodes each open view wants sampled: key -> {nodes, summary}.
  const demand = shallowReactive<Record<string, { nodes: string[]; summary: boolean }>>({})
  const loadSubs = new Map<string, Sampler>()
  const summarySubs = new Map<string, () => void>()

  const node = computed(() =>
    nodes.currentInfo?.status === 'connected' ? nodes.currentInfo.node : null)

  function push(n: string, p: LoadPoint) {
    errors[n] = null
    const r = (history[n] ??= shallowRef<LoadPoint[]>([]))
    const cutoff = p.time - MAX_WINDOW_MS
    let i = 0
    while (i < r.value.length && r.value[i].time < cutoff) i++
    r.value = [...r.value.slice(i), p]
  }

  const connected = (n: string) => nodes.nodes[n]?.status === 'connected'

  // Nodes to sample and at which interval.
  // Views' demand first, then the background demand of the overview wall.
  const demands = computed(() => {
    const out = Object.values(demand)
    if (!paused.value) out.push({ nodes: Object.keys(nodes.nodes).filter(connected), summary: true })
    return out
  })

  const wanted = computed(() => {
    const out = new Map<string, number>()
    if (active.value && node.value) out.set(node.value, interval.value)
    let peers = 0
    for (const d of demands.value) {
      for (const n of d.nodes) {
        if (out.has(n) || !connected(n) || peers >= MAX_PEERS) continue
        out.set(n, peerInterval.value)
        peers++
      }
    }
    return out
  })

  const wantedSummary = computed(() => {
    const out = new Set<string>()
    for (const d of demands.value) {
      if (!d.summary) continue
      for (const n of d.nodes) if (wanted.value.has(n)) out.add(n)
    }
    return out
  })

  function reconcile() {
    for (const [n, s] of loadSubs) {
      if (wanted.value.get(n) !== s.interval) {
        s.stop()
        loadSubs.delete(n)
      }
    }
    for (const [n, every] of wanted.value) {
      if (loadSubs.has(n)) continue
      const stop = client.subscribe('node.load', { node: n }, every,
        (p: LoadPoint) => push(n, p), (e) => { errors[n] = e })
      loadSubs.set(n, { interval: every, stop })
    }
    for (const [n, stop] of summarySubs) {
      if (!wantedSummary.value.has(n)) {
        stop()
        summarySubs.delete(n)
      }
    }
    for (const n of wantedSummary.value) {
      if (summarySubs.has(n)) continue
      summarySubs.set(n, client.subscribe('node.summary', { node: n }, SUMMARY_INTERVAL,
        (s: NodeSummary) => { summaries[n] = s }))
    }
  }

  watch([wanted, wantedSummary], reconcile, { immediate: true })
  watch(peerInterval, (v) => {
    try { localStorage.setItem(PEER_INTERVAL_KEY, String(v)) } catch { /* ignore */ }
  })

  // Takes a sample now: restarts the running subscriptions, or while paused
  // reads every connected node once.
  function refresh() {
    if (!paused.value) {
      for (const sub of loadSubs.values()) sub.stop()
      loadSubs.clear()
      for (const stop of summarySubs.values()) stop()
      summarySubs.clear()
      reconcile()
      return
    }
    for (const n of Object.keys(nodes.nodes).filter(connected).slice(0, MAX_PEERS)) {
      if (!loadSubs.has(n)) once('node.load', n, (p: LoadPoint) => push(n, p))
      if (!summarySubs.has(n)) once('node.summary', n, (x: NodeSummary) => { summaries[n] = x })
    }
  }

  function once<T>(topic: string, n: string, onData: (d: T) => void) {
    const stop = client.subscribe(topic, { node: n }, 60_000, (d: T) => { stop(); onData(d) },
      (e) => { stop(); errors[n] = e })
  }

  client.on('node_removed', ({ node: n }: { node: string }) => {
    delete history[n]
    delete errors[n]
    delete summaries[n]
  })

  function start() {
    active.value = true
  }

  // Asks for nodes to be sampled while the calling component is mounted.
  // summary: also keep their node.summary (limits, OTP version, uptime).
  function useSampling(key: string, list: () => string[], summary = false) {
    watch(list, (ns) => { demand[key] = { nodes: ns, summary } }, { immediate: true })
    onBeforeUnmount(() => { delete demand[key] })
  }

  // The current node's history, as the single-node Load page shows it.
  const points = computed(() => (node.value ? history[node.value]?.value ?? [] : []))
  const error = computed(() => (node.value ? errors[node.value] ?? null : null))

  return { points, interval, error, node, start, history, errors, summaries, useSampling,
           paused, peerInterval, refresh }
})
