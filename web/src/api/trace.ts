// Labels for the message trace, in the current UI language.
import { i18n } from '../i18n'
import type { TraceEvent } from './types'

const { t, te } = i18n.global

// Looks up procs.trace.<group>.<id>; undefined when there is no text.
// Ids like $socket are stored without the $.
function lookup(group: string, id: string): string | undefined {
  const key = `procs.trace.${group}.${id.replace(/^\$/, '')}`
  return te(key) ? t(key) : undefined
}

export const kindLabel = (kind: string): string => lookup('kind', kind) ?? kind
export const kindTip = (kind: string): string | undefined => lookup('kind_tip', kind)
// The BEAM Book card behind a kind of traced message.
export function kindCard(kind: string): string | undefined {
  if (kind === 'call' || kind === 'reply') return 'call_trick'
  if (kind === 'exit' || kind === 'down') return 'exits_monitors'
  if (kind === 'io') return 'group_leader'
  if (kind === 'timer') return 'timers'
  if (kind === 'node') return 'node'
  if (kind === 'code') return 'code'
  if (kind === 'cast' || kind === 'info') return 'message_passing'
  if (/^(tcp|udp|ssl)/.test(kind)) return 'sockets'
  return undefined
}
export const categoryLabel = (cat: string): string => lookup('category', cat) ?? cat
export const stopReason = (reason: string): string =>
  lookup('stop_reason', reason) ?? t('procs.trace.stopped_with', { reason })
export const refusedReason = (reason: string): string => lookup('refused', reason) ?? reason

export function formatTime(us: number): string {
  const d = new Date(Math.floor(us / 1000))
  const pad = (n: number, w = 2) => String(n).padStart(w, '0')
  return `${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}.${pad(d.getMilliseconds(), 3)}`
}

export function formatLatency(us: number): string {
  if (us < 1000) return `${us} µs`
  if (us < 1000000) return `${(us / 1000).toFixed(us < 10000 ? 2 : 1)} ms`
  return `${(us / 1000000).toFixed(2)} s`
}

export function peerText(e: TraceEvent): string {
  if (e.peer_name && e.peer && e.peer.startsWith('<')) return `${e.peer_name} ${e.peer}`
  return e.peer_name ?? e.peer ?? ''
}

export function eventLine(e: TraceEvent, processName: (pid: string) => string): string {
  const dir = t(e.dir === 'in' ? 'procs.trace.received' : 'procs.trace.sent')
  const peer = peerText(e)
  return `${formatTime(e.t)} ${processName(e.pid)} ${dir} ${categoryLabel(e.cat)}/${kindLabel(e.kind)}`
    + `${peer ? ` ${t(e.dir === 'in' ? 'procs.trace.from' : 'procs.trace.to')} ${peer}` : ''}: ${e.text.replace(/\s+/g, ' ')}`
}
