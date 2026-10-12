<script setup lang="ts">
import { useQueryRef } from '../composables/useQueryRef'
import { computed, h, ref, toRef } from 'vue'
import { NDataTable, NInput, NIcon, NAlert, NTag, type DataTableColumns } from 'naive-ui'
import { SearchOutline } from '@vicons/ionicons5'
import { useNodes } from '../stores/nodes'
import { useTopic } from '../composables/useTopic'
import type { PortRow } from '../api/types'
import { formatBytes, formatNumber } from '../api/format'
import PageHeader from '../components/PageHeader.vue'
import NodeGuard from '../components/NodeGuard.vue'
import PortDrawer from '../components/PortDrawer.vue'
import ProcessDrawer from '../components/ProcessDrawer.vue'
import { term } from '../api/term'

const nodes = useNodes()
const node = computed(() =>
  nodes.currentInfo?.status === 'connected' ? nodes.currentInfo.node : null)
const { data, error } = useTopic<PortRow[]>('node.ports', toRef(node), 3000)

const search = ref('')
const selectedPort = useQueryRef('port')
const selectedPid = useQueryRef('pid')

const rows = computed(() => {
  const q = search.value.trim().toLowerCase()
  const all = data.value ?? []
  return q ? all.filter((p) => [p.id, p.name, p.connected ?? '', p.registered_name ?? '']
    .some((t) => t.toLowerCase().includes(q))) : all
})

const num = (a: number, b: number) => a - b

const columns: DataTableColumns<PortRow> = [
  { key: 'id', title: '端口', width: 130, sorter: (a, b) => portNo(a.id) - portNo(b.id),
    render: (r) => h('span', { class: 'mono' }, r.id) },
  { key: 'name', title: '名称', minWidth: 240, ellipsis: { tooltip: true },
    sorter: (a, b) => a.name.localeCompare(b.name),
    render: (r) => h('span', { class: 'mono' }, [
      r.registered_name ? h('b', null, `${r.registered_name} `) : null,
      h('span', { class: r.registered_name ? 'muted' : '' }, r.name),
    ]) },
  { key: 'type', title: '类型', width: 90,
    render: (r) => h(NTag, { size: 'small', bordered: false, type: r.inet ? 'info' : r.os_pid ? 'warning' : 'default' },
      { default: () => (r.inet ? 'socket' : r.os_pid ? '外部程序' : '驱动') }) },
  { key: 'connected', title: term('所属进程'), width: 130,
    render: (r) => r.connected
      ? h('a', { class: 'mono link', onClick: (e: Event) => { e.stopPropagation(); selectedPid.value = r.connected } }, r.connected)
      : '-' },
  { key: 'os_pid', title: term('OS pid'), width: 90, align: 'right',
    render: (r) => h('span', { class: 'mono muted' }, r.os_pid ?? '-') },
  { key: 'input', title: '输入', width: 110, align: 'right', sorter: (a, b) => num(a.input, b.input),
    render: (r) => h('span', { class: 'mono' }, formatBytes(r.input)) },
  { key: 'output', title: '输出', width: 110, align: 'right', sorter: (a, b) => num(a.output, b.output),
    render: (r) => h('span', { class: 'mono' }, formatBytes(r.output)) },
  { key: 'queue_size', title: term('队列'), width: 100, align: 'right', sorter: (a, b) => num(a.queue_size, b.queue_size),
    render: (r) => h('span', { class: ['mono', r.queue_size > 0 ? 'q-warn' : 'muted'] }, formatBytes(r.queue_size)) },
]

function portNo(id: string) {
  const m = /\.(\d+)>/.exec(id)
  return m ? Number(m[1]) : 0
}

const rowProps = (r: PortRow) => ({ style: 'cursor: pointer', onClick: () => { selectedPort.value = r.id } })
</script>

<template>
  <PageHeader title="端口" :subtitle="data ? `${formatNumber(data.length)} 个端口` : nodes.current ?? undefined">
    <NInput v-model:value="search" clearable placeholder="按端口、名称或进程过滤" style="width: 280px">
      <template #prefix><NIcon :component="SearchOutline" /></template>
    </NInput>
  </PageHeader>
  <NodeGuard>
    <NAlert v-if="error" type="error" style="margin-bottom: 12px">{{ error }}</NAlert>
    <NDataTable :columns="columns" :data="rows" :loading="!data && !error" size="small"
                :row-key="(r: PortRow) => r.id" :row-props="rowProps" :scroll-x="1000"
                :pagination="{ pageSize: 50 }" />
    <template v-if="node">
      <PortDrawer v-model:port="selectedPort" :node="node" @open-pid="(p) => (selectedPid = p)" />
      <ProcessDrawer v-model:pid="selectedPid" :node="node" />
    </template>
  </NodeGuard>
</template>

<style scoped>
:deep(.muted) { opacity: 0.6; }
:deep(.q-warn) { color: #f0a020; font-weight: 600; }
:deep(.link) { cursor: pointer; }
:deep(.link:hover) { text-decoration: underline; }
</style>
