import { defineStore } from 'pinia'
import { ref } from 'vue'

export const useUi = defineStore('ui', () => {
  const connectOpen = ref(false)
  const connectNode = ref('')

  function openConnect(node = '') {
    connectNode.value = node
    connectOpen.value = true
  }

  return { connectOpen, connectNode, openConnect }
})
