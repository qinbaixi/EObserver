import { defineStore } from 'pinia'
import { ref } from 'vue'
import { client } from '../api/ws'

// Server-side settings the UI needs to know about (e.g. --read-only).
export const useSettings = defineStore('settings', () => {
  const readOnly = ref(false)
  const version = ref('')

  async function load() {
    try {
      const s = await client.request<{ read_only: boolean; version: string }>('settings.get')
      readOnly.value = s.read_only
      version.value = s.version
    } catch {
      /* older backend or not connected yet */
    }
  }

  client.on('socket_open', () => void load())
  return { readOnly, version, load }
})
