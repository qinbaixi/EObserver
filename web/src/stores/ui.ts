import { defineStore } from 'pinia'
import { ref } from 'vue'

export const useUi = defineStore('ui', () => {
  const connectOpen = ref(false)
  const connectNode = ref('')
  const paletteOpen = ref(false)
  // A node being dragged out of the node switcher (to open it in a new tab).
  const dragNode = ref<string | null>(null)

  function openConnect(node = '') {
    connectNode.value = node
    connectOpen.value = true
  }

  return { connectOpen, connectNode, paletteOpen, dragNode, openConnect }
})
