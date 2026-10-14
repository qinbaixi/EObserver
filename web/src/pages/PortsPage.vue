<script setup lang="ts">
import { useQueryRef } from '../composables/useQueryRef'
import { computed, h, ref, toRef } from 'vue'
import { useI18n } from 'vue-i18n'
import { NDataTable, NInput, NIcon, NAlert, NTag, type DataTableColumns } from 'naive-ui'
import { SearchOutline } from '@vicons/ionicons5'
import { useNodes } from '../stores/nodes'
import { useTopic } from '../composables/useTopic'
import type { PortRow } from '../api/types'
import { formatBytes, formatNumber } from '../api/format'
import PageHeader from '../components/PageHeader.vue'
import RefreshControl from '../components/RefreshControl.vue'
import NodeGuard from '../components/NodeGuard.vue'
import PortDrawer from '../components/PortDrawer.vue'
import ProcessDrawer from '../components/ProcessDrawer.vue'
import { term } from '../api/term'
import { useResizableTable } from '../api/table'

const { t } = useI18n()
const nodes = useNodes()
const node = computed(() =>
  nodes.currentInfo?.status === 'connected' ? nodes.currentInfo.node : null)
const { data, error, paused, interval, refresh } = useTopic<PortRow[]>('node.ports', toRef(node), 3000)

const search = ref('')
const selectedPort = useQueryRef('port')
const selectedPid = useQueryRef('pid')

const rows = computed(() => {
  const q = search.value.trim().toLowerCase()
  const all = data.value ?? []
  return q ? all.filter((p) => [p.id, p.name, p.connected ?? '', p.registered_name ?? '']
    .some((s) => s.toLowerCase().includes(q))) : all
})

const num = (a: number, b: number) => a - b

const columns = computed<DataTableColumns<PortRow>>(() => [
  { key: 'id', title: t('pages.ports.cols.id'), width: 130, sorter: (a, b) => portNo(a.id) - portNo(b.id),
    render: (r) => h('span', { class: 'mono' }, r.id) },
  { key: 'name', title: t('pages.ports.cols.name'), minWidth: 240, ellipsis: { tooltip: true },
    sorter: (a, b) => a.name.localeCompare(b.name),
    render: (r) => h('span', { class: 'mono' }, [
      r.registered_name ? h('b', null, `${r.registered_name} `) : null,
      h('span', { class: r.registered_name ? 'muted' : '' }, r.name),
    ]) },
  { key: 'type', title: t('pages.ports.cols.type'), width: 90,
    render: (r) => h(NTag, { size: 'small', bordered: false, type: r.inet ? 'info' : r.os_pid ? 'warning' : 'default' },
      { default: () => (r.inet ? 'socket' : t(r.os_pid ? 'pages.ports.types.external' : 'pages.ports.types.driver')) }) },
  { key: 'connected', title: term('所属进程'), width: 130,
    render: (r) => r.connected
      ? h('a', { class: 'mono link', onClick: (e: Event) => { e.stopPropagation(); selectedPid.value = r.connected } }, r.connected)
      : '-' },
  { key: 'os_pid', title: term('OS pid'), width: 90, align: 'right',
    render: (r) => h('span', { class: 'mono muted' }, r.os_pid ?? '-') },
  { key: 'input', title: t('pages.ports.cols.input'), width: 110, align: 'right', sorter: (a, b) => num(a.input, b.input),
    render: (r) => h('span', { class: 'mono' }, formatBytes(r.input)) },
  { key: 'output', title: t('pages.ports.cols.output'), width: 110, align: 'right', sorter: (a, b) => num(a.output, b.output),
    render: (r) => h('span', { class: 'mono' }, formatBytes(r.output)) },
  { key: 'queue_size', title: term('队列'), width: 100, align: 'right', sorter: (a, b) => num(a.queue_size, b.queue_size),
    render: (r) => h('span', { class: ['mono', r.queue_size > 0 ? 'q-warn' : 'muted'] }, formatBytes(r.queue_size)) },
])

function portNo(id: string) {
  const m = /\.(\d+)>/.exec(id)
  return m ? Number(m[1]) : 0
}

const rowProps = (r: PortRow) => ({ style: 'cursor: pointer', onClick: () => { selectedPort.value = r.id } })
const portTable = useResizableTable(columns)
</script>

<template>
  <PageHeader :title="t('pages.ports.title')"
              :subtitle="data ? t('pages.ports.count', { n: formatNumber(data.length) }, data.length) : nodes.current ?? undefined">
    <NInput v-model:value="search" clearable :placeholder="t('pages.ports.filter')" style="width: 280px">
      <template #prefix><NIcon :component="SearchOutline" /></template>
    </NInput>
    <RefreshControl v-model:paused="paused" v-model:interval="interval" @refresh="refresh" />
  </PageHeader>
  <NodeGuard>
    <NAlert v-if="error" type="error" style="margin-bottom: 12px">{{ error }}</NAlert>
    <NDataTable v-bind="portTable" :data="rows" :loading="!data && !error" size="small"
                :row-key="(r: PortRow) => r.id" :row-props="rowProps"
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
