import { h, type VNodeChild } from 'vue'
import type { ReconProcBase } from '../../api/types'

// Chart label of a process: its registered name, else its initial call,
// followed by the pid so equal names stay apart.
export const procLabel = (p: ReconProcBase) => `${p.name ?? p.initial_call} ${p.pid}`

// Table cell of a process, as in the diagnosis tables.
export const procCell = (p: ReconProcBase, ...extra: VNodeChild[]) => h('span', null, [
  h('span', { class: 'mono pid' }, p.pid), ' ',
  p.name ? h('b', null, p.name) : h('span', { class: 'mono muted' }, p.initial_call),
  ...extra,
])

export const pct = (v: number | null | undefined, digits = 0) =>
  (v == null ? '-' : `${(v * 100).toFixed(digits)}%`)

// Large counts in charts: 12 345 678 → 12.3M.
export function compact(n: number): string {
  const a = Math.abs(n)
  if (a >= 1e9) return `${(n / 1e9).toFixed(1)}G`
  if (a >= 1e6) return `${(n / 1e6).toFixed(1)}M`
  if (a >= 1e4) return `${(n / 1e3).toFixed(1)}K`
  return Math.round(n).toLocaleString('en-US')
}
