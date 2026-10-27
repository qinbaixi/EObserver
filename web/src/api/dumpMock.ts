// Development-only stand-in for the dump.* backend methods, so the crash
// dump pages can be built and screenshot without the Erlang side. Loaded
// only from api/dump.ts behind import.meta.env.DEV and ?dumpmock.
// Shapes follow docs/crashdump-contract.md.
import type {
  BrowseResult, DumpColumn, DumpInfo, DumpOverview, DumpProcess, DumpQueryResult, DumpRow, DumpTerm, SearchHit,
} from './dump'

/* eslint-disable @typescript-eslint/no-explicit-any */
type Json = any

const listeners = new Map<string, Set<(d: Json) => void>>()
export function mockOn(event: string, fn: (d: Json) => void): () => void {
  if (!listeners.has(event)) listeners.set(event, new Set())
  listeners.get(event)!.add(fn)
  return () => listeners.get(event)?.delete(fn)
}
const emit = (event: string, d: Json) => listeners.get(event)?.forEach((fn) => fn(d))

// Deterministic data: the same screens every run.
function rng(seed: number) {
  let s = seed >>> 0
  return () => {
    s = (s * 1664525 + 1013904223) >>> 0
    return s / 4294967296
  }
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms))

// --- open dumps -------------------------------------------------------------

interface MockDump { info: DumpInfo; started: number; duration: number; timer?: number }
const dumps = new Map<string, MockDump>()
let nextId = 1
// ?dumpmock=slow keeps the scan running for a minute (progress screenshots).
const slow = new URLSearchParams(location.search).get('dumpmock') === 'slow'

function scanSize(path: string) {
  if (path.includes('small')) return 48 * 1024 * 1024
  return 1_932_735_283
}

function startScan(d: MockDump) {
  const tick = () => {
    const el = Date.now() - d.started
    const frac = Math.min(1, el / d.duration)
    const truncated = d.info.path.includes('truncated')
    d.info.scanned = Math.floor(d.info.size * frac)
    const rate = d.info.size / (d.duration / 1000)
    if (frac >= 1) {
      d.info.status = 'ready'
      d.info.truncated = truncated
      d.info.last_tag = truncated ? 'proc_heap' : 'end'
      d.info.skipped = truncated ? 1 : 0
      emit('dump_progress', { ...d.info, rate, eta: 0 })
      return
    }
    emit('dump_progress', { ...d.info, rate, eta: (d.info.size - d.info.scanned) / rate })
    d.timer = window.setTimeout(tick, 250)
  }
  tick()
}

// --- generated content ------------------------------------------------------

const MODULES = ['gen_server', 'gen_statem', 'gen_event', 'proc_lib', 'supervisor', 'ranch_conns', 'cowboy_stream_h',
  'my_app_session', 'my_app_cache', 'my_app_worker', 'ssl_gen_statem', 'tls_sender', 'inet_tcp_dist', 'logger_olp',
  'erl_prim_loader', 'application_master', 'code_server', 'global', 'pg', 'ets_owner', 'kafka_producer', 'ecto_pool']
const NAMES = ['init', 'erts_code_purger', 'logger', 'code_server', 'application_controller', 'kernel_sup',
  'user', 'global_name_server', 'inet_db', 'file_server_2', 'my_app_sup', 'my_app_cache', 'session_registry',
  'kafka_client', 'ranch_server', 'ssl_manager', 'pg', 'net_kernel', 'auth', 'timer_server']
const STATES = ['Waiting', 'Waiting', 'Waiting', 'Waiting', 'Waiting', 'Running', 'Runnable', 'Garbing', 'Exiting', 'Suspended']

interface Kind { columns: DumpColumn[]; rows: () => DumpRow[]; sort: string }
const col = (key: string, type: DumpColumn['type'], sortable = true): DumpColumn => ({ key, type, sortable })
const memo = <T>(f: () => T) => { let v: T | undefined; return () => (v ??= f()) }

