<script setup lang="ts">
import { computed } from 'vue'

// A tiny line chart drawn as SVG (the overview wall shows dozens of them,
// too many for one ECharts instance each). Gaps are null values.
const props = withDefaults(defineProps<{
  data: [number, number | null][]
  windowMs: number
  now: number
  height?: number
}>(), { height: 28 })

const W = 100

// The x axis spans the history there is (at least MIN_SPAN_MS, at most the
// window); the y axis fits the values (padded by at least 10% so noise
// stays small), so a flat line sits in the middle.
const MIN_SPAN_MS = 60000

const paths = computed(() => {
  const pts = props.data.filter(([t]) => t >= props.now - props.windowMs)
  const vals = pts.map(([, v]) => v).filter((v): v is number => v != null)
  if (!vals.length) return { line: '', area: '' }
  const span = Math.min(props.windowMs, Math.max(MIN_SPAN_MS, props.now - pts[0][0]))
  const from = props.now - span
  const hi = Math.max(...vals)
  const lo = Math.min(...vals)
  const pad = Math.max((hi - lo) * 0.15, Math.abs(hi) * 0.1, 0.5)
  const min = Math.max(0, lo - pad)
  const range = hi + pad - min
  const h = props.height
  const x = (t: number) => (((t - from) / span) * W).toFixed(2)
  const y = (v: number) => (h - 1 - ((v - min) / range) * (h - 3)).toFixed(2)
  let line = ''
  let area = ''
  let run: [string, string][] = []
  const flush = () => {
    if (!run.length) return
    const segs = run.map(([a, b]) => `L${a},${b}`).join('')
    line += `M${run[0][0]},${run[0][1]}${segs}`
    area += `M${run[0][0]},${h}${segs}L${run[run.length - 1][0]},${h}Z`
    run = []
  }
  for (const [t, v] of pts) {
    if (v == null) flush()
    else run.push([x(t), y(v)])
  }
  flush()
  return { line, area }
})
</script>

<template>
  <svg class="spark" :viewBox="`0 0 ${W} ${height}`" preserveAspectRatio="none"
       :style="{ height: `${height}px` }" aria-hidden="true">
    <path :d="paths.area" class="area" />
    <path :d="paths.line" class="line" vector-effect="non-scaling-stroke" />
  </svg>
</template>

<style scoped>
.spark {
  display: block;
  width: 100%;
  overflow: visible;
}
.line {
  fill: none;
  stroke: currentColor;
  stroke-width: 1.5;
  stroke-linejoin: round;
}
.area {
  fill: currentColor;
  opacity: 0.12;
}
</style>
