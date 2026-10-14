import type { LoadPoint, NodeSummary } from './types'

// The cheap part of the health check (diag.check), recomputed in the
// browser from data the overview wall already samples: limit ratios and the
// run queue. Thresholds mirror check/0 in eobs_agent.erl: limits warn at
// 70% and are critical at 90%; the run queue warns when it stays above the
// online schedulers and is critical above four times that.
export const LIMIT_WARN = 70
export const LIMIT_CRIT = 90
// "Stays above": the smallest of the last few samples (2 s apart) counts.
export const RUN_QUEUE_SAMPLES = 3

export type Level = 'ok' | 'warn' | 'crit'

export interface QuickFinding {
  id: 'process_count' | 'port_count' | 'atom_count' | 'ets_count' | 'run_queue'
  level: Level
  value: number
  limit: number
  pct: number
}

const rank: Record<Level, number> = { ok: 0, warn: 1, crit: 2 }

function limit(id: QuickFinding['id'], value: number | null | undefined,
               max: number | null | undefined): QuickFinding | null {
  if (typeof value !== 'number' || typeof max !== 'number' || max <= 0) return null
  const pct = Math.floor((value * 100) / max)
  const level: Level = pct >= LIMIT_CRIT ? 'crit' : pct >= LIMIT_WARN ? 'warn' : 'ok'
  return { id, level, value, limit: max, pct }
}

// Findings worse than ok, worst first; the process count comes from the
// newest load sample when there is one.
export function quickCheck(s: NodeSummary | null, points: LoadPoint[]): QuickFinding[] {
  if (!s) return []
  const last = points.at(-1)
  const out = [
    limit('process_count', last?.process_count ?? s.process_count, s.process_limit),
    limit('port_count', s.port_count, s.port_limit),
    limit('atom_count', s.atom_count, s.atom_limit),
    limit('ets_count', s.ets_count, s.ets_limit),
  ]
  const recent = points.slice(-RUN_QUEUE_SAMPLES)
  const sched = s.schedulers_online
  if (recent.length === RUN_QUEUE_SAMPLES && sched > 0) {
    const min = Math.min(...recent.map((p) => p.run_queue))
    const level: Level = min >= sched * 4 + 1 ? 'crit' : min >= sched + 1 ? 'warn' : 'ok'
    out.push({ id: 'run_queue', level, value: min, limit: sched, pct: 0 })
  }
  return out
    .filter((f): f is QuickFinding => f !== null && f.level !== 'ok')
    .sort((a, b) => rank[b.level] - rank[a.level])
}

export function worst(findings: QuickFinding[]): Level {
  return findings[0]?.level ?? 'ok'
}
