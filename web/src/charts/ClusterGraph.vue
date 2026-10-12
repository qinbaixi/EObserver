<script setup lang="ts">
import './echarts'
import { computed, shallowRef, watch } from 'vue'
import VChart from 'vue-echarts'
import type { ECElementEvent } from 'echarts/core'
import { useChartTheme } from '../composables/useChartTheme'
import type { ClusterInfo } from '../api/types'
import { formatBytes } from '../api/format'

const props = defineProps<{ cluster: ClusterInfo; current: string | null; height?: number }>()
const emit = defineEmits<{ select: [node: string, observed: boolean] }>()
const t = useChartTheme()

type Kind = 'observed' | 'peer' | 'tool' | 'hidden'
const KIND_LABEL: Record<Kind, string> = {
  observed: '已观察', peer: '集群节点', hidden: '隐藏节点', tool: 'EObserver',
}

interface Link { source: string; target: string; hidden: boolean }

// The topology only: which nodes exist, how they are connected. The byte
// counters change on every refresh, so they live outside the option and
// are only read when a tooltip opens.
const graph = computed(() => {
  const kinds = new Map<string, Kind>()
  for (const n of props.cluster.nodes) kinds.set(n.node, 'observed')
  const links: Link[] = []
  const io = new Map<string, { input: number | null; output: number | null }>()
  const seen = new Set<string>()
  for (const n of props.cluster.nodes) {
    for (const c of n.connections) {
      if (!kinds.has(c.node)) kinds.set(c.node, c.node === props.cluster.tool ? 'tool' : c.hidden ? 'hidden' : 'peer')
      const key = [n.node, c.node].sort().join('|')
      if (!io.has(key)) io.set(key, { input: c.input, output: c.output })
      if (seen.has(key)) continue
      seen.add(key)
      links.push({ source: n.node, target: c.node, hidden: c.hidden })
    }
  }
  const nodeKey = [...kinds.entries()].map(([n, k]) => `${n}:${k}`).sort().join(',')
  const linkKey = links.map((l) => [l.source, l.target].sort().join('|') + (l.hidden ? 'h' : '')).sort().join(',')
  return { kinds, links, io, key: `${nodeKey}#${linkKey}` }
})

let io = new Map<string, { input: number | null; output: number | null }>()
watch(graph, (g) => { io = g.io }, { immediate: true })

// Fixed positions instead of a force layout, so the picture stays put
// across refreshes: cluster nodes on a circle in name order, EObserver and
// other hidden nodes in the middle. Labels sit on the outer side.
function layout(kinds: Map<string, Kind>) {
  const ring = [...kinds.keys()].filter((n) => kinds.get(n) === 'observed' || kinds.get(n) === 'peer').sort()
  const inner = [...kinds.keys()].filter((n) => !ring.includes(n)).sort()
  const pos = new Map<string, { x: number; y: number; angle: number | null }>()
  const R = 100
  ring.forEach((n, i) => {
    const a = -Math.PI / 2 + (2 * Math.PI * i) / Math.max(ring.length, 1)
    pos.set(n, { x: Math.cos(a) * R, y: Math.sin(a) * R, angle: a })
  })
  const r = inner.length > 1 ? R * 0.3 : 0
  inner.forEach((n, i) => {
    const a = -Math.PI / 2 + (2 * Math.PI * i) / inner.length
    pos.set(n, { x: Math.cos(a) * r, y: Math.sin(a) * r, angle: null })
  })
  return pos
}

function labelFor(angle: number | null) {
  if (angle === null) return { position: 'bottom' as const }
  const x = Math.cos(angle)
  const y = Math.sin(angle)
  // Horizontal text pointing away from the circle.
  if (Math.abs(x) < 0.15) return { position: y < 0 ? 'top' as const : 'bottom' as const }
  return { position: x > 0 ? 'right' as const : 'left' as const }
}

function buildOption() {
  const th = t.value
  const { kinds, links } = graph.value
  const pos = layout(kinds)
  const color: Record<Kind, string> = {
    observed: th.series[0], peer: th.muted, hidden: th.muted, tool: th.series[1],
  }
  return {
    animation: false,
    tooltip: {
      backgroundColor: th.tooltipBg,
      borderColor: th.axis,
      textStyle: { color: th.text },
      formatter: (p: { dataType: string; data: { name?: string; kind?: Kind; source?: string; target?: string; hidden?: boolean } }) => {
        const d = p.data
        if (p.dataType === 'node') return `<b>${d.name}</b><br/>${KIND_LABEL[d.kind!]}`
        const c = io.get([d.source!, d.target!].sort().join('|'))
        const bytes = c && c.input != null ? `<br/>接收 ${formatBytes(c.input)} · 发送 ${formatBytes(c.output ?? 0)}` : ''
        return `${d.source} ↔ ${d.target}${d.hidden ? '（隐藏连接）' : ''}${bytes}`
      },
    },
    series: [{
      type: 'graph',
      layout: 'none',
      roam: true,
      draggable: true,
      // Room for the labels around the circle.
      left: 300, right: 300, top: 50, bottom: 50,
      label: { show: true, color: th.text, fontFamily: 'ui-monospace, Menlo, monospace', fontSize: 12, distance: 8 },
      emphasis: { focus: 'adjacency', lineStyle: { width: 3, opacity: 1 } },
      data: [...kinds.entries()].map(([name, kind]) => {
        const p = pos.get(name)!
        return {
          name,
          kind,
          x: p.x,
          y: p.y,
          label: labelFor(p.angle),
          symbol: kind === 'observed' || kind === 'tool' ? 'circle' : 'emptyCircle',
          symbolSize: kind === 'observed' ? (name === props.current ? 22 : 16) : 12,
          itemStyle: {
            color: color[kind],
            borderColor: name === props.current ? th.text : th.surface,
            borderWidth: name === props.current ? 3 : 2,
          },
        }
      }),
      links: links.map((l) => ({
        ...l,
        lineStyle: { color: th.axis, width: 1.5, opacity: 0.8, type: l.hidden ? 'dashed' : 'solid', curveness: 0 },
      })),
    }],
  }
}

// Rebuild (and so re-place the nodes and reset zoom) only when the
// topology, the selected node or the theme changes.
const option = shallowRef(buildOption())
watch(() => `${graph.value.key}|${props.current}|${t.value.dark}`, () => { option.value = buildOption() })

function onClick(p: ECElementEvent) {
  const d = p.data as { name?: string; kind?: Kind } | undefined
  if (p.dataType !== 'node' || !d?.name || d.kind === 'tool') return
  emit('select', d.name, d.kind === 'observed')
}
</script>

<template>
  <VChart :option="option" :style="{ height: `${height ?? 520}px` }" autoresize @click="onClick" />
</template>
