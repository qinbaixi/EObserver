// Crash dump viewer requests (dump.* over the WebSocket, see
// docs/crashdump-contract.md). In `npm run dev` the page can run against a
// local mock instead of the backend: open it with ?dumpmock in the URL. The
// mock is only reachable behind import.meta.env.DEV, so production builds
// drop it.
import { client } from './ws'

/* eslint-disable @typescript-eslint/no-explicit-any */
type Json = any

export type DumpStatus = 'scanning' | 'ready' | 'failed' | 'cancelled'

export interface DumpInfo {
  id: string
  path: string
  size: number
  status: DumpStatus
  scanned: number
  truncated: boolean
  last_tag: string | null
  skipped: number
  // Only on dump_progress events.
  rate?: number
  eta?: number | null
  error?: string | null
}

export interface DumpTerm {
  text: string
  more: string | null
  size?: number
}

export type ColumnType = 'text' | 'int' | 'bytes' | 'words' | 'pid' | 'port' | 'term' | 'ms' | 'bool'

export interface DumpColumn {
  key: string
  type: ColumnType
  sortable: boolean
}

export type DumpRow = Record<string, Json>

export interface DumpQueryResult {
  total: number
  columns: DumpColumn[]
  // Objects keyed by column, or arrays in column order (both accepted).
  rows: (DumpRow | Json[])[]
}

export interface DumpTarget { kind: string; key: string }

export interface DumpFinding {
  level: 'critical' | 'warning' | 'info'
  code: string
  params: Record<string, Json>
  target: DumpTarget | null
}

export interface DumpOverview {
  file: DumpInfo
  general: Record<string, Json> & {
    slogan?: string
    node?: string
    time?: string
    system_version?: string
    compiled?: string
    taints?: string
    calling_thread?: string
  }
  reason: { code: string; params: Record<string, Json> } | null
  counts: Partial<Record<'processes' | 'ports' | 'ets' | 'timers' | 'funs' | 'modules' | 'atoms' | 'nodes', number | null>>
  limits: Partial<Record<'processes' | 'ports' | 'atoms' | 'ets', number | null>>
  memory: Partial<Record<'total' | 'processes' | 'processes_used' | 'system' | 'atom' | 'atom_used' | 'binary' | 'code' | 'ets', number | null>> | null
  findings: DumpFinding[]
  top: { memory: DumpRow[]; mql: DumpRow[] } | null
}

export interface DumpProcess {
  summary: DumpRow
  info: { key: string; value: Json; type?: string }[]
  parent: string | null
  links: string[]
  monitors: string[]
  monitored_by: string[]
  parts: { messages: number; dictionary: number; stack: number; heap: boolean }
  // garbing | no_heap | truncated
  notes?: string[]
}

// var slots may carry the value as a Term (with expand).
export interface StackItem { addr: string; kind: 'frame' | 'return' | 'catch' | 'var'; text: string; term?: DumpTerm }
export interface DictItem { key: DumpTerm; value: DumpTerm }

export interface DumpDetail {
  title: string
  fields: { key: string; value: Json }[]
  terms?: { key: string; value: DumpTerm }[] | Record<string, DumpTerm>
  // node: distribution links / monitors as {local, remote} pairs
  links?: { local: string; remote: string }[]
  monitors?: { local: string; remote: string }[]
  monitored_by?: { local: string; remote: string }[]
  // allocator: one entry per instance
  instances?: { name: string; fields: { key: string; value: Json }[] }[]
  // scheduler: the stack lines
  stack?: string[]
}

export interface SearchHit { kind: string; key: string; label: string }

export interface BrowseEntry { name: string; path: string; dir: boolean; size: number | null; mtime: number | null; dump: boolean }
export interface BrowseRoot { name: string; path: string; kind?: 'home' | 'cwd' | 'root' | 'drive' | string }
export interface BrowseResult {
  path: string
  parent: string | null
  sep: string
  // Plain paths or {name, path, kind}.
  roots: (string | BrowseRoot)[]
  entries: BrowseEntry[]
  truncated?: boolean
}
export interface RecentFile { path: string; size: number; mtime: number; opened: number }

export const dumpMock = import.meta.env.DEV && new URLSearchParams(location.search).has('dumpmock')

// Requests may read large sections of a big file, so they get longer than
// the usual 20 s.
export async function dumpRequest<T = Json>(method: string, params: Json = {}, timeout = 60000): Promise<T> {
  if (import.meta.env.DEV && dumpMock) {
    const m = await import('./dumpMock')
    return m.mockRequest(method, params) as Promise<T>
  }
  return client.request<T>(method, params, timeout)
}

export function onDumpProgress(fn: (info: DumpInfo) => void): () => void {
  if (import.meta.env.DEV && dumpMock) {
    let off = () => {}
    let cancelled = false
    void import('./dumpMock').then((m) => { if (!cancelled) off = m.mockOn('dump_progress', fn) })
    return () => { cancelled = true; off() }
  }
  return client.on('dump_progress', fn)
}

// Calls fn when the backend socket (re)opens; the mock is always open.
export function onSocketOpen(fn: () => void): () => void {
  if (import.meta.env.DEV && dumpMock) {
    queueMicrotask(fn)
    return () => {}
  }
  if (client.state.value === 'open') queueMicrotask(fn)
  return client.on('socket_open', fn)
}

// Row objects for both row shapes of dump.query.
export function rowObjects(r: DumpQueryResult): DumpRow[] {
  return r.rows.map((row) => {
    if (!Array.isArray(row)) return row
    const o: DumpRow = {}
    r.columns.forEach((c, i) => { o[c.key] = row[i] })
    return o
  })
}

export const isTerm = (v: Json): v is DumpTerm =>
  v !== null && typeof v === 'object' && typeof v.text === 'string'

// Backend times are POSIX seconds; accept milliseconds too.
export const toMs = (t: number) => (t < 1e12 ? t * 1000 : t)

export function basename(p: string): string {
  const parts = p.split(/[\\/]/).filter(Boolean)
  return parts[parts.length - 1] ?? p
}
