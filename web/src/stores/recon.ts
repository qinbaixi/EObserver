import { defineStore } from 'pinia'
import { ref } from 'vue'
import type {
  BinLeakReport, InetReport, PortTypesReport, ReconAllocReport, ReconProcReport, SchedUsageReport, WindowReport,
} from '../api/types'

export interface Result<T> { report: T; at: number }
type PerNode<T> = Record<string, Result<T>>

// Last result of each recon tool per node, kept while the app is open so
// they survive switching pages.
export const useRecon = defineStore('recon', () => {
  const proc = ref<PerNode<ReconProcReport>>({})
  const window = ref<PerNode<WindowReport>>({})
  const binLeak = ref<PerNode<BinLeakReport>>({})
  const inet = ref<PerNode<InetReport>>({})
  const ports = ref<PerNode<PortTypesReport>>({})
  const alloc = ref<PerNode<ReconAllocReport>>({})
  const sched = ref<PerNode<SchedUsageReport>>({})
  return { proc, window, binLeak, inet, ports, alloc, sched }
})