const procs = memo(() => {
  const r = rng(7)
  const rows: DumpRow[] = []
  for (let i = 0; i < 4823; i++) {
    const pid = `<0.${i === 0 ? 0 : i * 3 + 40}.0>`
    const named = i < NAMES.length ? NAMES[i] : r() < 0.04 ? `worker_${i}` : null
    const mod = MODULES[Math.floor(r() * MODULES.length)]
    let memory = Math.floor(2700 + r() ** 6 * 4e6)
    let mql = r() < 0.92 ? 0 : Math.floor(r() ** 3 * 800)
    let state = STATES[Math.floor(r() * STATES.length)]
    if (i === 13) { memory = 2_147_520_000; state = 'Garbing'; mql = 3 }
    if (i === 14) { mql = 1_284_331; memory = 812_000_000 }
    if (i === 77) { memory = 340_000_000 }
    rows.push({
      pid, name: named, state, memory, mq: mql,
      reds: Math.floor(r() ** 2 * 5e8), heap: Math.floor(memory * 0.8),
      bin: Math.floor(r() * memory / 16), current: `${mod}:loop/3`,
      init: i < 3 ? 'otp_ring0:start/2' : `proc_lib:init_p/5`,
      links: Math.floor(r() * 4),
    })
  }
  return rows
})

const word = (r: () => number) => ['users', 'sessions', 'cache', 'routes', 'tokens', 'acl', 'stats', 'jobs'][Math.floor(r() * 8)]

