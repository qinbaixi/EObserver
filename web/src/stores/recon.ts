import { defineStore } from 'pinia'
import { shallowReactive } from 'vue'
import { client } from '../api/ws'
import type {
  BinLeakReport, InetReport, PortTypesReport, ReconAllocReport, ReconProcReport, SchedUsageReport, WindowReport,
} from '../api/types'

export interface Result<T> { report: T; at: number }
type PerNode<T> = Record<string, Result<T>>

// Last result of each recon tool per node, kept while the app is open so
// they survive switching pages.
export const useRecon = defineStore('recon', () => {
  const proc = shallowReactive<PerNode<ReconProcReport>>({})
  const window = shallowReactive<PerNode<WindowReport>>({})
  const binLeak = shallowReactive<PerNode<BinLeakReport>>({})
  const inet = shallowReactive<PerNode<InetReport>>({})
  const ports = shallowReactive<PerNode<PortTypesReport>>({})
  const alloc = shallowReactive<PerNode<ReconAllocReport>>({})
  const sched = shallowReactive<PerNode<SchedUsageReport>>({})
  client.on('node_removed', ({ node }: { node: string }) => {
    delete proc[node]
    delete window[node]
    delete binLeak[node]
    delete inet[node]
    delete ports[node]
    delete alloc[node]
    delete sched[node]
  })
  return { proc, window, binLeak, inet, ports, alloc, sched }
})
