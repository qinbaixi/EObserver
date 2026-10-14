import { computed, onBeforeUnmount, ref, watch, type Ref } from 'vue'
import { client } from '../../api/ws'
import { errorText } from '../../api/errors'
import type { Result } from '../../stores/recon'

// One on-demand recon request: the last result per node lives in the recon
// store (`slot`), the running flag and error are per tab. A node switch
// while running drops the answer for the old node into its own slot.
// `elapsed` (seconds) ticks while a request runs, for progress bars.
export function useTool<T>(slot: Ref<Record<string, Result<T>>>, node: () => string) {
  const running = ref(false)
  const error = ref<string | null>(null)
  const elapsed = ref(0)
  let ticker: number | undefined
  const last = computed(() => slot.value[node()] ?? null)
  const atText = computed(() => (last.value ? new Date(last.value.at).toLocaleTimeString() : ''))

  watch(node, () => { error.value = null })

  async function run(method: string, params: Record<string, unknown>, timeout: number) {
    if (running.value) return
    const n = node()
    running.value = true
    error.value = null
    const start = Date.now()
    elapsed.value = 0
    ticker = window.setInterval(() => { elapsed.value = (Date.now() - start) / 1000 }, 250)
    try {
      const report = await client.request<T>(method, { ...params, node: n }, timeout)
      slot.value[n] = { report, at: Date.now() }
    } catch (e) {
      if (n === node()) error.value = errorText(e)
    } finally {
      clearInterval(ticker)
      running.value = false
    }
  }

  onBeforeUnmount(() => clearInterval(ticker))
  return { running, error, elapsed, last, atText, run }
}
