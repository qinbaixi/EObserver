import { defineStore } from 'pinia'
import { computed, ref, shallowRef, triggerRef, watch } from 'vue'
import { client } from '../api/ws'
import { errorText } from '../api/errors'
import type { CrashGroup, LogLine, LogsData, RestartGroup } from '../api/types'
import { useNodes } from './nodes'

// Log lines kept in the browser; older ones are dropped.
export const MAX_LINES = 10000

type Status = Omit<LogsData, 'logs' | 'crashes' | 'restarts'>

// The current node's live log and crash records. The target only
// collects while someone pulls (the Logs page is open, see acquire), but
// what was collected stays here when the page is left.
export const useLogs = defineStore('logs', () => {
  const nodes = useNodes()
  const status = ref<Status | null>(null)
  const lines = shallowRef<LogLine[]>([])
  const crashes = shallowRef(new Map<number, CrashGroup>())
  const restarts = shallowRef(new Map<number, RestartGroup>())
  // Lines overwritten on the target before they were read, summed.
  const lost = ref(0)
  const error = ref<string | null>(null)
  // While paused, new lines wait here instead of joining the list.
  const paused = ref(false)
  const pending: LogLine[] = []
  let collection: number | undefined
  let lastSeq = 0
  let users = 0
  let stop: (() => void) | null = null

  const node = computed(() =>
    nodes.currentInfo?.status === 'connected' ? nodes.currentInfo.node : null)

  function clearLines() {
    lines.value = []
    pending.length = 0
  }

  function reset() {
    clearLines()
    crashes.value = new Map()
    restarts.value = new Map()
    status.value = null
    lost.value = 0
    collection = undefined
    lastSeq = 0
  }

  function append(list: LogLine[]) {
    const all = lines.value
    all.push(...list)
    if (all.length > MAX_LINES) all.splice(0, all.length - MAX_LINES)
    triggerRef(lines)
  }

  function onData(d: LogsData) {
    error.value = null
    if (d.id !== collection) {
      // A new collection on the target (the old one timed out or the
      // agent was reloaded): its sequence numbers start over.
      if (collection !== undefined) reset()
      collection = d.id
    }
    const { logs, crashes: cs, restarts: rs, ...rest } = d
    status.value = rest
    lost.value += d.lost
    // A new subscription reads the target's rings from the start again.
    const fresh = logs.filter((l) => l.seq > lastSeq)
    if (fresh.length) {
      lastSeq = fresh[fresh.length - 1].seq
      if (paused.value) {
        pending.push(...fresh)
        if (pending.length > MAX_LINES) pending.splice(0, pending.length - MAX_LINES)
      } else {
        append(fresh)
      }
    }
    if (cs.length) {
      for (const c of cs) crashes.value.set(c.id, c)
      triggerRef(crashes)
    }
    if (rs.length) {
      for (const r of rs) restarts.value.set(r.id, r)
      triggerRef(restarts)
    }
  }

  function subscribe() {
    stop?.()
    stop = null
    if (!node.value || users === 0) return
    stop = client.subscribe('logs.events', { node: node.value }, 1000, onData,
      (e) => { error.value = errorText(e) })
  }

  watch(node, () => { reset(); subscribe() })
  watch(paused, (p) => {
    if (!p && pending.length) {
      append(pending.splice(0))
    }
  })

  // Pages showing the logs hold the collection open while mounted.
  function acquire() {
    users++
    if (users === 1) subscribe()
  }

  function release() {
    users = Math.max(0, users - 1)
    if (users === 0) {
      stop?.()
      stop = null
    }
  }

  return {
    node, status, lines, crashes, restarts, lost, error, paused,
    acquire, release, clearLines,
  }
})