const kinds: Record<string, Kind> = {
  processes: {
    columns: [col('pid', 'pid'), col('name', 'text'), col('state', 'text'), col('init', 'text'), col('current', 'text'),
      col('reds', 'int'), col('memory', 'bytes'), col('mq', 'int'), col('heap', 'bytes'), col('bin', 'bytes')],
    rows: procs, sort: 'memory',
  },
  ports: {
    columns: [col('id', 'port'), col('name', 'text'), col('connected', 'pid'), col('controls', 'text'),
      col('input', 'bytes'), col('output', 'bytes'), col('queue', 'bytes')],
    rows: memo(() => { const r = rng(3); return Array.from({ length: 62 }, (_, i) => ({
      id: `#Port<0.${i + 1}>`, name: i < 3 ? 'forker' : i % 5 === 0 ? 'efile' : 'tcp_inet',
      connected: procs()[Math.floor(r() * 300)].pid, controls: i % 5 === 0 ? '' : `${Math.floor(r() * 400)}`,
      input: Math.floor(r() * 9e7), output: Math.floor(r() * 9e7), queue: i === 9 ? 48_000_000 : 0 })) }),
    sort: 'id',
  },
  ets: {
    columns: [col('table', 'text'), col('name', 'text'), col('owner', 'pid'), col('type', 'text'),
      col('objects', 'int'), col('memory', 'words'), col('buckets', 'int')],
    rows: memo(() => { const r = rng(5); return Array.from({ length: 138 }, (_, i) => ({
      table: `#Ref<0.${i}.${1000 + i}>`, name: i === 4 ? 'session_cache' : `${word(r)}_${i}`,
      owner: procs()[Math.floor(r() * 200)].pid, type: ['set', 'ordered_set', 'bag'][i % 3],
      objects: i === 4 ? 9_120_334 : Math.floor(r() ** 4 * 2e5),
      memory: i === 4 ? 61_221_009 : Math.floor(r() ** 4 * 3e6), buckets: 256 })) }),
    sort: 'memory',
  },
  timers: {
    columns: [col('owner', 'pid'), col('message', 'term', false), col('time_left', 'ms')],
    rows: memo(() => { const r = rng(9); return Array.from({ length: 213 }, () => ({
      owner: procs()[Math.floor(r() * 4000)].pid, message: { text: '{timeout,flush}', more: null },
      time_left: Math.floor(r() * 60000) })) }),
    sort: 'time_left',
  },
  schedulers: {
    columns: [col('id', 'int'), col('type', 'text'), col('sleep_info', 'text', false), col('current_process', 'pid'),
      col('run_queue', 'int'), col('current_port', 'port')],
    rows: memo(() => Array.from({ length: 12 }, (_, i) => ({
      id: i + 1, type: i < 8 ? 'Normal' : i < 10 ? 'Dirty CPU' : 'Dirty IO',
      sleep_info: i === 0 ? 'Running' : 'Sleeping | TSE_SLEEPING', current_process: i === 0 ? '<0.79.0>' : null,
      run_queue: i === 0 ? 3 : 0, current_port: null }))),
    sort: 'id',
  },
  nodes: {
    columns: [col('name', 'text'), col('type', 'text'), col('channel', 'int'), col('controller', 'port'), col('creation', 'int')],
    rows: memo(() => ['api@10.0.0.4', 'api@10.0.0.5', 'db@10.0.0.9', 'worker@10.0.1.2'].map((n, i) => ({
      name: n, type: i === 3 ? 'not_connected' : 'visible', channel: i + 3, controller: `#Port<0.${i + 7}>`, creation: 1698000000 + i }))),
    sort: 'name',
  },
  modules: {
    columns: [col('name', 'text'), col('current_size', 'bytes'), col('old_size', 'bytes')],
    rows: memo(() => { const r = rng(11); return Array.from({ length: 512 }, (_, i) => ({
      name: i < MODULES.length ? MODULES[i] : `mod_${word(r)}_${i}`, current_size: Math.floor(r() * 400000),
      old_size: r() < 0.03 ? Math.floor(r() * 200000) : 0 })) }),
    sort: 'name',
  },
  funs: {
    columns: [col('module', 'text'), col('uniq', 'int'), col('index', 'int'), col('address', 'text', false), col('refc', 'int')],
    rows: memo(() => { const r = rng(13); return Array.from({ length: 2210 }, (_, i) => ({
      module: MODULES[i % MODULES.length], uniq: Math.floor(r() * 1e8), index: i % 17,
      address: `0x00007f${Math.floor(r() * 1e9).toString(16)}`, refc: Math.floor(r() * 30) })) }),
    sort: 'module',
  },
  atoms: {
    columns: [col('index', 'int'), col('text', 'text')],
    rows: memo(() => Array.from({ length: 41290 }, (_, i) => ({ index: i, text: i < MODULES.length ? MODULES[i] : `atom_${i.toString(36)}` }))),
    sort: 'index',
  },
  persistent_terms: {
    columns: [col('key', 'term', false), col('value', 'term', false)],
    rows: memo(() => Array.from({ length: 24 }, (_, i) => ({
      key: { text: `{my_app, config_${i}}`, more: null },
      value: { text: `#{pool_size => ${i * 4}, timeout => 5000, hosts => [<<"10.0.0.${i}">>]}`, more: i === 2 ? 'tok-pt-2' : null } }))),
    sort: 'key',
  },
  allocators: {
    columns: [col('name', 'text'), col('blocks_size', 'bytes'), col('carriers_size', 'bytes'), col('mbcs_carriers_size', 'bytes'),
      col('sbcs_carriers_size', 'bytes'), col('blocks', 'int')],
    rows: memo(() => ['eheap_alloc', 'binary_alloc', 'ets_alloc', 'll_alloc', 'driver_alloc', 'fix_alloc', 'std_alloc', 'sl_alloc', 'temp_alloc'].map((n, i) => ({
      name: n, blocks_size: [3.4e9, 1.1e9, 5.1e8, 1.2e8, 3.3e7, 2e6, 1.5e7, 4e5, 1e5][i],
      carriers_size: [3.9e9, 1.6e9, 5.6e8, 1.3e8, 4.2e7, 4e6, 2e7, 1e6, 1e6][i],
      mbcs_carriers_size: [1.2e9, 7e8, 5e8, 1.3e8, 4e7, 4e6, 2e7, 1e6, 1e6][i],
      sbcs_carriers_size: [2.7e9, 9e8, 6e7, 0, 2e6, 0, 0, 0, 0][i], blocks: [92000, 300211, 81233, 5000, 3120, 900, 1200, 40, 9][i] }))),
    sort: 'carriers_size',
  },
  memory: {
    columns: [col('key', 'text'), col('value', 'bytes')],
    rows: memo(() => Object.entries(MEM).map(([key, value]) => ({ key, value }))),
    sort: 'value',
  },
  hash_tables: {
    columns: [col('name', 'text'), col('size', 'int'), col('used', 'int'), col('objs', 'int'), col('depth', 'int')],
    rows: memo(() => ['atom_tab', 'module_code', 'export_list', 'secure_ref', 'fun_table', 'node_table', 'dist_table'].map((n, i) => ({
      name: n, size: 2 ** (10 + i), used: 2 ** (9 + i), objs: 3 * 2 ** (9 + i), depth: 3 + (i % 3) }))),
    sort: 'name',
  },
  index_tables: {
    columns: [col('name', 'text'), col('size', 'int'), col('limit', 'int'), col('entries', 'int')],
    rows: memo(() => [{ name: 'atom_tab', size: 41290, limit: 1048576, entries: 41290 },
      { name: 'module_code', size: 512, limit: 65536, entries: 512 },
      { name: 'export_list', size: 15032, limit: 524288, entries: 15032 }]),
    sort: 'name',
  },
  internal_tables: {
    columns: [col('name', 'text'), col('buckets', 'int'), col('chain_length', 'int'), col('memory', 'bytes')],
    rows: memo(() => ['ets_meta', 'fun_entries', 'code_ix', 'port_tab', 'proc_tab', 'monitors'].map((n, i) => ({
      name: n, buckets: 256 << i, chain_length: (i % 4) + 1, memory: 4096 * (i + 1) ** 3 }))),
    sort: 'name',
  },
}

