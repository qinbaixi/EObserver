<script setup lang="ts">
import { computed, h, ref } from 'vue'
import { useRouter } from 'vue-router'
import { NGrid, NGi, NCard, NDataTable, NAlert, NTag, NText, type DataTableColumns } from 'naive-ui'
import { useNodes } from '../stores/nodes'
import { useUi } from '../stores/ui'
import { useTopic } from '../composables/useTopic'
import { useChartTheme } from '../composables/useChartTheme'
import type { ClusterInfo } from '../api/types'
import { formatBytes } from '../api/format'
import PageHeader from '../components/PageHeader.vue'
import RefreshControl from '../components/RefreshControl.vue'
import ClusterGraph from '../charts/ClusterGraph.vue'
import { useResizableTable } from '../api/table'

const nodes = useNodes()
const ui = useUi()
const router = useRouter()
const t = useChartTheme()
// The topic covers every observed node; the parameter only starts it.
const { data, error, paused, interval, refresh } = useTopic<ClusterInfo>('cluster', ref('all'), 3000)

interface Row { from: string; to: string; hidden: boolean; input: number | null; output: number | null; observed: boolean }
const rows = computed<Row[]>(() => {
  const d = data.value
  if (!d) return []
  const observed = new Set(d.nodes.map((n) => n.node))
  return d.nodes.flatMap((n) => n.connections
    .filter((c) => c.node !== d.tool)
    .map((c) => ({ from: n.node, to: c.node, hidden: c.hidden, input: c.input, output: c.output, observed: observed.has(c.node) })))
})

const peers = computed(() => new Set(rows.value.map((r) => r.to)).size)

function select(node: string, observed: boolean) {
  if (observed) {
    nodes.select(node)
    void router.push({ name: 'system', query: { node } })
  } else {
    ui.openConnect(node)
  }
}

const mono = (s: string) => h('span', { class: 'mono' }, s)
const columns: DataTableColumns<Row> = [
  { key: 'from', title: '节点', minWidth: 180, sorter: (a, b) => a.from.localeCompare(b.from), render: (r) => mono(r.from) },
  { key: 'to', title: '连接到', minWidth: 200, sorter: (a, b) => a.to.localeCompare(b.to),
    render: (r) => h('a', { class: 'mono link', onClick: () => select(r.to, r.observed) }, r.to) },
  { key: 'kind', title: '类型', width: 110,
    render: (r) => h(NTag, { size: 'small', bordered: false, type: r.hidden ? 'default' : 'info' },
      { default: () => (r.hidden ? '隐藏' : '可见') }) },
  { key: 'input', title: '接收', width: 110, align: 'right', sorter: (a, b) => (a.input ?? 0) - (b.input ?? 0),
    render: (r) => mono(r.input == null ? '-' : formatBytes(r.input)) },
  { key: 'output', title: '发送', width: 110, align: 'right', sorter: (a, b) => (a.output ?? 0) - (b.output ?? 0),
    render: (r) => mono(r.output == null ? '-' : formatBytes(r.output)) },
]
const connTable = useResizableTable(columns)
</script>

<template>
  <PageHeader title="集群拓扑" :subtitle="data ? `观察 ${data.nodes.length} 个节点，发现 ${peers} 个相连节点` : undefined">
    <RefreshControl v-model:paused="paused" v-model:interval="interval" @refresh="refresh" />
  </PageHeader>
  <NAlert v-if="error" type="error" style="margin-bottom: 12px">{{ error }}</NAlert>
  <NGrid :cols="1" :y-gap="12">
    <NGi>
      <NCard size="small" title="分布式连接">
        <template #header-extra>
          <div class="legend">
            <span><i class="dot" :style="{ background: t.series[0] }" />已观察</span>
            <span><i class="dot ring" :style="{ borderColor: t.muted }" />集群节点</span>
            <span><i class="dot" :style="{ background: t.series[1] }" />EObserver</span>
            <span><i class="dash" :style="{ borderColor: t.muted }" />隐藏连接</span>
          </div>
        </template>
        <ClusterGraph v-if="data && data.nodes.length" :cluster="data" :current="nodes.current" @select="select" />
        <div v-else class="empty"><NText depth="3">{{ data ? '还没有观察任何节点' : '加载中…' }}</NText></div>
        <NText depth="3" style="font-size: 12px">点击已观察的节点切换过去，点击其他节点可以连接它；可拖动和缩放。</NText>
      </NCard>
    </NGi>
    <NGi>
      <NCard size="small" title="连接列表">
        <NDataTable v-bind="connTable" :data="rows" size="small" :pagination="{ pageSize: 50 }"
                    :row-key="(r: Row) => `${r.from}|${r.to}`" />
      </NCard>
    </NGi>
  </NGrid>
</template>

<style scoped>
.legend { display: flex; gap: 16px; font-size: 12px; opacity: 0.8; }
.legend span { display: inline-flex; align-items: center; gap: 6px; }
.dot { width: 10px; height: 10px; border-radius: 50%; display: inline-block; }
.dot.ring { background: transparent; border: 2px solid; width: 6px; height: 6px; }
.dash { width: 18px; border-top: 2px dashed; display: inline-block; }
.empty { height: 240px; display: flex; align-items: center; justify-content: center; }
:deep(.link) { cursor: pointer; }
:deep(.link:hover) { text-decoration: underline; }
</style>
