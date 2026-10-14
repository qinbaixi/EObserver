import { defineStore } from 'pinia'
import { ref } from 'vue'
import type { DiagReport } from '../api/types'

// Last health check per node, kept while the app is open so it survives
// switching pages.
export const useDiag = defineStore('diag', () => {
  const health = ref<Record<string, { report: DiagReport; at: number }>>({})
  return { health }
})
