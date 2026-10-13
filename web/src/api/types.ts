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

export interface ProcessRow {
  pid: string
  name: string | null
  initial_call: string
  current_function: string
  status: string
  reductions: number
  reds: number | null
  memory: number
  message_queue_len: number
}

export interface ProcessPage {
  total: number
  process_count: number
  has_delta: boolean
  rows: ProcessRow[]
}

export interface ProcessDetail {
  pid: string
  name: string | null
  status: string
  initial_call: string
  current_function: string
  stacktrace: { mfa: string; location: string | null }[]
  message_queue_len: number
  messages: string[] | 'truncated'
  links: string[]
  monitors: string[]
  monitored_by: string[]
  trap_exit: boolean
  priority: string
  group_leader: string
  reductions: number
  memory: number
  total_heap_size: number
  heap_size: number
  stack_size: number
  garbage_collection: { key: string; value: string }[]
  dictionary: { key: string; value: string }[]
  word_size: number
}

export interface AppInfo {
  name: string
  description: string
  vsn: string
  running: boolean
}

export interface SupNode {
  pid: string | null
  id: string
  name: string | null
  type: 'supervisor' | 'worker'
  module: string | null
  status?: string
  error?: string
  hidden: number
  children: SupNode[]
}

export interface AppTree {
  master: string | null
  root: SupNode | null
}

export interface PortRow {
  id: string
  name: string
  registered_name: string | null
  connected: string | null
  os_pid: number | null
  input: number
  output: number
  queue_size: number
  memory: number
  inet: boolean
}

export interface InetRow extends PortRow {
  local: string | null
  remote: string | null
  protocol: string
  stats: { recv_oct?: number; send_oct?: number; recv_cnt?: number; send_cnt?: number }
}

export interface PortDetail extends PortRow {
  links: string[]
  monitors: string[]
  parallelism: boolean
  locking: string | null
  local?: string | null
  remote?: string | null
  protocol?: string
  stats?: Record<string, number>
}

export interface SocketRow {
  id: string
  domain: string | null
  type: string | null
  protocol: string | null
  owner: string | null
  rstates: string[]
  wstates: string[]
  local: string | null
  remote: string | null
  read_bytes: number
  write_bytes: number
  counters: Record<string, number>
}

export interface EtsTable {
  id: string
  name: string
  named: boolean
  type: string
  size: number
  memory: number
  owner: string | null
  owner_name: string | null
  protection: string
  keypos: number
  compressed: boolean
  read_concurrency: boolean
  write_concurrency: string
  system: boolean
}

export interface MnesiaTable {
  id: string
  name: string
  storage: string
  type: string
  size: number
  memory: number
  record_name: string
  attributes: string[]
  where_to_read: string
}

export interface TableRows {
  rows: string[][]
  // Opaque key of each row, for table.object (older agents: absent).
  keys?: (string | null)[]
  keypos: number
  columns: number
  total: number
  scanned: number
  complete: boolean
  attributes?: string[]
}

export interface AllocatorRow {
  type: string
  instances: number
  blocks: number
  carriers: number
  carriers_max: number
  mbcs_blocks: number
  mbcs_carriers: number
  sbcs_blocks: number
  sbcs_carriers: number
}

export interface AllocInfo {
  allocators: AllocatorRow[]
  memory_total: number
}

export interface DistConnection {
  node: string
  hidden: boolean
  input: number | null
  output: number | null
}

export interface ClusterInfo {
  tool: string
  nodes: { node: string; connections: DistConnection[]; error: string | null }[]
}

export interface SavedCookie {
  id: string
  label: string
  hint: string
  last_used: number
}

export interface DiscoveredNode {
  name: string
  port: number
  node: string
}

export interface Discovery {
  host: string
  default: string
  hosts: string[]
  epmd: boolean
  nodes: DiscoveredNode[]
}

export type TraceCategory = 'business' | 'system' | 'network'

export interface TraceEvent {
  seq: number
  // microseconds since the epoch, on the observed node's clock
  t: number
  pid: string
  dir: 'in' | 'out'
  // sent to a process that no longer exists
  dead: boolean
  cat: TraceCategory
  kind: string
  peer: string | null
  peer_name: string | null
  // reference shared by a gen call and its reply
  ref: string | null
  summary: string
  text: string
}

