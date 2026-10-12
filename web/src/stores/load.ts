import { defineStore } from 'pinia'
import { computed, ref, watch } from 'vue'
import { client } from '../api/ws'
import type { LoadPoint } from '../api/types'
import { useNodes } from './nodes'

// Keeps load samples for the current node while the app is open, so the
// charts keep their history when the user navigates between pages.
export const MAX_WINDOW_MS = 10 * 60 * 1000

export const useLoad = defineStore('load', () => {
  const nodes = useNodes()
  const points = ref<LoadPoint[]>([])
  const interval = ref(1000)
  const error = ref<string | null>(null)
  const active = ref(false)
  let stop: (() => void) | null = null

  const node = computed(() =>
    nodes.currentInfo?.status === 'connected' ? nodes.currentInfo.node : null)

  function restart() {
    stop?.()
    stop = null
    if (!active.value || !node.value) return
    stop = client.subscribe('node.load', { node: node.value }, interval.value, (p: LoadPoint) => {
      error.value = null
      const list = points.value
      list.push(p)
      const cutoff = p.time - MAX_WINDOW_MS
      while (list.length && list[0].time < cutoff) list.shift()
    }, (e) => { error.value = e })
  }

  // A different node means a different history.
  watch(() => nodes.current, () => { points.value = [] })
  watch([node, interval, active], restart)

  function start() {
    active.value = true
  }

  return { points, interval, error, node, start }
})
