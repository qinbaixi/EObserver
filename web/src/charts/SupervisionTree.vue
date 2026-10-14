<script setup lang="ts">
import './echarts'
import { computed, ref } from 'vue'
import VChart from 'vue-echarts'
import { useI18n } from 'vue-i18n'
import { useChartTheme } from '../composables/useChartTheme'
import type { SupNode } from '../api/types'

const props = defineProps<{ root: SupNode }>()
const emit = defineEmits<{ select: [pid: string] }>()
const t = useChartTheme()
const { t: tr } = useI18n()

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
      name: tr('pages.sup_tree.more', { n: n.hidden }),
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

// Rough label width in px for the 12px monospace font; wide (CJK) characters
// count double.
function textWidth(s: string) {
  let w = 0
  for (const ch of s) w += ch.charCodeAt(0) > 0x2e80 ? 2 : 1
  return w * 7.4
}

// ECharts spaces tree levels evenly across the chart, so names overlap when
// a leaf's label (drawn to its right) meets the label of a supervisor one
// level deeper (drawn to its left). Size every level gap for the widest such
// pair and let the chart grow wider than the page; the wrapper scrolls.
const layout = computed(() => {
  const leafW: number[] = []   // widest right-hand (leaf) label per depth
  const supW: number[] = []    // widest left-hand (supervisor) label per depth
  const walk = (d: TreeDatum, depth: number) => {
    const w = textWidth(d.name)
    if (d.children.length === 0) leafW[depth] = Math.max(leafW[depth] ?? 0, w)
    else supW[depth] = Math.max(supW[depth] ?? 0, w)
    d.children.forEach((c) => walk(c, depth + 1))
  }
  walk(toDatum(props.root), 0)
  const depth = Math.max(leafW.length, supW.length) - 1
  const left = (supW[0] ?? leafW[0] ?? 0) + 24
  const right = Math.max(0, ...leafW.filter((x) => x != null)) + 24
  let gap = 140
  for (let d = 0; d < depth; d++) gap = Math.max(gap, (leafW[d] ?? 0) + (supW[d + 1] ?? 0) + 40)
  return { left, right, width: Math.ceil(left + right + gap * depth) }
})

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
          n.pid ? `pid ${n.pid}` : tr('pages.sup_tree.status', { s: n.status ?? tr('pages.sup_tree.not_running') }),
          n.module ? tr('pages.sup_tree.module', { m: n.module }) : '',
          `${tr(n.type === 'supervisor' ? 'pages.sup_tree.supervisor' : 'pages.sup_tree.worker')} · id ${n.id}`,
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
      left: layout.value.left,
      right: layout.value.right,
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

// Dragging the tree pans the scroll box; a press that barely moves stays a
// click on a node.
const box = ref<HTMLElement | null>(null)
let drag: { x: number; y: number; left: number; top: number; moved: boolean } | null = null
function onPointerDown(e: PointerEvent) {
  if (e.button !== 0 || !box.value) return
  drag = { x: e.clientX, y: e.clientY, left: box.value.scrollLeft, top: box.value.scrollTop, moved: false }
}
function onPointerMove(e: PointerEvent) {
  if (!drag || !box.value) return
  const dx = e.clientX - drag.x
  const dy = e.clientY - drag.y
  if (!drag.moved && Math.abs(dx) + Math.abs(dy) < 4) return
  drag.moved = true
  box.value.scrollLeft = drag.left - dx
  box.value.scrollTop = drag.top - dy
}
function onPointerUp() {
  // Keep the flag until the chart's click event, which fires after this.
  setTimeout(() => { drag = null })
}

function onClick(e: { data?: unknown }) {
  if (drag?.moved) return
  const pid = (e.data as TreeDatum | undefined)?.node?.pid
  if (pid) emit('select', pid)
}
</script>

<template>
  <div ref="box" class="tree-scroll"
       @pointerdown="onPointerDown" @pointermove="onPointerMove" @pointerup="onPointerUp"
       @pointerleave="onPointerUp">
    <VChart :option="option" :style="{ height: `${height}px`, minWidth: `${layout.width}px` }"
            autoresize @click="onClick" />
  </div>
</template>

<style scoped>
/* Wide or tall trees scroll inside a box that fits the window, so the
   horizontal scrollbar stays in view instead of below the whole tree. */
.tree-scroll {
  overflow: auto;
  max-height: calc(100vh - 230px);
  min-height: 420px;
}
.tree-scroll::-webkit-scrollbar { width: 12px; height: 12px; }
.tree-scroll::-webkit-scrollbar-thumb {
  background: var(--n-scrollbar-color, rgba(128, 128, 128, 0.45));
  border-radius: 5px;
}
.tree-scroll::-webkit-scrollbar-track { background: transparent; }
</style>
