<script setup lang="ts">
import './echarts'
import { computed } from 'vue'
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

const graph = computed(() => {
  const kinds = new Map<string, Kind>()
  const observed = new Set(props.cluster.nodes.map((n) => n.node))
  for (const n of props.cluster.nodes) kinds.set(n.node, 'observed')
  const links: { source: string; target: string; hidden: boolean; input: number | null; output: number | null }[] = []
  const seen = new Set<string>()
  for (const n of props.cluster.nodes) {
    for (const c of n.connections) {
      if (!kinds.has(c.node)) kinds.set(c.node, c.node === props.cluster.tool ? 'tool' : c.hidden ? 'hidden' : 'peer')
      const key = [n.node, c.node].sort().join('|')
      if (seen.has(key)) continue
      seen.add(key)
      links.push({ source: n.node, target: c.node, hidden: c.hidden, input: c.input, output: c.output })
    }
  }
  return { kinds, links, observed }
})

const option = computed(() => {
  const th = t.value
  const { kinds, links } = graph.value
  const color: Record<Kind, string> = {
    observed: th.series[0], peer: th.muted, hidden: th.muted, tool: th.series[1],
  }
  return {
    animationDurationUpdate: 300,
    tooltip: {
      backgroundColor: th.tooltipBg,
      borderColor: th.axis,
      textStyle: { color: th.text },
      formatter: (p: { dataType: string; data: { name?: string; kind?: Kind; source?: string; target?: string; hidden?: boolean; input?: number | null; output?: number | null } }) => {
        const d = p.data
        if (p.dataType === 'node') return `<b>${d.name}</b><br/>${KIND_LABEL[d.kind!]}`
        const io = d.input != null ? `<br/>接收 ${formatBytes(d.input)} · 发送 ${formatBytes(d.output ?? 0)}` : ''
        return `${d.source} ↔ ${d.target}${d.hidden ? '（隐藏连接）' : ''}${io}`
      },
    },
    series: [{
      type: 'graph',
      layout: 'force',
      roam: true,
      draggable: true,
      force: { repulsion: 420, edgeLength: [90, 180], gravity: 0.08 },
      label: { show: true, position: 'bottom', color: th.text, fontFamily: 'ui-monospace, Menlo, monospace', fontSize: 12 },
      emphasis: { focus: 'adjacency', lineStyle: { width: 3 } },
      data: [...kinds.entries()].map(([name, kind]) => ({
        name,
        kind,
        symbol: kind === 'observed' || kind === 'tool' ? 'circle' : 'emptyCircle',
        symbolSize: kind === 'observed' ? (name === props.current ? 30 : 22) : 16,
        itemStyle: {
          color: color[kind],
          borderColor: name === props.current ? th.text : th.surface,
          borderWidth: name === props.current ? 3 : 2,
        },
      })),
      links: links.map((l) => ({
        ...l,
        lineStyle: { color: th.axis, width: 2, type: l.hidden ? 'dashed' : 'solid', curveness: 0 },
      })),
    }],
  }
})

function onClick(p: ECElementEvent) {
  const d = p.data as { name?: string; kind?: Kind } | undefined
  if (p.dataType !== 'node' || !d?.name || d.kind === 'tool') return
  emit('select', d.name, d.kind === 'observed')
}
</script>

<template>
  <VChart :option="option" :style="{ height: `${height ?? 520}px` }" autoresize @click="onClick" />
</template>
