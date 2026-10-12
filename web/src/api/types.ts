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
  uptime_ms: number
  features: { socket: boolean; mnesia: boolean }
}

export interface NodeInfo {
  node: string
  status: NodeStatus
  error: string | null
  summary: NodeSummary | null
  agent: { loaded: boolean; version: number; method: string } | null
}
