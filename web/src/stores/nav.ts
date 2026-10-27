import { defineStore } from 'pinia'
import { computed, ref } from 'vue'
import { pages } from '../router'

const KEY = 'eobs.nav'
export const DEFAULT_PINNED = ['system', 'load', 'processes', 'trace', 'diagnosis']

// Which pages the sidebar shows directly, in the user's order; the rest are
// under "More".
export const useNav = defineStore('nav', () => {
  const known = new Set(pages.map((p) => p.name))
  let saved: string[] | null = null
  try {
    const raw = JSON.parse(localStorage.getItem(KEY) ?? 'null')
    if (Array.isArray(raw)) saved = raw.filter((n) => typeof n === 'string' && known.has(n))
  } catch {
    /* storage unavailable or corrupt */
  }
  const pinned = ref<string[]>(saved ?? DEFAULT_PINNED)
  const rest = computed(() => pages.map((p) => p.name).filter((n) => !pinned.value.includes(n)))

  function setPinned(list: string[]) {
    pinned.value = list.filter((n) => known.has(n))
    try {
      localStorage.setItem(KEY, JSON.stringify(pinned.value))
    } catch {
      /* storage unavailable */
    }
  }

  return { pinned, rest, setPinned }
})
