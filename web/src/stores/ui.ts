import { defineStore } from 'pinia'
import { ref } from 'vue'

export const useUi = defineStore('ui', () => {
  const connectOpen = ref(false)
  const connectNode = ref('')
  const paletteOpen = ref(false)

  function openConnect(node = '') {
    connectNode.value = node
    connectOpen.value = true
  }

  return { connectOpen, connectNode, paletteOpen, openConnect }
})
