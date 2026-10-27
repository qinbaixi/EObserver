import { defineStore } from 'pinia'
import { ref } from 'vue'
import { dumpRequest, onDumpProgress, onSocketOpen, type DumpInfo, type RecentFile } from '../api/dump'

// The crash dumps open in the EObserver backend (shared by every page that
// shows them) and their scan progress from dump_progress events.
export const useDumps = defineStore('dumps', () => {
  const list = ref<DumpInfo[]>([])
  const loaded = ref(false)
  const recent = ref<RecentFile[]>([])
  const error = ref<string | null>(null)

  async function refresh() {
    try {
      list.value = await dumpRequest<DumpInfo[]>('dump.list')
      loaded.value = true
      error.value = null
    } catch (e) {
      error.value = e instanceof Error ? e.message : String(e)
    }
  }

  async function loadRecent() {
    try {
      recent.value = await dumpRequest<RecentFile[]>('dump.recent')
    } catch {
      recent.value = []
    }
  }

  async function open(path: string): Promise<string> {
    const { id } = await dumpRequest<{ id: string }>('dump.open', { path })
    await refresh()
    void loadRecent()
    return id
  }

  async function close(id: string) {
    list.value = list.value.filter((d) => d.id !== id)
    try {
      await dumpRequest('dump.close', { id })
    } finally {
      await refresh()
    }
  }

  // Stops a running scan; the dump stays open with what was read so far.
  // (Backends without dump.cancel close it instead.)
  async function cancel(id: string) {
    try {
      await dumpRequest('dump.cancel', { id })
      await refresh()
    } catch {
      await close(id)
    }
  }

  const get = (id: string | null) => list.value.find((d) => d.id === id) ?? null

  let started = false
  function start() {
    if (started) return
    started = true
    onSocketOpen(() => { void refresh(); void loadRecent() })
    onDumpProgress((info) => {
      const i = list.value.findIndex((d) => d.id === info.id)
      if (i >= 0) list.value.splice(i, 1, { ...list.value[i], ...info })
      else void refresh()
    })
  }

  return { list, loaded, recent, error, refresh, loadRecent, open, close, cancel, get, start }
})
