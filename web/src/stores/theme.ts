import { defineStore } from 'pinia'
import { computed, ref } from 'vue'

export type Mode = 'light' | 'dark' | 'system'
const KEY = 'eobs.theme'

export const useTheme = defineStore('theme', () => {
  let saved: Mode = 'system'
  try {
    saved = (localStorage.getItem(KEY) as Mode) || 'system'
  } catch {
    /* storage unavailable */
  }
  const mode = ref<Mode>(saved)
  const media = window.matchMedia('(prefers-color-scheme: dark)')
  const systemDark = ref(media.matches)
  media.addEventListener('change', (e) => (systemDark.value = e.matches))

  const isDark = computed(() => (mode.value === 'system' ? systemDark.value : mode.value === 'dark'))

  function setMode(m: Mode) {
    mode.value = m
    try {
      localStorage.setItem(KEY, mode.value)
    } catch {
      /* storage unavailable */
    }
  }

  return { mode, isDark, setMode }
})
