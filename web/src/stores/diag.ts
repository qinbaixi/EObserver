import { defineStore } from 'pinia'
import { shallowReactive } from 'vue'
import { client } from '../api/ws'
import type { DiagReport } from '../api/types'

// Last health check per node, kept while the app is open so it survives
// switching pages.
export const useDiag = defineStore('diag', () => {
  const health = shallowReactive<Record<string, { report: DiagReport; at: number }>>({})
  client.on('node_removed', ({ node }: { node: string }) => {
    delete health[node]
  })
  return { health }
})
