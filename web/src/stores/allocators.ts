import { defineStore } from 'pinia'
import { computed, ref, shallowReactive, shallowRef, watch, type ShallowRef } from 'vue'
import { client } from '../api/ws'
import { errorText } from '../api/errors'
import type { AllocInfo } from '../api/types'
import { useNodes } from './nodes'

// Samples the current node's memory allocators from app start, not only
// while the Allocators page is open, so its charts already have history
// when the page is opened. Pausing on the page stops it until resumed;
// the pause is not remembered across runs. Each node keeps its own history,
// so switching nodes back and forth keeps what was collected.

// Allocators drawn as their own series, in a fixed order so each keeps
// its color; the rest are folded into "other".
export const NAMED = ['eheap_alloc', 'binary_alloc', 'ets_alloc', 'll_alloc', 'literal_alloc', 'fix_alloc', 'std_alloc']
export const WINDOW_MS = 5 * 60 * 1000

export interface AllocPoint { time: number; carriers: Record<string, number>; util: Record<string, number | null> }

const INTERVAL_KEY = 'eobs.interval.node.allocators'

function loadInterval() {
  try {
    const v = Number(localStorage.getItem(INTERVAL_KEY))
    return v >= 500 ? v : 2000
  } catch {
    return 2000
  }
}

export const useAllocators = defineStore('allocators', () => {
  const nodes = useNodes()
  const paused = ref(false)
  const interval = ref(loadInterval())
  const latest = shallowReactive<Record<string, AllocInfo>>({})
  const histories = shallowReactive<Record<string, ShallowRef<AllocPoint[]>>>({})
  const errors = shallowReactive<Record<string, string | null>>({})
  let stop: (() => void) | null = null

  const node = computed(() =>
    nodes.currentInfo?.status === 'connected' ? nodes.currentInfo.node : null)

  function push(n: string, d: AllocInfo) {
    latest[n] = d
    errors[n] = null
    const time = Date.now()
    const carriers: Record<string, number> = { other: 0 }
    const util: Record<string, number | null> = {}
    for (const a of d.allocators) {
      if (NAMED.includes(a.type)) {
        carriers[a.type] = a.carriers
        util[a.type] = a.carriers > 0 ? a.blocks / a.carriers : null
      } else {
        carriers.other += a.carriers
      }
    }
    const r = (histories[n] ??= shallowRef<AllocPoint[]>([]))
    r.value = [...r.value.filter((p) => p.time >= time - WINDOW_MS), { time, carriers, util }]
  }

  // once: take a single sample and unsubscribe (manual refresh while paused).
  function start(once = false) {
    stop?.()
    stop = null
    const n = node.value
    if (!n) return
    const unsub = client.subscribe('node.allocators', { node: n }, interval.value,
      (d: AllocInfo) => {
        push(n, d)
        if (once) { unsub(); if (stop === unsub) stop = null }
      },
      (e) => { errors[n] = errorText(e) })
    stop = unsub
  }

  watch([node, paused, interval], ([, p]) => {
    if (p) { stop?.(); stop = null } else start()
  }, { immediate: true })
  watch(interval, (v) => {
    try { localStorage.setItem(INTERVAL_KEY, String(v)) } catch { /* ignore */ }
  })

  client.on('node_removed', ({ node: n }: { node: string }) => {
    delete latest[n]
    delete histories[n]
    delete errors[n]
  })

  function refresh() {
    start(paused.value)
  }

  const data = computed(() => (node.value ? latest[node.value] ?? null : null))
  const history = computed(() => (node.value ? histories[node.value]?.value ?? [] : []))
  const error = computed(() => (node.value ? errors[node.value] ?? null : null))

  return { node, data, history, error, paused, interval, refresh }
})
