export type NodeStatus = 'connecting' | 'connected' | 'disconnected' | 'failed'

export interface NodeSummary {
  node: string
  otp_release: string
  erts_version: string
  system_architecture: string
  word_size: number
  logical_processors: number | string
  schedulers: number
  schedulers_online: number
  dirty_cpu_schedulers: number
  dirty_io_schedulers: number
  process_count: number
  process_limit: number
  port_count: number
  port_limit: number
  atom_count: number
  atom_limit: number
  ets_count: number
  memory_total: number
  memory: MemoryInfo
  uptime_ms: number
  emu_flavor: string | null
  kernel_poll: boolean
  thread_pool_size: number
  dirty_cpu_schedulers_online: number
  ets_limit: number | null
  run_queue: number
  io_input: number
  io_output: number
  reductions: number
  context_switches: number
  gc_count: number
  gc_words_reclaimed: number
  features: { socket: boolean; mnesia: boolean }
}

export interface NodeInfo {
  node: string
  status: NodeStatus
  error: string | null
  summary: NodeSummary | null
  agent: { loaded: boolean; version: number; method: string } | null
}

export interface SchedulerUtil {
  id: number
  type: 'normal' | 'dirty_cpu' | 'dirty_io'
  util: number
}

export interface MemoryInfo {
  total: number
  processes: number
  processes_used: number
  system: number
  atom: number
  atom_used: number
  binary: number
  code: number
  ets: number
}

export interface LoadPoint {
  time: number
  run_queue: number
  process_count: number
  memory: MemoryInfo
  schedulers: SchedulerUtil[] | null
  io_input: number | null
  io_output: number | null
  reductions: number | null
}