export interface TraceProcess {
  pid: string
  name: string | null
}

export interface TraceState {
  status: 'running' | 'stopped' | 'none'
  id?: number
  reason?: string | null
  count?: number
  dropped?: number
  started?: number
  limits?: { max_events: number; max_seconds: number; max_rate: number }
  processes?: TraceProcess[]
  events?: TraceEvent[]
}

export interface TraceStart {
  id: number
  processes: TraceProcess[]
  refused: { target: string; reason: string }[]
  limits: { max_events: number; max_seconds: number; max_rate: number }
}

// gen call statistics of one (process, direction, request kind).
export interface TraceStatsRow {
  row: number
  pid: string
  // in: calls the process served; out: calls it made
  dir: 'in' | 'out'
  // a tuple's first element or the atom; null for the two groups below
  kind: string | null
  group: 'named' | 'other' | 'overflow'
  calls: number
  answered: number
  pending: number
  unanswered: number
  // microseconds; null without any answered call
  avg: number | null
  p95: number | null
  max: number | null
  // only with details: one entry per non-empty bucket, in microseconds
  hist?: { low: number; high: number; count: number }[]
  slowest?: { latency: number; t: number; peer: string | null; summary: string }[]
}

export interface TraceStats {
  status: 'running' | 'stopped' | 'none'
  id?: number
  kinds?: number
  max_kinds?: number
  rows: TraceStatsRow[]
}

// A trace saved to a file, opened later without a node.
export interface SavedTrace {
  format: 'eobserver-trace'
  version: 1
  node: string | null
  saved_at: number
  state: TraceState
  events: TraceEvent[]
  stats: TraceStats | null
}

export type DiagLevel ='ok' | 'warn' | 'crit' | 'skip'

export interface DiagItem {
  pid?: string
  name?: string | null
  initial_call?: string
  current_function?: string | null
  table?: string
  owner?: string | null
  node?: string
  value: number | null
}

export interface DiagCheck {
  id: string
  level: DiagLevel
  value: number | null
  warn: number | null
  crit: number | null
  items: DiagItem[]
  [extra: string]: unknown
}

export interface DiagReport {
  checks: DiagCheck[]
  memory_total: number
  process_count: number
  took_ms: number
}

export interface WindowItem {
  pid: string
  name: string | null
  initial_call: string
  current_function: string | null
  value: number
  reductions: number
  memory: number
  message_queue_len: number
  new: boolean
  alive: boolean
}

export interface WindowReport {
  seconds: number
  process_count: number
  created: number
  exited: number
  reductions: WindowItem[]
  memory: WindowItem[]
  message_queue_len: WindowItem[]
}

export type LogLevel = 'emergency' | 'alert' | 'critical' | 'error' | 'warning' | 'notice' | 'info' | 'debug'

export interface LogLine {
  seq: number
  t: number
  level: LogLevel
  module: string | null
  pid: string | null
  text: string
}

export interface StackFrame {
  mfa: string
  location: string | null
}

// Crashes of one process (registered name or initial call; null for
// plain spawned processes) with the same reason.
export interface CrashGroup {
  id: number
  who: string | null
  pid: string | null
  class: string
  reason: string
  text: string
  stack: StackFrame[]
  count: number
  first: number
  last: number
}

// Terminations and restarts of one child of one supervisor.
export interface RestartGroup {
  id: number
  supervisor: string
  child: string
  count: number
  failed_starts: number
  gave_up: boolean
  restart_type: string | null
  context: string
  reason: string
  pid: string | null
  last: number
  times: number[]
}

export interface LogsData {
  id: number
  reset: boolean
  status: 'running' | 'stopped'
  reason: string | null
  started: number
  now: number
  primary_level: string | null
  received: number
  lost: number
  dropped: number
  limited: number
  collector_restarts: number
  logs: LogLine[]
  crashes: CrashGroup[]
  restarts: RestartGroup[]
}
