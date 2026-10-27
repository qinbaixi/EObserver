import { h, inject, type InjectionKey, type VNodeChild } from 'vue'
import { i18n } from '../../i18n'
import { formatBytes, formatNumber, formatDuration } from '../../api/format'
import { isTerm, type ColumnType, type DumpTarget } from '../../api/dump'

// Shared by the crash dump tables, drawers and overview: labels for the
// backend's keys and rendering of typed values.

export interface DumpNav {
  open: (target: DumpTarget) => void
  wordSize: () => number
}
export const NAV: InjectionKey<DumpNav> = Symbol('dump-nav')
export const useNav = () => inject(NAV, { open: () => {}, wordSize: () => 8 })

const te = (key: string) => i18n.global.te(key) || i18n.global.te(key, 'zh')
const t = (key: string, named: Record<string, unknown> = {}) => i18n.global.t(key, named)

// crashdump.col.<key>, else the raw key.
export function colLabel(key: string): string {
  const k = `crashdump.col.${key}`
  return te(k) ? t(k) : key
}

// crashdump.info.<key>, then crashdump.col.<key>, else the raw key.
export function infoLabel(key: string): string {
  const k = `crashdump.info.${key}`
  return te(k) ? t(k) : colLabel(key)
}

export const PID_RE = /^<\d+\.\d+\.\d+>$/
export const PORT_RE = /^#Port<\d+\.\d+>$/

export function formatValue(type: ColumnType, v: unknown, wordSize = 8): string {
  if (v === null || v === undefined || v === '') return ''
  if (isTerm(v)) return v.text
  switch (type) {
    case 'int': return typeof v === 'number' ? formatNumber(v) : String(v)
    case 'bytes': return typeof v === 'number' ? formatBytes(v) : String(v)
    case 'words': return typeof v === 'number' ? formatBytes(v * wordSize) : String(v)
    case 'ms': return typeof v === 'number' ? (v < 1000 ? `${v} ms` : formatDuration(v)) : String(v)
    case 'bool': return v === true || v === 'true' ? t('crashdump.yes') : v === false || v === 'false' ? t('crashdump.no') : String(v)
    default: return String(v)
  }
}

export const isNumeric = (type: ColumnType) => type === 'int' || type === 'bytes' || type === 'words' || type === 'ms'

// A pid or port as a link to its detail.
export function refLink(text: string, nav: DumpNav): VNodeChild {
  const kind = PID_RE.test(text) ? 'process' : PORT_RE.test(text) ? 'port' : null
  if (!kind) return h('span', { class: 'mono' }, text)
  return h('a', {
    class: 'mono dump-link',
    onClick: (e: MouseEvent) => { e.stopPropagation(); nav.open({ kind, key: text }) },
  }, text)
}

export function renderCell(type: ColumnType, v: unknown, nav: DumpNav): VNodeChild {
  if (v === null || v === undefined || v === '') return h('span', { class: 'dump-muted' }, '-')
  if ((type === 'pid' || type === 'port') && typeof v === 'string') return refLink(v, nav)
  if (type === 'term' || isTerm(v)) {
    return h('span', { class: 'mono dump-term-cell', title: isTerm(v) ? v.text : String(v) }, isTerm(v) ? v.text : String(v))
  }
  if (type === 'words' && typeof v === 'number') {
    return h('span', { class: 'mono', title: `${formatNumber(v)} words` }, formatValue(type, v, nav.wordSize()))
  }
  if (type === 'text' && typeof v === 'string' && (PID_RE.test(v) || PORT_RE.test(v))) return refLink(v, nav)
  return h('span', { class: isNumeric(type) ? 'mono' : undefined }, formatValue(type, v, nav.wordSize()))
}

// Types of process / info keys whose type the backend does not send.
const BYTE_KEYS = new Set(['memory', 'bin_vheap', 'binary', 'total', 'size', 'at', 'input', 'output', 'queue', 'bytes', 'heap', 'bin', 'pid_binary', 'current_size', 'old_size'])
const WORD_KEYS = new Set(['stack_heap', 'old_heap', 'heap_unused', 'old_heap_unused', 'heap_size', 'stack_size', 'total_heap_size', 'bin_vheap_unused', 'old_bin_vheap'])
const INT_KEYS = new Set(['message_queue_len', 'mq', 'reductions', 'reds', 'count', 'len', 'length', 'used', 'limit', 'max', 'objects', 'number_of_heap_fragments', 'heap_frags'])
export function keyType(key: string): ColumnType {
  if (BYTE_KEYS.has(key)) return 'bytes'
  if (WORD_KEYS.has(key)) return 'words'
  if (INT_KEYS.has(key)) return 'int'
  return 'text'
}

// Message params formatted for display: sizes as bytes, counts grouped.
export function formatParams(params: Record<string, unknown> | null | undefined): Record<string, string> {
  const out: Record<string, string> = {}
  for (const [k, v] of Object.entries(params ?? {})) {
    if (typeof v === 'number') {
      // share: a percentage (52.3); ratio: a fraction.
      if (k === 'share') out[k] = `${v}%`
      else if (k === 'ratio') out[k] = `${(v * 100).toFixed(0)}%`
      else out[k] = formatValue(keyType(k) === 'text' ? 'int' : keyType(k), v)
    } else if (v === null || v === undefined) out[k] = ''
    else if (isTerm(v)) out[k] = v.text
    else out[k] = String(v)
  }
  return out
}