const MEM = {
  total: 6_442_450_944, processes: 4_102_220_800, processes_used: 4_101_990_112, system: 2_340_230_144,
  atom: 1_598_721, atom_used: 1_582_111, binary: 1_210_008_112, code: 48_221_909, ets: 489_768_072,
}

const termText = (n: number) => `{call,{<0.${200 + n}.0>,#Ref<0.1823.442.${n}>},{get,session,<<"u-${10000 + n}">>}}`

function overview(d: MockDump): DumpOverview {
  const ready = d.info.status === 'ready'
  const frac = d.info.size ? d.info.scanned / d.info.size : 0
  const partial = (n: number) => (ready ? n : Math.floor(n * frac))
  const top = [...procs()].sort((a, b) => b.memory - a.memory).slice(0, 5)
  const mql = [...procs()].sort((a, b) => b.mq - a.mq).slice(0, 5)
  const findings: DumpOverview['findings'] = [
    { level: 'critical', code: 'top_memory_process', params: { pid: '<0.79.0>', name: null, memory: 2_147_520_000, share: 33.3 }, target: { kind: 'process', key: '<0.79.0>' } },
    { level: 'critical', code: 'long_message_queue', params: { pid: '<0.82.0>', name: 'session_registry', len: 1_284_331 }, target: { kind: 'process', key: '<0.82.0>' } },
    { level: 'warning', code: 'binary_heavy', params: { binary: MEM.binary, total: MEM.total, share: 18.8 }, target: { kind: 'memory', key: 'binary' } },
    { level: 'warning', code: 'big_ets', params: { name: 'session_cache', table: '#Ref<0.4.1004>', bytes: 61_221_009 * 8, objects: 9_120_334 }, target: { kind: 'ets', key: '#Ref<0.4.1004>' } },
    { level: 'info', code: 'many_processes_in_state', params: { state: 'Garbing', count: 431, total: 4823 }, target: null },
    { level: 'critical', code: 'garbage_collecting', params: { pid: '<0.79.0>', name: null, memory: 2_147_520_000 }, target: { kind: 'process', key: '<0.79.0>' } },
    { level: 'info', code: 'calling_process', params: { pid: '<0.79.0>', scheduler: 'scheduler:3', state: 'Garbing' }, target: { kind: 'process', key: '<0.79.0>' } },
  ]
  if (d.info.path.includes('truncated') && ready) {
    findings.unshift({ level: 'critical', code: 'truncated', params: { at: d.info.size, last_tag: 'proc_heap' }, target: null })
  }
  const oom = !d.info.path.includes('halt')
  return {
    file: d.info,
    general: {
      slogan: oom ? 'eheap_alloc: Cannot allocate 2147520000 bytes of memory (of type "heap").' : 'Kernel pid terminated (application_controller) ({application_terminated,my_app,shutdown})',
      node: 'api@10.0.0.4', time: 'Tue Oct 27 03:14:07 2026',
      system_version: 'Erlang/OTP 26 [erts-14.2.5.4] [source] [64-bit] [smp:8:8] [ds:8:8:10] [async-threads:1] [jit:ns]',
      compiled: 'Mon Sep 30 10:00:00 2026', taints: '', calling_thread: 'scheduler:3',
      atoms: 41290,
    },
    reason: oom ? { code: 'oom', params: { allocator: 'eheap_alloc', size: 2147520000, type: 'heap' } }
      : { code: 'kernel_pid_terminated', params: { app: 'my_app', reason: 'shutdown' } },
    counts: { processes: partial(4823), ports: partial(62), ets: partial(138), timers: partial(213), funs: partial(2210),
      modules: partial(512), atoms: ready || frac > 0.95 ? 41290 : null, nodes: partial(4) },
    limits: { processes: 262144, ports: 65536, atoms: 1048576, ets: null },
    memory: frac > 0.02 || ready ? MEM : null,
    findings: ready ? findings : findings.slice(0, Math.floor(frac * 4)),
    top: { memory: top, mql },
  }
}

