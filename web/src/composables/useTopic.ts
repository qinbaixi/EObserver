import { onBeforeUnmount, ref, watch, type Ref } from 'vue'
import { client } from '../api/ws'

// Subscribes to a backend topic for the given node while the component is
// mounted, re-subscribing whenever the node changes.
export function useTopic<T>(topic: string, node: Ref<string | null>, interval = 2000,
                            extra: () => Record<string, unknown> = () => ({})) {
  const data = ref<T | null>(null) as Ref<T | null>
  const error = ref<string | null>(null)
  let stop: (() => void) | null = null

  watch(node, (n) => {
    stop?.()
    stop = null
    data.value = null
    error.value = null
    if (!n) return
    stop = client.subscribe(topic, { node: n, ...extra() }, interval,
      (d) => { data.value = d; error.value = null },
      (e) => { error.value = e })
  }, { immediate: true })

  onBeforeUnmount(() => stop?.())
  return { data, error }
}
