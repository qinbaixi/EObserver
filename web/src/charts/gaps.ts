import type { LoadPoint } from '../api/types'

// Samples further apart than this are not joined by a line: the node was
// not sampled in between (it was not shown, or was disconnected).
export const GAP_MS = 12000

// One chart line from load samples, with a null inserted at every gap.
export function lineData(points: LoadPoint[], f: (p: LoadPoint) => number | null): [number, number | null][] {
  const out: [number, number | null][] = []
  let prev: number | null = null
  for (const p of points) {
    if (prev !== null && p.time - prev > GAP_MS) out.push([prev + 1, null])
    out.push([p.time, f(p)])
    prev = p.time
  }
  return out
}
