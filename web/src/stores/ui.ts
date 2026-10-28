import { defineStore } from 'pinia'
import { ref } from 'vue'

const SWITCHER_KEY = 'eobs.switcherOpen'

function loadFlag(key: string) {
  try {
    return localStorage.getItem(key) === '1'
  } catch {
    return false
  }
}

export const useUi = defineStore('ui', () => {
  const connectOpen = ref(false)
  const connectNode = ref('')
  const paletteOpen = ref(false)
  // A node being dragged out of the node switcher (to open it in a new tab).
  const dragNode = ref<string | null>(null)
  // With several tabs the node switcher folds into a button; this unfolds it.
  const switcherOpen = ref(loadFlag(SWITCHER_KEY))

  function setSwitcherOpen(open: boolean) {
    switcherOpen.value = open
    try {
      localStorage.setItem(SWITCHER_KEY, open ? '1' : '0')
    } catch {
      /* storage unavailable */
    }
  }

  function openConnect(node = '') {
    connectNode.value = node
    connectOpen.value = true
  }

  return { connectOpen, connectNode, paletteOpen, dragNode, switcherOpen, setSwitcherOpen, openConnect }
})
