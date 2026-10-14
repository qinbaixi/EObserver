import { defineStore } from 'pinia'
import { ref } from 'vue'
import type { DiagReport, WindowReport } from '../api/types'

// Last diagnosis results per node, kept while the app is open so they
// survive switching pages.
export const useDiag = defineStore('diag', () => {
  const health = ref<Record<string, { report: DiagReport; at: number }>>({})
  const window = ref<Record<string, { report: WindowReport; at: number }>>({})
  return { health, window }
})
