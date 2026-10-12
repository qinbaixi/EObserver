<script setup lang="ts">
import './echarts'
import { computed } from 'vue'
import VChart from 'vue-echarts'
import { useChartTheme } from '../composables/useChartTheme'
import type { SupNode } from '../api/types'

const props = defineProps<{ root: SupNode }>()
const emit = defineEmits<{ select: [pid: string] }>()
const t = useChartTheme()

interface TreeDatum {
  name: string
  value: string | null
  node: SupNode | null
  children: TreeDatum[]
  symbol?: string
  itemStyle?: Record<string, unknown>
  label?: Record<string, unknown>
}

function label(n: SupNode) {
  return n.name ?? (n.id !== 'undefined' ? n.id : n.pid ?? '?')
}

function toDatum(n: SupNode): TreeDatum {
  const th = t.value
  const sup = n.type === 'supervisor'
  const alive = n.pid !== null
  const children = n.children.map(toDatum)
  if (n.hidden > 0) {
    children.push({
      name: `… 还有 ${n.hidden} 个`,
      value: null,
      node: null,
      children: [],
      symbol: 'none',
      label: { color: th.muted },
    })
  }
  return {
    name: label(n),
    value: n.pid,
    node: n,
    children,
    symbol: sup ? 'circle' : 'emptyCircle',
    // emptyCircle strokes with `color` and fills with the background.
    itemStyle: {
      color: alive ? th.series[0] : th.muted,
      borderWidth: sup ? 0 : 2,
    },
    label: n.error ? { color: '#d03050' } : undefined,
  }
}

function leaves(n: SupNode): number {
  const own = n.children.reduce((a, c) => a + leaves(c), 0) + (n.hidden > 0 ? 1 : 0)
  return Math.max(1, own)
}

const height = computed(() => Math.max(420, leaves(props.root) * 26 + 40))

const option = computed(() => {
  const th = t.value
  return {
    animationDuration: 200,
    tooltip: {
      trigger: 'item',
      backgroundColor: th.tooltipBg,
      borderColor: th.axis,
      textStyle: { color: th.text },
      formatter: (p: { data: TreeDatum }) => {
        const n = p.data.node
        if (!n) return p.data.name
        const rows = [
          `<b>${p.data.name}</b>`,
          n.pid ? `pid ${n.pid}` : `状态 ${n.status ?? '未运行'}`,
          n.module ? `模块 ${n.module}` : '',
          `${n.type === 'supervisor' ? '监督者' : '工作进程'} · id ${n.id}`,
          n.error ? `<span style="color:#d03050">${n.error}</span>` : '',
        ]
        return rows.filter(Boolean).join('<br/>')
      },
    },
    series: [{
      type: 'tree',
      data: [toDatum(props.root)],
      orient: 'LR',
      top: 20,
      bottom: 20,
      left: 120,
      right: 220,
      symbolSize: 10,
      initialTreeDepth: -1,
      expandAndCollapse: false,
      roam: false,
      lineStyle: { color: th.axis, width: 1.5, curveness: 0.5 },
      label: {
        position: 'left',
        verticalAlign: 'middle',
        align: 'right',
        color: th.text,
        fontSize: 12,
        fontFamily: "'JetBrains Mono', 'SFMono-Regular', Menlo, Consolas, monospace",
      },
      leaves: { label: { position: 'right', align: 'left' } },
      emphasis: { focus: 'descendant' },
    }],
  }
})

function onClick(e: { data?: unknown }) {
  const pid = (e.data as TreeDatum | undefined)?.node?.pid
  if (pid) emit('select', pid)
}
</script>

<template>
  <VChart :option="option" :style="{ height: `${height}px` }" autoresize @click="onClick" />
</template>