function query(p: Json): DumpQueryResult {
  const k = kinds[p.kind]
  if (!k) throw new Error('bad_kind')
  let rows = k.rows()
  const f = String(p.filter ?? '').toLowerCase()
  if (f) {
    const textCols = k.columns.filter((c) => c.type !== 'int' && c.type !== 'bytes' && c.type !== 'words')
    rows = rows.filter((r) => textCols.some((c) => {
      const v = r[c.key]
      return String(v && typeof v === 'object' ? v.text : v ?? '').toLowerCase().includes(f)
    }))
  }
  const sort = p.sort || k.sort
  const dir = p.order === 'asc' ? 1 : p.order === 'desc' ? -1 : (sort === k.sort && ['memory', 'carriers_size', 'value'].includes(sort) ? -1 : 1)
  rows = [...rows].sort((a, b) => {
    const x = a[sort], y = b[sort]
    if (typeof x === 'number' && typeof y === 'number') return (x - y) * dir
    return String(x ?? '').localeCompare(String(y ?? ''), 'en', { numeric: true }) * dir
  })
  const offset = Number(p.offset ?? 0)
  const limit = Number(p.limit ?? 50)
  return { total: rows.length, columns: k.columns, rows: rows.slice(offset, offset + limit) }
}

function process(pid: string): DumpProcess {
  const row = procs().find((r) => r.pid === pid)
  if (!row) throw new Error('not_found')
  const idx = procs().indexOf(row)
  const r = rng(idx + 1)
  const other = () => procs()[Math.floor(r() * 400)].pid
  return {
    summary: row,
    info: [
      { key: 'state', value: row.state },
      { key: 'name', value: row.name },
      { key: 'init', value: row.init },
      { key: 'parent', value: '<0.70.0>', type: 'pid' },
      { key: 'current', value: row.current },
      { key: 'mq', value: row.mq, type: 'int' },
      { key: 'reds', value: row.reds, type: 'int' },
      { key: 'memory', value: row.memory, type: 'bytes' },
      { key: 'stack_heap', value: row.heap, type: 'bytes' },
      { key: 'old_heap', value: row.bin, type: 'bytes' },
      { key: 'heap_unused', value: 14560, type: 'bytes' },
      { key: 'old_heap_unused', value: 0, type: 'bytes' },
      { key: 'bin_vheap', value: 249_768, type: 'bytes' },
      { key: 'heap_frags', value: 2, type: 'int' },
      { key: 'program_counter', value: '0x00007f3a2c1b40a8 (gen_server:loop/7 + 288)' },
      
      
    ],
    parent: '<0.70.0>',
    links: [other(), other(), '#Port<0.12>'],
    monitors: row.links > 1 ? [other()] : [],
    monitored_by: [other(), other()],
    parts: { messages: row.mq, dictionary: 6, stack: 23, heap: true },
    notes: row.state === 'Garbing' ? ['garbing'] : [],
  }
}

