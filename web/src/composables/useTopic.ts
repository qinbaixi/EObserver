import { onBeforeUnmount, ref, shallowRef, watch, type Ref, type ShallowRef } from 'vue'
import { client } from '../api/ws'
import { errorText, rawError } from '../api/errors'

function loadInterval(topic: string, fallback: number): number {
  try {
    const v = Number(localStorage.getItem(`eobs.interval.${topic}`))
    return v >= 500 ? v : fallback
  } catch {
    return fallback
  }
}

function saveInterval(topic: string, v: number) {
  try { localStorage.setItem(`eobs.interval.${topic}`, String(v)) } catch { /* ignore */ }
}

// Subscribes to a backend topic for the given node while the component is
// mounted, re-subscribing whenever the node changes. The returned paused,
// interval and refresh drive the page's RefreshControl.
export function useTopic<T>(topic: string, node: Ref<string | null>, interval = 2000,
                            extra: () => Record<string, unknown> = () => ({})) {
  const data = shallowRef<T | null>(null) as ShallowRef<T | null>
  const error = ref<string | null>(null)
  const errorCode = ref<string | null>(null)
  const every = ref(loadInterval(topic, interval))
  const paused = ref(false)
  let stop: (() => void) | null = null

  // once: take a single update and unsubscribe (manual refresh while paused).
  function start(once = false) {
    stop?.()
    stop = null
    const n = node.value
    if (!n) return
    const unsub = client.subscribe(topic, { node: n, ...extra() }, every.value,
      (d) => {
        data.value = d
        error.value = null
        errorCode.value = null
        if (once) { unsub(); if (stop === unsub) stop = null }
      },
      (e) => {
        errorCode.value = rawError(e)
        error.value = errorText(e)
        if (once) { unsub(); if (stop === unsub) stop = null }
      })
    stop = unsub
  }

  watch(node, () => {
    data.value = null
    error.value = null
    errorCode.value = null
    start(paused.value)
  }, { immediate: true })
  watch(every, (v) => {
    saveInterval(topic, v)
    if (!paused.value) start()
  })
  watch(paused, (p) => {
    if (p) { stop?.(); stop = null } else start()
  })

  function refresh() {
    start(paused.value)
  }

  onBeforeUnmount(() => stop?.())
  return { data, error, errorCode, paused, interval: every, refresh }
}