function processPart(p: Json): { total: number; items: Json[] } {
  const proc = process(p.pid)
  const offset = Number(p.offset ?? 0)
  const limit = Number(p.limit ?? 50)
  if (p.part === 'messages') {
    const total = proc.parts.messages
    const n = Math.max(0, Math.min(limit, total - offset))
    return { total, items: Array.from({ length: n }, (_, i): DumpTerm => ({
      text: termText(offset + i), more: (offset + i) % 7 === 0 ? `tok-msg-${offset + i}` : null })) }
  }
  if (p.part === 'dictionary') {
    const items = [
      ['$initial_call', '{my_app_session,init,1}'], ['$ancestors', '[my_app_sup,<0.70.0>]'],
      ['rand_seed', '{#{bits => 58,jump => #Fun<rand.3.34006561>,next => #Fun<rand.0.34006561>},[...]}'],
      ['logger_metadata', '#{request_id => <<"9f1c2d">>,user => <<"u-10042">>}'],
      ['session_count', '18232'], ['{cache,hits}', '99120331'],
    ].map(([k, v], i) => ({ key: { text: k, more: null }, value: { text: v, more: i === 2 ? 'tok-dict-2' : null } }))
    return { total: items.length, items: items.slice(offset, offset + limit) }
  }
  if (p.part === 'stack') {
    const items = Array.from({ length: 23 }, (_, i) => {
      const kind = i % 6 === 0 ? 'return' : i % 11 === 5 ? 'catch' : i % 3 === 0 ? 'frame' : 'var'
      return {
        addr: `0x00007f3a2d${(0x1000 + i * 8).toString(16)}`, kind,
        text: kind === 'return' ? `Return addr 0x00007f3a2c1b40a8 (gen_server:loop/7 + 288)`
          : kind === 'catch' ? 'Catch 0x00007f3a2c1b4210 (gen_server:try_handle_call/4 + 192)'
          : kind === 'frame' ? `y(${i % 4})` : `[<<"u-${10000 + i}">>,{session,<0.${300 + i}.0>,1698400000}]`,
      }
    })
    return { total: items.length, items: items.slice(offset, offset + limit) }
  }
  throw new Error('bad_part')
}

function detail(p: Json) {
  const k = String(p.kind)
  const key = String(p.key)
  const src: Record<string, [string, string]> = { port: ['ports', 'id'], ets: ['ets', 'table'], node: ['nodes', 'channel'], module: ['modules', 'name'] }
  const s = src[k]
  if (!s) throw new Error('bad_kind')
  const row = kinds[s[0]].rows().find((r) => String(r[s[1]]) === key || r.name === key)
  if (!row) throw new Error('not_found')
  return {
    title: k === 'ets' ? `${row.name} (${row.table})` : String(row.name ?? row[s[1]]),
    fields: Object.entries(row).filter(([, v]) => typeof v !== 'object' || v === null).map(([key, value]) => ({ key, value })),
    terms: k === 'module' ? [{ key: 'current_attrib', value: { text: '[{vsn,[1928374650192837465]}]', more: null } },
      { key: 'current_comp', value: { text: '[{version,"8.3.2"},{options,[debug_info]}]', more: 'tok-mod' } }] : undefined,
  }
}

function search(q: string): SearchHit[] {
  const s = q.toLowerCase()
  const out: SearchHit[] = []
  for (const r of procs()) {
    if (out.length >= 20) break
    if (r.pid.includes(s) || (r.name && r.name.toLowerCase().includes(s)) || r.current.includes(s)) {
      out.push({ kind: 'process', key: r.pid, label: `${r.pid} ${r.name ?? r.current}` })
    }
  }
  for (const r of kinds.ets.rows()) if (out.length < 35 && String(r.name).includes(s)) out.push({ kind: 'ets', key: r.table, label: r.name })
  for (const r of kinds.modules.rows()) if (out.length < 45 && String(r.name).includes(s)) out.push({ kind: 'module', key: r.name, label: r.name })
  for (const r of kinds.ports.rows()) if (out.length < 50 && String(r.id).includes(s)) out.push({ kind: 'port', key: r.id, label: `${r.id} ${r.name}` })
  return out.slice(0, 50)
}

function browse(path?: string): BrowseResult {
  const p = path && path !== '/' ? path.replace(/\/$/, '') : '/home/me'
  const parent = p === '/' ? null : p.split('/').slice(0, -1).join('/') || '/'
  const now = Math.floor(Date.now() / 1000)
  const entries = p.endsWith('dumps')
    ? [
        { name: 'erl_crash.dump', path: `${p}/erl_crash.dump`, dir: false, size: 1_932_735_283, mtime: now - 3600, dump: true },
        { name: 'erl_crash-truncated.dump', path: `${p}/erl_crash-truncated.dump`, dir: false, size: 1_073_741_824, mtime: now - 86400, dump: true },
        { name: 'halt-small.dump', path: `${p}/halt-small.dump`, dir: false, size: 48 * 1024 * 1024, mtime: now - 7 * 86400, dump: true },
        { name: 'notes.txt', path: `${p}/notes.txt`, dir: false, size: 1200, mtime: now - 20 * 86400, dump: false },
      ]
    : [
        { name: 'dumps', path: `${p}/dumps`, dir: true, size: null, mtime: now - 3600, dump: false },
        { name: 'projects', path: `${p}/projects`, dir: true, size: null, mtime: now - 7200, dump: false },
        { name: '.config', path: `${p}/.config`, dir: true, size: null, mtime: now - 99e3, dump: false },
        { name: 'erl_crash.dump', path: `${p}/erl_crash.dump`, dir: false, size: 812_331_002, mtime: now - 5 * 86400, dump: true },
        { name: 'README.md', path: `${p}/README.md`, dir: false, size: 4211, mtime: now - 30 * 86400, dump: false },
      ]
  return { path: p, parent, sep: '/', roots: [{ name: '/home/me', path: '/home/me', kind: 'home' }, { name: '/srv/api', path: '/srv/api', kind: 'cwd' }, { name: '/', path: '/', kind: 'root' }], entries }
}

const nowS = () => Math.floor(Date.now() / 1000)
const recent = [
  { path: '/home/me/dumps/erl_crash.dump', size: 1_932_735_283, mtime: nowS() - 3600, opened: nowS() - 1800 },
  { path: '/srv/api/log/erl_crash-truncated.dump', size: 1_073_741_824, mtime: nowS() - 86400, opened: nowS() - 86400 },
  { path: '/home/me/dumps/halt-small.dump', size: 48 * 1024 * 1024, mtime: nowS() - 7 * 86400, opened: nowS() - 6 * 86400 },
]

export async function mockRequest(method: string, p: Json): Promise<Json> {
  await sleep(120)
  const need = () => {
    const d = dumps.get(String(p.id))
    if (!d) throw new Error('not_found')
    return d
  }
  switch (method) {
    case 'dump.browse': return browse(p.path)
    case 'dump.recent': return recent
    case 'dump.list': return [...dumps.values()].map((d) => d.info)
    case 'dump.open': {
      for (const d of dumps.values()) if (d.info.path === p.path) return { id: d.info.id }
      if (!String(p.path).includes('dump')) throw new Error('not_a_dump')
      const id = `d${nextId++}`
      const size = scanSize(String(p.path))
      const d: MockDump = {
        info: { id, path: String(p.path), size, status: 'scanning', scanned: 0, truncated: false, last_tag: null, skipped: 0 },
        started: Date.now(), duration: slow ? 60000 : size < 1e8 ? 800 : 4500,
      }
      dumps.set(id, d)
      startScan(d)
      return { id }
    }
    case 'dump.close': {
      const d = dumps.get(String(p.id))
      if (d) { clearTimeout(d.timer); dumps.delete(String(p.id)) }
      return 'ok'
    }
    case 'dump.cancel': {
      const d = need()
      clearTimeout(d.timer)
      if (d.info.status === 'scanning') d.info.status = 'cancelled'
      emit('dump_progress', { ...d.info, rate: 0, eta: null })
      return 'ok'
    }
    case 'dump.overview': return overview(need())
    case 'dump.query': need(); return query(p)
    case 'dump.process': need(); return process(String(p.pid))
    case 'dump.process_part': need(); return processPart(p)
    case 'dump.detail': need(); return detail(p)
    case 'dump.expand': need(); return { text: `${'['}${Array.from({ length: 40 }, (_, i) => `{entry,${i},<<"value-${i}">>}`).join(',')}]`, more: null }
    case 'dump.search': need(); return search(String(p.q ?? ''))
    default: throw new Error('unknown_method')
  }
}
